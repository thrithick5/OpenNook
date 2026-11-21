import Foundation
import AppKit
import SwiftUI

// MARK: - App settings (Complete NotchNook + Boring.Notch configuration)

struct Settings: Codable, Equatable {
    // Notch Behavior
    var openOnHover: Bool = true
    var hoverDelay: Double = 0.08
    var enableOnNonNotchScreens: Bool = true
    var followMouseDisplay: Bool = true
    var showInFullscreen: Bool = false
    var hideFromScreenRecording: Bool = false
    var pinnedOpenByDefault: Bool = false
    var enableSwipeGestures: Bool = true
    var naturalGestureDirection: Bool = true

    // Appearance & Sizing
    var contentPadding: Int = 12
    var notchWidthPreset: String = "standard" // "compact", "standard", "wide"
    var notchStyle: String = "notch" // "notch" (concave top ears), "floating" (rounded pill)
    var accentColorName: String = "blue"
    var useDynamicAlbumTint: Bool = true
    var animationSpeed: Double = 1.0 // 0.75 slow, 1.0 normal, 1.35 snappy
    var glassOpacity: Double = 0.96

    // Collapsed Pill & Live Activities
    var showClockOnPill: Bool = true
    var showMiniMusic: Bool = true
    var showBatteryOnPill: Bool = true
    var showSneakPeekOnTrackChange: Bool = true
    var enableHUDReplacement: Bool = true
    var showHUDPercentage: Bool = true
    var enableBatteryLiveActivity: Bool = true
    var enableBluetoothLiveActivity: Bool = true

    // Media & Audio
    var preferredMusicApp: String = "auto" // "auto", "music", "spotify"
    var showRemainingTime: Bool = false
    var showSourceAppBadge: Bool = true
    var visualizerStyle: String = "bars" // "bars", "waveform", "dots"

    // Calendar & Reminders
    var showAllDayEvents: Bool = true
    var showRemindersInCalendar: Bool = true
    var weekStartDay: String = "system" // "system", "sunday", "monday"
    var autoScrollToNextEvent: Bool = true

    // Tray (File Shelf)
    var autoOpenTrayOnDrag: Bool = true
    var reverseTrayOrder: Bool = true
    var removeTrayItemAfterDrag: Bool = false
    var clearTrayOnQuit: Bool = false
    var enableClipboardWatch: Bool = true

    // Mirror
    var mirrorFlipped: Bool = true
    var preferredCameraID: String = "auto"

    // Widgets Visibility in Nook (All fit in one row without sideways scrolling)
    var showMediaWidget: Bool = true
    var showMirrorWidget: Bool = true
    var showCalendarWidget: Bool = true
    var showNotesWidget: Bool = true
    var showTimerWidget: Bool = true
    var showTasksWidget: Bool = false

    // General
    var disableHaptics: Bool = false
    var launchAtLogin: Bool = false
    var keepAwakeDefault: Bool = false
    var menubarIconName: String = "rectangle.topthird.inset"

    static let defaultsKey = "appSettings.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        openOnHover = try c.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? d.openOnHover
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? d.hoverDelay
        enableOnNonNotchScreens = try c.decodeIfPresent(Bool.self, forKey: .enableOnNonNotchScreens) ?? d.enableOnNonNotchScreens
        followMouseDisplay = try c.decodeIfPresent(Bool.self, forKey: .followMouseDisplay) ?? d.followMouseDisplay
        showInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .showInFullscreen) ?? d.showInFullscreen
        hideFromScreenRecording = try c.decodeIfPresent(Bool.self, forKey: .hideFromScreenRecording) ?? d.hideFromScreenRecording
        pinnedOpenByDefault = try c.decodeIfPresent(Bool.self, forKey: .pinnedOpenByDefault) ?? d.pinnedOpenByDefault
        enableSwipeGestures = try c.decodeIfPresent(Bool.self, forKey: .enableSwipeGestures) ?? d.enableSwipeGestures
        naturalGestureDirection = try c.decodeIfPresent(Bool.self, forKey: .naturalGestureDirection) ?? d.naturalGestureDirection

        contentPadding = try c.decodeIfPresent(Int.self, forKey: .contentPadding) ?? d.contentPadding
        notchWidthPreset = try c.decodeIfPresent(String.self, forKey: .notchWidthPreset) ?? d.notchWidthPreset
        notchStyle = try c.decodeIfPresent(String.self, forKey: .notchStyle) ?? d.notchStyle
        accentColorName = try c.decodeIfPresent(String.self, forKey: .accentColorName) ?? d.accentColorName
        useDynamicAlbumTint = try c.decodeIfPresent(Bool.self, forKey: .useDynamicAlbumTint) ?? d.useDynamicAlbumTint
        animationSpeed = try c.decodeIfPresent(Double.self, forKey: .animationSpeed) ?? d.animationSpeed
        glassOpacity = try c.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? d.glassOpacity

        showClockOnPill = try c.decodeIfPresent(Bool.self, forKey: .showClockOnPill) ?? d.showClockOnPill
        showMiniMusic = try c.decodeIfPresent(Bool.self, forKey: .showMiniMusic) ?? d.showMiniMusic
        showBatteryOnPill = try c.decodeIfPresent(Bool.self, forKey: .showBatteryOnPill) ?? d.showBatteryOnPill
        showSneakPeekOnTrackChange = try c.decodeIfPresent(Bool.self, forKey: .showSneakPeekOnTrackChange) ?? d.showSneakPeekOnTrackChange
        enableHUDReplacement = try c.decodeIfPresent(Bool.self, forKey: .enableHUDReplacement) ?? d.enableHUDReplacement
        showHUDPercentage = try c.decodeIfPresent(Bool.self, forKey: .showHUDPercentage) ?? d.showHUDPercentage
        enableBatteryLiveActivity = try c.decodeIfPresent(Bool.self, forKey: .enableBatteryLiveActivity) ?? d.enableBatteryLiveActivity
        enableBluetoothLiveActivity = try c.decodeIfPresent(Bool.self, forKey: .enableBluetoothLiveActivity) ?? d.enableBluetoothLiveActivity

        preferredMusicApp = try c.decodeIfPresent(String.self, forKey: .preferredMusicApp) ?? d.preferredMusicApp
        showRemainingTime = try c.decodeIfPresent(Bool.self, forKey: .showRemainingTime) ?? d.showRemainingTime
        showSourceAppBadge = try c.decodeIfPresent(Bool.self, forKey: .showSourceAppBadge) ?? d.showSourceAppBadge
        visualizerStyle = try c.decodeIfPresent(String.self, forKey: .visualizerStyle) ?? d.visualizerStyle

        showAllDayEvents = try c.decodeIfPresent(Bool.self, forKey: .showAllDayEvents) ?? d.showAllDayEvents
        showRemindersInCalendar = try c.decodeIfPresent(Bool.self, forKey: .showRemindersInCalendar) ?? d.showRemindersInCalendar
        weekStartDay = try c.decodeIfPresent(String.self, forKey: .weekStartDay) ?? d.weekStartDay
        autoScrollToNextEvent = try c.decodeIfPresent(Bool.self, forKey: .autoScrollToNextEvent) ?? d.autoScrollToNextEvent

        autoOpenTrayOnDrag = try c.decodeIfPresent(Bool.self, forKey: .autoOpenTrayOnDrag) ?? d.autoOpenTrayOnDrag
        reverseTrayOrder = try c.decodeIfPresent(Bool.self, forKey: .reverseTrayOrder) ?? d.reverseTrayOrder
        removeTrayItemAfterDrag = try c.decodeIfPresent(Bool.self, forKey: .removeTrayItemAfterDrag) ?? d.removeTrayItemAfterDrag
        clearTrayOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearTrayOnQuit) ?? d.clearTrayOnQuit
        enableClipboardWatch = try c.decodeIfPresent(Bool.self, forKey: .enableClipboardWatch) ?? d.enableClipboardWatch

        mirrorFlipped = try c.decodeIfPresent(Bool.self, forKey: .mirrorFlipped) ?? d.mirrorFlipped
        preferredCameraID = try c.decodeIfPresent(String.self, forKey: .preferredCameraID) ?? d.preferredCameraID

        showMediaWidget = try c.decodeIfPresent(Bool.self, forKey: .showMediaWidget) ?? d.showMediaWidget
        showMirrorWidget = try c.decodeIfPresent(Bool.self, forKey: .showMirrorWidget) ?? d.showMirrorWidget
        showCalendarWidget = try c.decodeIfPresent(Bool.self, forKey: .showCalendarWidget) ?? d.showCalendarWidget
        showNotesWidget = try c.decodeIfPresent(Bool.self, forKey: .showNotesWidget) ?? d.showNotesWidget
        showTimerWidget = try c.decodeIfPresent(Bool.self, forKey: .showTimerWidget) ?? d.showTimerWidget
        showTasksWidget = try c.decodeIfPresent(Bool.self, forKey: .showTasksWidget) ?? false

        disableHaptics = try c.decodeIfPresent(Bool.self, forKey: .disableHaptics) ?? d.disableHaptics
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        keepAwakeDefault = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeDefault) ?? d.keepAwakeDefault
        menubarIconName = try c.decodeIfPresent(String.self, forKey: .menubarIconName) ?? d.menubarIconName
    }

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Settings.defaultsKey)
        }
    }

    static let accentHex: [String: UInt32] = [
        "blue": 0x2f6fed,
        "purple": 0x8a51d8,
        "pink": 0xe4498f,
        "orange": 0xf08422,
        "green": 0x32b25d,
        "cyan": 0x15b0bc,
        "red": 0xe04141,
        "indigo": 0x5856d6,
        "mint": 0x00c7be
    ]

    var expandedMaxWidth: CGFloat {
        switch notchWidthPreset {
        case "compact": return 820
        case "wide": return 1120
        default: return 960
        }
    }

    var expandedMaxHeight: CGFloat {
        switch notchWidthPreset {
        case "compact": return 178
        case "wide": return 224
        default: return 198
        }
    }

    var widgetScaleFactor: CGFloat {
        switch notchWidthPreset {
        case "compact": return 0.84
        case "wide": return 1.14
        default: return 1.00
        }
    }
}

// MARK: - Haptic Feedback Manager (Force Touch Trackpad support)

enum Haptics {
    static func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment, disabled: Bool = false) {
        guard !disabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - Tasks

struct TaskItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var done: Bool = false
    var starred: Bool = false
    var createdAt: Date = Date()
}

// MARK: - Clipboard Item

struct ClipboardItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var content: String
    var copiedAt: Date = Date()

    var preview: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Tray (dragged files)

struct TrayItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var path: String
    var addedAt: Date = Date()

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var fileExtension: String {
        let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }
    var fileURL: URL { URL(fileURLWithPath: path) }
    var isImage: Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"].contains(ext)
    }

    var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - AirDrop, Sharing & Archive helpers

@MainActor
enum AirDropHelper {
    static func shareFileViaAirDrop(_ path: String) {
        shareFilesViaAirDrop([path])
    }

    static func shareFilesViaAirDrop(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            // Fallback to general share picker anchored on active window if AirDrop isn't directly available
            if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
                let picker = NSSharingServicePicker(items: urls)
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        }
    }

    static func showShareMenu(for paths: [String], in view: NSView?) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        guard let targetView = view ?? NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: targetView.bounds, of: targetView, preferredEdge: .minY)
    }

    static func zipFiles(_ paths: [String], completion: @escaping (URL?) -> Void) {
        let validPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !validPaths.isEmpty else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let tempDir = FileManager.default.temporaryDirectory
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let zipName = validPaths.count == 1
                ? "\(URL(fileURLWithPath: validPaths[0]).deletingPathExtension().lastPathComponent).zip"
                : "OpenNook-Archive-\(formatter.string(from: Date())).zip"
            let destURL = tempDir.appendingPathComponent(zipName)
            try? FileManager.default.removeItem(at: destURL)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = ["-r", "-j", destURL.path] + validPaths
            try? proc.run()
            proc.waitUntilExit()
            let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: destURL.path)
            DispatchQueue.main.async {
                completion(ok ? destURL : nil)
            }
        }
    }
}

enum SystemShortcuts {
    static func takeScreenshot() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: ["-i", "-c"])
    }

    static func takeScreenshotFull() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: ["-c"])
    }

    static func recordScreenInteractive() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: ["-i", "-v"])
    }

    static func lockScreen() {
        let sc = "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func sleepDisplay() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
    }

    static func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    static func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    static func emptyTrash() {
        let sc = "tell application \"Finder\" to empty trash"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func toggleDarkMode() {
        let sc = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    @MainActor
    static func pickColorToClipboard(completion: ((String?) -> Void)? = nil) {
        let sampler = NSColorSampler()
        sampler.show { selectedColor in
            guard let color = selectedColor?.usingColorSpace(.sRGB) else {
                completion?(nil)
                return
            }
            let r = Int(round(color.redComponent * 255))
            let g = Int(round(color.greenComponent * 255))
            let b = Int(round(color.blueComponent * 255))
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            completion?(hex)
        }
    }
}

// MARK: - Store (tasks + tray + notes + clipboard), persisted as JSON in Application Support

final class Store: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var trayItems: [TrayItem] = []
    @Published var selectedTrayIDs: Set<UUID> = []
    @Published var notes: String = ""
    @Published var clipboardHistory: [ClipboardItem] = []

    private let fileURL: URL
    private let workerQueue = DispatchQueue(label: "com.opennook.store")

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenNook", isDirectory: true)
        self.fileURL = base.appendingPathComponent("data.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            tasks = []
            trayItems = []
            notes = ""
            clipboardHistory = []
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let raw = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(StorePayload.self, from: raw)
                tasks = decoded.tasks
                trayItems = decoded.trayItems
                notes = decoded.notes
                clipboardHistory = decoded.clipboardHistory ?? []
            }
        } catch {
            tasks = []
            trayItems = []
            notes = ""
            clipboardHistory = []
        }
    }

    private struct StorePayload: Codable {
        var schema: Int = 2
        var tasks: [TaskItem] = []
        var trayItems: [TrayItem] = []
        var notes: String = ""
        var clipboardHistory: [ClipboardItem]? = []
    }

    private func persist() {
        let payload = StorePayload(tasks: tasks, trayItems: trayItems, notes: notes, clipboardHistory: clipboardHistory)
        let url = fileURL
        workerQueue.async {
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func updateNotes(_ newNotes: String) {
        guard notes != newNotes else { return }
        notes = newNotes
        persist()
    }

    // Clipboard
    func addClipboardSnippet(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if clipboardHistory.first?.content == trimmed { return }
        clipboardHistory.removeAll { $0.content == trimmed }
        clipboardHistory.insert(ClipboardItem(content: trimmed), at: 0)
        if clipboardHistory.count > 15 {
            clipboardHistory = Array(clipboardHistory.prefix(15))
        }
        persist()
    }

    func clearClipboardHistory() {
        clipboardHistory.removeAll()
        persist()
    }

    // Tasks
    func addTask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.insert(TaskItem(title: trimmed), at: 0)
        sortTasks()
        persist()
    }

    func toggleTask(_ id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].done.toggle()
        }
        sortTasks()
        persist()
    }

    func toggleStarTask(_ id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].starred.toggle()
        }
        sortTasks()
        persist()
    }

    func removeTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    func clearCompletedTasks() {
        tasks.removeAll { $0.done }
        persist()
    }

    private func sortTasks() {
        tasks.sort { a, b in
            if a.done != b.done { return !a.done }
            if a.starred != b.starred { return a.starred }
            return a.createdAt > b.createdAt
        }
    }

    // Tray
    @discardableResult
    func addTrayItem(path: String, reverseOrder: Bool = true) -> Bool {
        guard !path.isEmpty, !trayItems.contains(where: { $0.path == path }) else { return false }
        let item = TrayItem(path: path)
        if reverseOrder {
            trayItems.insert(item, at: 0)
        } else {
            trayItems.append(item)
        }
        persist()
        return true
    }

    func removeTrayItem(_ id: UUID) {
        trayItems.removeAll { $0.id == id }
        selectedTrayIDs.remove(id)
        persist()
    }

    func clearTray() {
        trayItems.removeAll()
        selectedTrayIDs.removeAll()
        persist()
    }

    func toggleTraySelection(_ id: UUID, exclusive: Bool = false) {
        if exclusive {
            if selectedTrayIDs == [id] {
                selectedTrayIDs.removeAll()
            } else {
                selectedTrayIDs = [id]
            }
        } else {
            if selectedTrayIDs.contains(id) {
                selectedTrayIDs.remove(id)
            } else {
                selectedTrayIDs.insert(id)
            }
        }
    }

    func cleanMissingTrayItems() {
        let before = trayItems.count
        trayItems.removeAll { !$0.exists }
        let validIDs = Set(trayItems.map(\.id))
        selectedTrayIDs = selectedTrayIDs.intersection(validIDs)
        if trayItems.count != before { persist() }
    }
}

// MARK: - Notch geometry & Custom Concave Ear Shape

struct NotchGeometry {
    /// Returns the hardware notch rect (top-center), in screen coordinates,
    /// or nil when the screen has no notch.
    static func notchRect(for frame: NSRect, leftInset: CGFloat, topInset: CGFloat) -> NSRect? {
        guard topInset > 0, topInset < frame.height else { return nil }
        let x = frame.minX + leftInset
        let y = frame.maxY - topInset
        let width = frame.width - leftInset * 2
        return NSRect(x: x, y: y, width: width, height: topInset)
    }

    /// Collapsed handle frame: a sleek pill centered under (and overlapping) the notch.
    static func handleRect(notch: NSRect?, screenFrame: NSRect, handleWidth: CGFloat = 380, faceHeight: CGFloat = 26, blendHeight: CGFloat = 32) -> NSRect {
        let hWidth = min(max(handleWidth, screenFrame.width * 0.15), screenFrame.width * 0.9)
        let cx = screenFrame.midX
        let top = screenFrame.maxY
        if let notch = notch {
            let blend = max(blendHeight, notch.height)
            let h = blend + faceHeight
            return NSRect(x: cx - hWidth / 2, y: top - h, width: hWidth, height: h)
        } else {
            return NSRect(x: cx - hWidth / 2, y: top - faceHeight, width: hWidth, height: faceHeight)
        }
    }
}

/// Authentic NotchNook / Boring.Notch silhouette with smooth concave top ears
/// that curve outward into the menu bar edge and rounded convex bottom corners.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 10, bottomCornerRadius: CGFloat = 22) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tr = min(topCornerRadius, rect.width / 6, rect.height / 3)
        let br = min(bottomCornerRadius, rect.width / 3, rect.height / 2)

        // Start at top-left outer flare
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Concave curve down into left vertical wall
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        // Left vertical line down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        // Convex bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        // Bottom horizontal edge
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        // Convex bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        // Right vertical line up to top-right ear
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        // Concave curve out to top-right flare
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Timer logic (pure, testable)

struct CountdownState: Codable, Equatable {
    var totalSeconds: Int
    var remaining: Int
    var running: Bool = false
    var label: String = ""

    mutating func start(totalSeconds: Int, label: String) {
        self.totalSeconds = max(1, totalSeconds)
        self.remaining = self.totalSeconds
        self.running = true
        self.label = label
    }

    mutating func tick(_ seconds: Int = 1) {
        guard running else { return }
        remaining = max(0, remaining - seconds)
        if remaining == 0 { running = false }
    }

    mutating func adjustDuration(by deltaSeconds: Int) {
        let next = max(0, remaining + deltaSeconds)
        remaining = next
        totalSeconds = max(totalSeconds, next)
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - remaining) / Double(totalSeconds)
    }

    static func formatHRMN(_ total: Int) -> String {
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Media info value type

struct MediaInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var app: String = ""
    var bundleIdentifier: String = ""
    var playing: Bool = false
    var duration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var artworkData: Data? = nil
    var isShuffling: Bool = false
    var isRepeating: Bool = false
    var isLiked: Bool = false
    var appVolume: Double = 100
    var dominantColorHex: UInt32? = nil

    var hasContent: Bool { !title.isEmpty }

    var sourceDisplayName: String {
        let lower = app.lowercased()
        if lower.contains("music") || bundleIdentifier.contains("com.apple.Music") { return "Apple Music" }
        if lower.contains("spotify") || bundleIdentifier.contains("spotify") { return "Spotify" }
        if lower.contains("youtube") || lower.contains("pear") { return "YouTube Music" }
        if lower.contains("safari") || lower.contains("chrome") || lower.contains("arc") { return "Browser Audio" }
        return app.isEmpty ? "Now Playing" : app
    }

    /// Parse MRMediaRemoteGetNowPlayingInfo's dictionary into MediaInfo.
    static func fromMRDictionary(_ dict: [String: Any]) -> MediaInfo? {
        let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = dict["kMRMediaRemoteNowPlayingInfoApplicationIdentifier"] as? String ?? ""

        // Reject stale web feeds and non-music social media sessions from MediaRemote
        let socialFeeds = ["instagram", "facebook", "twitter", "tiktok", "reddit", "threads", "linkedin"]
        if socialFeeds.contains(title.lowercased()) && artist.isEmpty && album.isEmpty {
            return nil
        }

        // In macOS MediaRemote, playback rate > 0 indicates active playback
        let playbackRate: Double = {
            if let d = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double { return d }
            if let num = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber { return num.doubleValue }
            return 0.0
        }()
        let playingAny = dict["kMRMediaRemoteNowPlayingInfoIsPlaying"]
        let playing: Bool
        if playbackRate > 0.001 {
            playing = true
        } else if let b = playingAny as? Bool {
            playing = b
        } else if let num = playingAny as? NSNumber {
            playing = num.boolValue
        } else {
            playing = false
        }

        let duration: Double = {
            if let d = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double { return d }
            if let num = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber { return num.doubleValue }
            return 0.0
        }()
        let baseElapsed: Double = {
            if let d = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double { return d }
            if let num = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber { return num.doubleValue }
            return 0.0
        }()
        let elapsed: Double = {
            if playing, let ts = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                let delta = max(0, Date().timeIntervalSince(ts))
                let rate = playbackRate > 0.001 ? playbackRate : 1.0
                let computed = baseElapsed + delta * rate
                return duration > 0 ? min(duration, computed) : computed
            }
            return baseElapsed
        }()

        let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let appName: String = {
            let lower = appID.lowercased()
            if lower.contains("brave") || lower.contains("chrome") || lower.contains("safari") || lower.contains("arc") {
                if album.lowercased().contains("youtube") || artist.lowercased().contains("youtube") || title.lowercased().contains("youtube") {
                    return "YouTube Music"
                }
                return "YouTube Music"
            }
            if appID.isEmpty { return "Now Playing" }
            return appID.split(separator: ".").last.map(String.init) ?? appID
        }()
        let domHex = artworkData.flatMap { ArtworkColorExtractor.extractDominantHex(from: $0) }
        return MediaInfo(title: title, artist: artist, album: album, app: appName,
                         bundleIdentifier: appID, playing: playing,
                         duration: duration, elapsedTime: elapsed,
                         artworkData: artworkData, dominantColorHex: domHex)
    }
}

// MARK: - Artwork Dominant Color Extractor

enum ArtworkColorExtractor {
    static func extractDominantHex(from data: Data) -> UInt32? {
        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = 8
        let height = 8
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rTotal: Int = 0
        var gTotal: Int = 0
        var bTotal: Int = 0
        var count: Int = 0

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let r = Int(pixelData[i])
            let g = Int(pixelData[i + 1])
            let b = Int(pixelData[i + 2])
            let brightness = (r + g + b) / 3
            // Skip near-black and near-white pixels for vibrant tint
            if brightness > 28 && brightness < 235 {
                rTotal += r
                gTotal += g
                bTotal += b
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let rAvg = UInt32(min(255, max(50, rTotal / count)))
        let gAvg = UInt32(min(255, max(50, gTotal / count)))
        let bAvg = UInt32(min(255, max(50, bTotal / count)))
        return (rAvg << 16) | (gAvg << 8) | bAvg
    }
}

// MARK: - Live Activity / HUD Overlay State

struct LiveActivityAlert: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case volume = "Volume"
        case brightness = "Brightness"
        case backlight = "Keyboard"
        case battery = "Battery"
        case media = "Now Playing"
        case bluetooth = "Bluetooth"
        case timer = "Timer"
        case meeting = "Meeting"
        case clipboard = "Copied"
        case caffeine = "Caffeine"
    }

    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var subtitle: String = ""
    var icon: String
    var value: Double? = nil // 0.0...1.0 for HUD progress bars
    var accentHex: UInt32? = nil
}

// MARK: - Small helpers

enum Format {
    static func clock(from date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d", h12, m)
    }

    static func dateShort(_ date: Date, calendar: Calendar = .current) -> String {
        let mon = calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1]
        return "\(mon) \(calendar.component(.day, from: date))"
    }

    static func duration(_ totalSeconds: TimeInterval) -> String {
        let s = Int(max(0, totalSeconds))
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }
}
