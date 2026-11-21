import AppKit
import SwiftUI

// MARK: - Keyable Floating Notch Panel

final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Notch panel controller (Single Morphing Apple Dynamic Island)

@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    enum State { case collapsed, expanded }

    private var screen: NSScreen
    private var islandPanel: KeyableNotchPanel!
    private var state: State = .collapsed
    private var pinned = false
    private var isDraggingOver = false
    private var pendingCollapse: DispatchWorkItem?
    private var pendingExpand: DispatchWorkItem?

    private let store: Store
    private let media: MediaProvider
    private let calendar: CalendarProvider
    private let timerModel: TimerModel
    private let settingsStore: SettingsStore
    private let mirror: MirrorService
    private let systemMonitor: SystemMonitor

    private var clickAwayMonitor: Any?
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var hoverCheckTimer: Timer?

    var viewModel: NotchViewModel!

    init(screen: NSScreen,
         store: Store,
         media: MediaProvider,
         calendar: CalendarProvider,
         timerModel: TimerModel,
         settingsStore: SettingsStore,
         mirror: MirrorService,
         systemMonitor: SystemMonitor? = nil) {
        self.screen = screen
        self.store = store
        self.media = media
        self.calendar = calendar
        self.timerModel = timerModel
        self.settingsStore = settingsStore
        self.mirror = mirror
        self.systemMonitor = systemMonitor ?? .shared
        super.init()
        setupWindow()
    }

    convenience init(screen: NSScreen,
                     store: Store,
                     media: MediaProvider,
                     calendar: CalendarProvider,
                     timerModel: TimerModel,
                     settings: Settings,
                     mirror: MirrorService) {
        let ss = SettingsStore(initial: settings)
        self.init(screen: screen, store: store, media: media, calendar: calendar,
                  timerModel: timerModel, settingsStore: ss, mirror: mirror, systemMonitor: .shared)
    }

    private var settings: Settings { settingsStore.settings }

    // MARK: Window setup

    private func setupWindow() {
        let notchH = hasHardwareNotch ? max(32, notchRect?.height ?? 32) : 32
        let cutoutW: CGFloat = {
            if let nr = notchRect, nr.width > 80 && nr.width < 320 {
                return nr.width
            }
            return 184
        }()

        viewModel = NotchViewModel(store: store, media: media, calendar: calendar,
                                   timerModel: timerModel, settingsStore: settingsStore,
                                   mirror: mirror, systemMonitor: systemMonitor,
                                   pillBlendHeight: notchH,
                                   hardwareNotchWidth: cutoutW)
        viewModel.onRequestExpand = { [weak self] in
            guard let self = self else { return }
            self.expand(pin: false)
        }
        viewModel.onRequestCollapse = { [weak self] in self?.collapse() }
        viewModel.onRequestPin = { [weak self] in self?.togglePinned() }
        viewModel.onOpenMirror = { [weak self] in
            guard let self = self else { return }
            self.cancelPendingCollapse()
            self.viewModel.activeTab = .nook
            Haptics.play(.generic, disabled: self.settings.disableHaptics)
            self.mirror.toggle(!self.mirror.isOn)
        }
        viewModel.onHoverEnterPanel = { [weak self] in self?.cancelPendingCollapse() }
        viewModel.onHoverExitPanel = { [weak self] in
            guard let self = self else { return }
            guard !self.mouseIsInsideNotchRegion() else { return }
            let recentMirrorTap = Date().timeIntervalSince(self.mirror.lastInteractionDate) < 2.2
            if !self.pinned && !self.viewModel.isEditingText && !self.isDraggingOver && !self.mirror.isOn && !self.mirror.isRequestingPermission && !recentMirrorTap {
                self.scheduleCollapse(in: 0.15)
            }
        }
        viewModel.onFocusTextField = { [weak self] in
            guard let self = self else { return }
            self.cancelPendingCollapse()
            NSApp.activate(ignoringOtherApps: true)
            self.islandPanel.makeKeyAndOrderFront(nil)
        }

        let rootView = DynamicIslandRootView(vm: viewModel)
        islandPanel = makePanel(contentRect: currentTargetFrame())
        islandPanel.contentView = HoverCatchingView(
            hosting: rootView,
            onEnter: { [weak self] in
                guard let self = self else { return }
                self.cancelPendingCollapse()
                if self.state == .collapsed && self.settings.openOnHover {
                    self.scheduleExpand(in: self.settings.hoverDelay)
                }
            },
            onExit: { [weak self] in
                guard let self = self else { return }
                self.pendingExpand?.cancel()
                guard !self.mouseIsInsideNotchRegion() else { return }
                let recentMirrorTap = Date().timeIntervalSince(self.mirror.lastInteractionDate) < 2.2
                if self.state == .expanded && !self.pinned && !self.viewModel.isEditingText && !self.isDraggingOver && !self.mirror.isOn && !self.mirror.isRequestingPermission && !recentMirrorTap {
                    self.scheduleCollapse(in: 0.15)
                }
            },
            onDragEnter: { [weak self] in
                guard let self = self else { return }
                self.isDraggingOver = true
                self.viewModel?.isDraggingFilesOver = true
                self.cancelPendingCollapse()
                if self.settings.autoOpenTrayOnDrag {
                    self.expandForDrag()
                }
            },
            onDragExit: { [weak self] in
                guard let self = self else { return }
                self.isDraggingOver = false
                self.viewModel?.isDraggingFilesOver = false
                if !self.pinned {
                    self.scheduleCollapse(in: 1.6)
                }
            },
            onPerformFileDrop: { [weak self] urls in
                guard let self = self else { return false }
                self.isDraggingOver = false
                self.viewModel?.isDraggingFilesOver = false
                self.cancelPendingCollapse()
                var addedAny = false
                for url in urls {
                    if self.store.addTrayItem(path: url.path, reverseOrder: self.settings.reverseTrayOrder) {
                        addedAny = true
                    }
                }
                if !urls.isEmpty {
                    Haptics.play(.alignment, disabled: self.settings.disableHaptics)
                    self.viewModel?.activeTab = .tray
                    if self.state == .collapsed {
                        self.expand(pin: false)
                    }
                }
                return addedAny || !urls.isEmpty
            },
            onScrollSwipe: { [weak self] deltaX, deltaY in
                self?.handleScrollGesture(deltaX: deltaX, deltaY: deltaY)
            }
        )
        islandPanel.orderOut(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)
    }

    private func makePanel(contentRect: NSRect) -> KeyableNotchPanel {
        let p = KeyableNotchPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar + 1
        p.collectionBehavior = settings.showInFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.canJoinAllSpaces, .stationary]
        p.sharingType = settings.hideFromScreenRecording ? .none : .readOnly
        p.isMovable = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.delegate = self
        return p
    }

    func applySettingsUpdate() {
        let behavior: NSWindow.CollectionBehavior = settings.showInFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.canJoinAllSpaces, .stationary]
        islandPanel.collectionBehavior = behavior
        islandPanel.sharingType = settings.hideFromScreenRecording ? .none : .readOnly
        islandPanel.setFrame(currentTargetFrame(), display: true, animate: true)
        applyVisibility()
    }

    func show() {
        islandPanel.setFrame(currentTargetFrame(), display: true)
        islandPanel.registerForDraggedTypes([.fileURL, .URL, .string])
        islandPanel.orderFrontRegardless()
        applyVisibility()
    }

    func hide() {
        islandPanel.orderOut(nil)
    }

    private func applyVisibility() {
        guard allowed else {
            islandPanel.alphaValue = 0
            islandPanel.ignoresMouseEvents = true
            return
        }
        islandPanel.alphaValue = 1
        islandPanel.ignoresMouseEvents = false
    }

    // MARK: Geometry

    private var notchRect: NSRect? {
        let frame = screen.frame
        let inset = screen.safeAreaInsets
        return NotchGeometry.notchRect(for: frame, leftInset: inset.left, topInset: inset.top)
    }

    var hasHardwareNotch: Bool { notchRect != nil }

    var allowed: Bool { hasHardwareNotch || settings.enableOnNonNotchScreens }

    private var physicalNotchCenter: CGFloat {
        if let tl = screen.auxiliaryTopLeftArea, let tr = screen.auxiliaryTopRightArea {
            return (tl.maxX + tr.minX) / 2.0
        }
        return screen.frame.midX
    }

    private func currentTargetFrame() -> NSRect {
        let center = physicalNotchCenter
        if state == .collapsed {
            let barHeight = hasHardwareNotch ? max(36, (notchRect?.height ?? 32) + 4) : 34
            let cutoutW: CGFloat = {
                if let nr = notchRect, nr.width > 80 && nr.width < 320 {
                    return nr.width
                }
                return 184
            }()
            return NSRect(
                x: round(center - cutoutW / 2),
                y: screen.frame.maxY - barHeight,
                width: cutoutW,
                height: barHeight
            )
        } else {
            let maxW = settings.expandedMaxWidth
            let contentWidth: CGFloat = min(screen.frame.width * 0.94, maxW)
            let totalHeight: CGFloat = settings.expandedMaxHeight
            let top = screen.frame.maxY
            return NSRect(
                x: round(center - contentWidth / 2),
                y: top - totalHeight,
                width: contentWidth,
                height: totalHeight
            )
        }
    }

    @objc private func screenChanged() {
        if settings.followMouseDisplay, let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            screen = mouseScreen
        } else if let main = NSScreen.main {
            screen = main
        }
        let notchH = hasHardwareNotch ? max(32, notchRect?.height ?? 32) : 32
        viewModel?.pillBlendHeight = notchH
        if let nr = notchRect, nr.width > 80 && nr.width < 320 {
            viewModel?.hardwareNotchWidth = nr.width
        }
        islandPanel.setFrame(currentTargetFrame(), display: true)
        applyVisibility()
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.screenChanged()
            self?.systemMonitor.refreshBattery()
            self?.media.refresh()
            self?.calendar.loadTodayEvents()
        }
    }

    // MARK: Trackpad Swipe & Scroll Gestures

    private func handleScrollGesture(deltaX: CGFloat, deltaY: CGFloat) {
        guard settings.enableSwipeGestures else { return }
        let dirMultiplier: CGFloat = settings.naturalGestureDirection ? 1.0 : -1.0
        let dy = deltaY * dirMultiplier

        if state == .collapsed {
            if dy < -5 {
                expand(pin: false)
            } else if abs(deltaX) > 6 {
                let step = deltaX > 0 ? 0.03 : -0.03
                systemMonitor.setSystemVolume(systemMonitor.systemVolume + step, showHUD: true)
            }
        } else {
            if dy > 10 && !pinned && !viewModel.isEditingText && !mirror.isOn {
                collapse()
            }
        }
    }

    // MARK: State transitions

    private func scheduleExpand(in delay: TimeInterval) {
        pendingExpand?.cancel()
        if delay <= 0.01 {
            expand(pin: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.expand(pin: false)
        }
        pendingExpand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func expand(pin: Bool = false) {
        pendingExpand?.cancel()
        guard state == .collapsed else {
            if pin && !pinned {
                pinned = true
                viewModel?.pinned = true
            }
            return
        }
        pendingCollapse?.cancel()
        Haptics.play(.alignment, disabled: settings.disableHaptics)
        pinned = pin
        state = .expanded
        viewModel?.pinned = pin

        islandPanel.setFrame(currentTargetFrame(), display: true)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)) {
            viewModel?.panelState = .expanded
        }

        if !mouseIsInsideNotchRegion() && !pinned && !isDraggingOver && !mirror.isOn && !mirror.isRequestingPermission {
            scheduleCollapse(in: 0.20)
        }
        applyVisibility()
        updateMonitors()
    }

    func expandForDrag() {
        pendingCollapse?.cancel()
        Haptics.play(.levelChange, disabled: settings.disableHaptics)
        viewModel?.activeTab = .tray
        expand(pin: false)
    }

    func collapse() {
        pendingExpand?.cancel()
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard state == .expanded else { return }
        if mirror.isOn {
            mirror.toggle(false)
        }
        isDraggingOver = false
        viewModel?.isEditingText = false
        islandPanel.makeFirstResponder(nil)
        state = .collapsed
        pinned = false
        viewModel?.pinned = false

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.05)) {
            viewModel?.panelState = .collapsed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self = self, self.state == .collapsed else { return }
            self.islandPanel.setFrame(self.currentTargetFrame(), display: false)
        }
        applyVisibility()
        updateMonitors()
    }

    func togglePinned() {
        Haptics.play(.generic, disabled: settings.disableHaptics)
        if state == .collapsed {
            expand(pin: true)
        } else {
            pinned.toggle()
            viewModel?.pinned = pinned
            if !pinned && !viewModel.isEditingText && !mirror.isOn {
                scheduleCollapse(in: 0.15)
            }
        }
    }

    // MARK: Monitors (mouse tracking, click-away, Esc)

    private func updateMonitors() {
        if state == .expanded {
            if clickAwayMonitor == nil {
                clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    guard let self = self else { return }
                    if !self.mouseIsInsideNotchRegion() && !self.pinned && !self.isDraggingOver && !self.mirror.isRequestingPermission {
                        self.collapse()
                    }
                }
            }
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { // Esc
                        self?.collapse()
                        return nil
                    }
                    return event
                }
            }
            if mouseMoveMonitor == nil {
                mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
                    self?.checkMousePosition()
                }
            }
            if localMouseMoveMonitor == nil {
                localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
                    self?.checkMousePosition()
                    return event
                }
            }
            if hoverCheckTimer == nil {
                hoverCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.checkMousePosition()
                    }
                }
            }
        } else {
            if let m = clickAwayMonitor { NSEvent.removeMonitor(m); clickAwayMonitor = nil }
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = mouseMoveMonitor { NSEvent.removeMonitor(m); mouseMoveMonitor = nil }
            if let m = localMouseMoveMonitor { NSEvent.removeMonitor(m); localMouseMoveMonitor = nil }
            hoverCheckTimer?.invalidate()
            hoverCheckTimer = nil
        }
    }

    private func checkMousePosition() {
        guard state == .expanded else { return }
        let recentMirrorTap = Date().timeIntervalSince(mirror.lastInteractionDate) < 2.2
        guard !pinned, !viewModel.isEditingText, !isDraggingOver, !mirror.isOn, !mirror.isRequestingPermission, !recentMirrorTap else { return }

        if mouseIsInsideNotchRegion() {
            cancelPendingCollapse()
        } else {
            scheduleCollapse(in: 0.15)
        }
    }

    func scheduleCollapse(in seconds: TimeInterval) {
        let recentMirrorTap = Date().timeIntervalSince(mirror.lastInteractionDate) < 2.2
        guard state == .expanded, !pinned, !viewModel.isEditingText, !mirror.isOn, !mirror.isRequestingPermission, !recentMirrorTap else { return }
        if pendingCollapse != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingCollapse = nil
            let isMouseDownOrDragging = (NSEvent.pressedMouseButtons & 1) != 0 || self.isDraggingOver
            let recentTap = Date().timeIntervalSince(self.mirror.lastInteractionDate) < 2.2
            if (self.mouseIsInsideNotchRegion() || self.viewModel.isEditingText || isMouseDownOrDragging || self.mirror.isOn || self.mirror.isRequestingPermission || recentTap) && !self.pinned {
                return
            }
            self.collapse()
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func mouseIsInsideNotchRegion() -> Bool {
        let mouse = NSEvent.mouseLocation
        let expandedRect = islandPanel.frame.insetBy(dx: -8, dy: -8)
        return expandedRect.contains(mouse)
    }

    func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    deinit {
        hoverCheckTimer?.invalidate()
    }
}

// MARK: - Hover, Scroll & Native Multi-File Drag Destination Wrapper
// Handles multi-file drags from Finder, Desktop, and the Dock Downloads Fan/Stack 100% reliably at the AppKit level.

final class HoverCatchingView<Content: View>: NSHostingView<Content> {
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private let onDragEnter: (() -> Void)?
    private let onDragExit: (() -> Void)?
    private let onPerformFileDrop: (([URL]) -> Bool)?
    private let onScrollSwipe: ((CGFloat, CGFloat) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    init(hosting root: Content,
         onEnter: @escaping () -> Void,
         onExit: @escaping () -> Void,
         onDragEnter: (() -> Void)? = nil,
         onDragExit: (() -> Void)? = nil,
         onPerformFileDrop: (([URL]) -> Bool)? = nil,
         onScrollSwipe: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.onEnter = onEnter
        self.onExit = onExit
        self.onDragEnter = onDragEnter
        self.onDragExit = onDragExit
        self.onPerformFileDrop = onPerformFileDrop
        self.onScrollSwipe = onScrollSwipe
        super.init(rootView: root)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    @MainActor required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }

    override func scrollWheel(with event: NSEvent) {
        onScrollSwipe?(event.scrollingDeltaX, event.scrollingDeltaY)
        super.scrollWheel(with: event)
    }

    // MARK: Native AppKit Multi-File Drag & Drop Support

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var extractedURLs: [URL] = []

        // 1. Read all file URLs via NSURL class reader (handles multi-file selection from Finder & Dock Stacks)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            extractedURLs.append(contentsOf: urls)
        }

        // 2. Fallback: Legacy NSFilenamesPboardType array for Dock stacks / third-party apps
        if extractedURLs.isEmpty,
           let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for p in paths {
                extractedURLs.append(URL(fileURLWithPath: p))
            }
        }

        // 3. Fallback: Individual pasteboard items
        if extractedURLs.isEmpty, let items = pb.pasteboardItems {
            for item in items {
                if let str = item.string(forType: .fileURL), let url = URL(string: str) {
                    extractedURLs.append(url)
                }
            }
        }

        if !extractedURLs.isEmpty, let handler = onPerformFileDrop {
            return handler(extractedURLs)
        }
        return super.performDragOperation(sender)
    }
}
