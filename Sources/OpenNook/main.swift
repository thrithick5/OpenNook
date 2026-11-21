import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Application bootstrap (pure Menu-Bar & Notch background agent — no Dock / Cmd+Tab icon)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    override nonisolated init() {}
    var settingsStore: SettingsStore!
    var store: Store!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    private let settingsDelegate = SettingsWindowDelegate()
    var panelController: NotchPanelController!
    var media: MediaProvider!
    var timerModel: TimerModel!
    var mirror: MirrorService!
    var systemMonitor: SystemMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always run as a background accessory (menu bar icon + notch only; never show in Dock or Cmd+Tab)
        NSApp.setActivationPolicy(.accessory)

        // Terminate any older running OpenNook instances so the latest build always takes over cleanly
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.opennook.app"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        if !runningApps.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.opennook.quit"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            for existing in runningApps {
                let pid = existing.processIdentifier
                _ = existing.terminate()
                _ = existing.forceTerminate()
                kill(pid, SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        // Sync current app bundle to /Applications/OpenNook.app if running from DMG, Downloads, or dist/
        let currentBundleURL = Bundle.main.bundleURL
        let appsURL = URL(fileURLWithPath: "/Applications/OpenNook.app")
        if currentBundleURL.path != appsURL.path && currentBundleURL.pathExtension == "app" {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: appsURL)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = [currentBundleURL.path, appsURL.path]
                try? ditto.run()
                ditto.waitUntilExit()
                let xattrProc = Process()
                xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProc.arguments = ["-cr", appsURL.path]
                try? xattrProc.run()
                xattrProc.waitUntilExit()
            }
        }

        settingsStore = SettingsStore()
        // Never start in pinned mode by default
        if settingsStore.settings.pinnedOpenByDefault {
            settingsStore.settings.pinnedOpenByDefault = false
        }

        store = Store()
        media = MediaProvider()
        timerModel = TimerModel()
        mirror = MirrorService()
        systemMonitor = SystemMonitor.shared

        panelController = makeController(settingsStore: settingsStore, store: store,
                                         media: media, timerModel: timerModel,
                                         mirror: mirror, systemMonitor: systemMonitor)

        settingsStore.onSettingsChanged = { [weak self] _ in
            Task { @MainActor in
                self?.panelController.applySettingsUpdate()
            }
        }

        timerModel.onFinished = { [weak self] in
            NSSound.beep()
            self?.systemMonitor.presentAlert(LiveActivityAlert(
                kind: .timer,
                title: "Timer Finished",
                subtitle: "Focus sprint complete!",
                icon: "checkmark.circle.fill",
                accentHex: 0x32b25d
            ), duration: 3.5)
        }

        media.onTrackChanged = { [weak self] newTrack in
            guard let self = self, self.settingsStore.settings.showSneakPeekOnTrackChange else { return }
            self.systemMonitor.presentAlert(LiveActivityAlert(
                kind: .media,
                title: newTrack.title,
                subtitle: newTrack.artist,
                icon: "music.note",
                accentHex: newTrack.dominantColorHex
            ), duration: 2.6)
        }

        media.startObserving()
        systemMonitor.startMonitoring(store: store, settings: settingsStore.settings)
        // Show the Dynamic Island quietly in its collapsed camera-notch state (not pinned, no Settings window)
        panelController.show()
        buildStatusItem()

        if settingsStore.settings.launchAtLogin {
            try? SMAppService.mainApp.register()
        }

        setupDebugRemoteControl()
    }

    // If user launches the app again while already running, keep it unpinned and do not open Settings automatically
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.setActivationPolicy(.accessory)
        for url in urls where url.host == "settings" {
            showSettings()
        }
    }

    // Remote control hooks for external signals and single-instance activation
    private func setupDebugRemoteControl() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(debugExpand),
            name: NSNotification.Name("com.opennook.debug.expand"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(debugCollapse),
            name: NSNotification.Name("com.opennook.debug.collapse"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(quitFromNotification),
            name: NSNotification.Name("com.opennook.quit"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func quitFromNotification() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    @objc private func debugExpand() {
        DispatchQueue.main.async { [weak self] in
            self?.panelController.expand(pin: false)
        }
    }

    @objc private func debugCollapse() {
        DispatchQueue.main.async { [weak self] in
            self?.panelController.collapse()
        }
    }

    func makeController(settingsStore: SettingsStore, store: Store,
                        media: MediaProvider, timerModel: TimerModel,
                        mirror: MirrorService, systemMonitor: SystemMonitor) -> NotchPanelController {
        let controller = NotchPanelController(screen: NSScreen.main ?? NSScreen.screens[0],
                                              store: store, media: media,
                                              calendar: .shared, timerModel: timerModel,
                                              settingsStore: settingsStore, mirror: mirror,
                                              systemMonitor: systemMonitor)
        controller.viewModel.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        return controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settingsStore.settings.clearTrayOnQuit {
            store.clearTray()
        }
        systemMonitor.stopMonitoring()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    // MARK: Status bar menu

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset", accessibilityDescription: "OpenNook")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Notch (Nook)", action: #selector(openNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open File Tray", action: #selector(openTray), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Camera Mirror", action: #selector(toggleMirror), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Caffeine (Keep Awake)", action: #selector(toggleCaffeine), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenNook", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openNotch() {
        panelController.viewModel.activeTab = .nook
        panelController.expand(pin: false)
    }

    @objc func openTray() {
        panelController.viewModel.activeTab = .tray
        panelController.expand(pin: false)
    }

    @objc func toggleMirror() {
        panelController.viewModel.activeTab = .nook
        panelController.expand(pin: false)
        mirror.toggle(!mirror.isOn)
    }

    @objc func toggleCaffeine() {
        systemMonitor.toggleCaffeine()
    }

    @objc func showSettings() {
        // Keep .accessory policy so OpenNook never shows in the Dock or Cmd+Tab app switcher
        NSApp.setActivationPolicy(.accessory)
        if let existing = settingsWindow {
            existing.deminiaturize(nil)
            existing.center()
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "OpenNook Settings"
        window.contentView = NSHostingView(rootView: SettingsRootView(settingsStore: settingsStore))
        window.center()
        window.level = .floating
        window.delegate = settingsDelegate
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
