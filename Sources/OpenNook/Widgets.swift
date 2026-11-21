import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Shared view model bridging AppKit controllers to SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum PanelState { case collapsed, expanded }
    enum ActiveTab: String, CaseIterable {
        case nook = "Nook"
        case tray = "Tray"
        case shortcuts = "Controls"

        static var widgets: ActiveTab { .nook }
        static var shelf: ActiveTab { .tray }
    }

    @Published var panelState: PanelState = .collapsed
    @Published var activeTab: ActiveTab = .nook
    @Published var pinned: Bool = false
    @Published var now = Date()
    @Published var pillBlendHeight: CGFloat = 32
    @Published var hardwareNotchWidth: CGFloat = 184
    @Published var isHoveringPill: Bool = false
    @Published var isHoveringPanel: Bool = false
    @Published var isEditingText: Bool = false
    @Published var isDraggingFilesOver: Bool = false
    @Published var isLightMode: Bool = NotchViewModel.detectSystemLightMode()

    let store: Store
    let settingsStore: SettingsStore
    let media: MediaProvider
    let calendar: CalendarProvider
    let timerModel: TimerModel
    let mirror: MirrorService
    let systemMonitor: SystemMonitor

    private var cancellables: Set<AnyCancellable> = []
    private var themeObserver: NSObjectProtocol?

    var settings: Settings { settingsStore.settings }

    var onRequestExpand: (() -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onRequestPin: (() -> Void)?
    var onOpenMirror: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onNewTaskFieldSubmit: ((String) -> Void)?
    var onHoverEnterPanel: (() -> Void)?
    var onHoverExitPanel: (() -> Void)?
    var onFocusTextField: (() -> Void)?

    static func detectSystemLightMode() -> Bool {
        // Prefer the system's real appearance over an app-internal dark mode that the rest of the
        // panel does not follow. An accessory-status-bar app can be semi-transparent over other
        // windows, so the most reliable read is whatever appearance the panel is currently being
        // rendered with, falling back to the app-wide appearance only when that is unavailable.
        if Thread.isMainThread, let panel = NSApp?.windows.first(where: { $0 is NSWindow && $0.level == .statusBar + 1 && !$0.isVisible == false }) {
            if let appearance = panel.effectiveAppearance {
                let match = appearance.bestMatch(from: [.aqua, .darkAqua])
                if match == .darkAqua {
                    return false
                }
                if match == .aqua {
                    return true
                }
            }
        }
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
           style.lowercased().contains("dark") {
            return false
        }
        if let app = NSApp {
            let match = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            if let match = match {
                return match == .aqua
            }
        }
        return true
    }

    func refreshAppearance() {
        let current = Self.detectSystemLightMode()
        if isLightMode != current {
            withAnimation(.easeInOut(duration: 0.22)) {
                isLightMode = current
            }
        }
    }

    init(store: Store, media: MediaProvider, calendar: CalendarProvider,
         timerModel: TimerModel, settingsStore: SettingsStore, mirror: MirrorService,
         systemMonitor: SystemMonitor? = nil,
         pillBlendHeight: CGFloat = 32,
         hardwareNotchWidth: CGFloat = 184) {
        let sys = systemMonitor ?? .shared
        self.store = store
        self.media = media
        self.calendar = calendar
        self.timerModel = timerModel
        self.settingsStore = settingsStore
        self.mirror = mirror
        self.systemMonitor = sys
        self.pillBlendHeight = pillBlendHeight
        self.hardwareNotchWidth = hardwareNotchWidth
        self.isLightMode = Self.detectSystemLightMode()
        store.cleanMissingTrayItems()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        media.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        calendar.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        timerModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        mirror.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sys.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppearance()
            }
        }

        let clockTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
                self?.refreshAppearance()
            }
        }
        RunLoop.main.add(clockTimer, forMode: .common)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidChangeScreenParameters),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // The accessory status-bar panel can be composited over windows that themselves change the
        // effective appearance mid-frame (e.g. a light app running above a dark one, or vice versa).
        // The safest refresh point for system-theme parity is therefore just before each frame paint
        // rather than only on the high-level theme-change notification.
        let appearanceRefreshTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppearance()
            }
        }
        RunLoop.main.add(appearanceRefreshTimer, forMode: .common)
    }

    @objc private func applicationDidChangeScreenParameters() {
        refreshAppearance()
    }

    convenience init(store: Store, media: MediaProvider, calendar: CalendarProvider,
                     timerModel: TimerModel, settings: Settings, mirror: MirrorService,
                     pillBlendHeight: CGFloat = 32) {
        let ss = SettingsStore(initial: settings)
        self.init(store: store, media: media, calendar: calendar, timerModel: timerModel,
                  settingsStore: ss, mirror: mirror, systemMonitor: .shared,
                  pillBlendHeight: pillBlendHeight)
    }

    var accent: Color {
        if settings.useDynamicAlbumTint,
           media.info.hasContent,
           let dynHex = media.info.dominantColorHex {
            return Color(hex: dynHex)
        }
        return Color(hex: Settings.accentHex[settings.accentColorName] ?? 0x0a84ff)
    }
}

// MARK: - Native macOS Frosted Liquid Glass Material

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Clean Liquid Glass Pod Surface (Concentric & Crisp)
// Uses the shared system-theme state so every Nook card tracks the system appearance,
// including the expanded panel that SwiftUI does not otherwise theme automatically.

struct IslandPodSurface<Content: View>: View {
    @ObservedObject var vm: NotchViewModel
    var cornerRadius: CGFloat = 18
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 9
    let content: Content

    init(cornerRadius: CGFloat = 18,
         horizontalPadding: CGFloat = 10,
         verticalPadding: CGFloat = 9,
         vm: NotchViewModel,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.vm = vm
        self.content = content()
    }

    var body: some View {
        let isLight = vm.isLightMode
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isLight
                            ? LinearGradient(
                                colors: [Color.white.opacity(0.78), Color.white.opacity(0.68)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95),
                                    Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.95)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                isLight
                                    ? LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.95),
                                            Color.white.opacity(0.60),
                                            Color.black.opacity(0.06)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.32),
                                            Color.white.opacity(0.14),
                                            Color.white.opacity(0.22)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                lineWidth: 0.9
                            )
                    )
            )
    }
}

// MARK: - macOS Tahoe Control Center Custom Slider

struct TahoeControlSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.0...1.0
    @ObservedObject var vm: NotchViewModel

    @State private var isDragging = false

    var body: some View {
        let isLight = vm.isLightMode
        GeometryReader { geo in
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let normalized = min(1.0, max(0.0, (value - range.lowerBound) / span))
            let trackHeight: CGFloat = 5.5
            let thumbSize: CGFloat = 15
            let usableWidth = max(1, geo.size.width - thumbSize)
            let thumbX = CGFloat(normalized) * usableWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.22))
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color.white)
                    .frame(width: max(trackHeight, thumbX + thumbSize * 0.5), height: trackHeight)

                Circle()
                    .fill(Color(white: isDragging ? 0.98 : 0.92))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(isLight ? 0.25 : 0.45), radius: 2, y: 1)
                    .offset(x: thumbX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let ratio = min(1.0, max(0.0, Double((gesture.location.x - thumbSize * 0.5) / usableWidth)))
                        value = range.lowerBound + ratio * span
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
    }
}

// MARK: - Apple Fluid Design: Instant Pointer-Down Pressable Button Style

struct ApplePressableButtonStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? 0.10 : 0.0)
            .animation(.spring(response: 0.20, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - AppKit-backed Focusable Multiline Note Editor

struct FocusableNoteTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11.0
    var onFocusChange: (Bool) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FocusableNoteTextView
        init(_ parent: FocusableNoteTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class ClickFocusingTextView: NSTextView {
        var onMouseDownCallback: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onMouseDownCallback?()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ClickFocusingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onMouseDownCallback = {
            context.coordinator.parent.onFocusChange(true)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
    }
}

// MARK: - AppKit-backed Focusable Single-Line TextField

struct FocusableLineField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableLineField
        init(_ parent: FocusableLineField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange(false)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class ClickFocusingTextField: NSTextField {
        var onActivate: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onActivate?()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            super.mouseDown(with: event)
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = ClickFocusingTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        tf.textColor = NSColor.labelColor
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .regular)
            ]
        )
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.onActivate = {
            context.coordinator.parent.onFocusChange(true)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }
}

// MARK: - AppKit-backed Typable Numeric Timer Dial Field

struct FocusableTimerDigitField: NSViewRepresentable {
    @Binding var value: Int
    var maxLimit: Int
    var fontSize: CGFloat = 13.0
    var isRunning: Bool
    var onCommitValue: (Int, Bool) -> Void
    var onStepValue: (Int) -> Void
    var onFocusChange: (Bool) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTimerDigitField
        var isEditing = false

        init(_ parent: FocusableTimerDigitField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            parent.onFocusChange(true)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let digitsOnly = tf.stringValue.filter { $0.isNumber }
            let clipped = String(digitsOnly.suffix(2))
            if tf.stringValue != clipped {
                tf.stringValue = clipped
            }
            if let parsed = Int(clipped) {
                parent.onCommitValue(min(parent.maxLimit, max(0, parsed)), false)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let tf = obj.object as? NSTextField else {
                parent.onFocusChange(false)
                return
            }
            let digitsOnly = tf.stringValue.filter { $0.isNumber }
            let parsed = min(parent.maxLimit, max(0, Int(digitsOnly) ?? 0))
            tf.stringValue = String(format: "%02d", parsed)
            parent.onCommitValue(parsed, false)
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                isEditing = false
                let digitsOnly = control.stringValue.filter { $0.isNumber }
                let parsed = min(parent.maxLimit, max(0, Int(digitsOnly) ?? 0))
                control.stringValue = String(format: "%02d", parsed)
                parent.onCommitValue(parsed, true)
                control.window?.makeFirstResponder(nil)
                parent.onFocusChange(false)
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onStepValue(1)
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onStepValue(-1)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class TimerDigitNSTextField: NSTextField {
        var onActivate: (() -> Void)?
        var onScrollStep: ((Int) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onActivate?()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            super.mouseDown(with: event)
            if let editor = currentEditor() {
                editor.selectAll(nil)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 1.0 {
                onScrollStep?(event.scrollingDeltaY > 0 ? 1 : -1)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = TimerDigitNSTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.alignment = .center
        tf.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        tf.textColor = NSColor(srgbRed: 10.0 / 255.0, green: 132.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
        tf.stringValue = String(format: "%02d", value)
        tf.onActivate = {
            context.coordinator.parent.onFocusChange(true)
        }
        tf.onScrollStep = { delta in
            context.coordinator.parent.onStepValue(delta)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        nsView.textColor = NSColor(srgbRed: 10.0 / 255.0, green: 132.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
        if !context.coordinator.isEditing {
            let formatted = String(format: "%02d", value)
            if nsView.stringValue != formatted {
                nsView.stringValue = formatted
            }
        }
    }
}

// MARK: - Unified Single-Window Morphing Apple Dynamic Island Root View (Zero Drop Shadow)

struct DynamicIslandRootView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        ZStack(alignment: .top) {
            if vm.panelState == .collapsed {
                CollapsedPillView(vm: vm)
            } else {
                ExpandedPanelView(vm: vm)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Animated Equalizer Waveform

struct AudioEqualizerView: View {
    let isPlaying: Bool
    let accent: Color
    var compact: Bool = false
    var style: String = "bars"

    var body: some View {
        HStack(spacing: compact ? 2 : 2.5) {
            if style == "dots" {
                ForEach(0..<4, id: \.self) { idx in
                    Circle()
                        .fill(accent)
                        .frame(width: compact ? 3.5 : 4.5, height: compact ? 3.5 : 4.5)
                        .scaleEffect(isPlaying ? 1.2 : 0.7)
                        .opacity(isPlaying ? 1.0 : 0.45)
                        .animation(
                            isPlaying
                                ? Animation.easeInOut(duration: 0.42)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(idx) * 0.11)
                                : .easeOut(duration: 0.18),
                            value: isPlaying
                        )
                }
            } else {
                bar(heightFactor: isPlaying ? 0.88 : 0.25, delay: 0.0)
                bar(heightFactor: isPlaying ? 0.48 : 0.25, delay: 0.14)
                bar(heightFactor: isPlaying ? 1.00 : 0.25, delay: 0.28)
                bar(heightFactor: isPlaying ? 0.62 : 0.25, delay: 0.42)
                if !compact {
                    bar(heightFactor: isPlaying ? 0.76 : 0.25, delay: 0.20)
                }
            }
        }
        .frame(height: compact ? 11 : 15)
    }

    private func bar(heightFactor: CGFloat, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(accent)
            .frame(width: compact ? 2.2 : 2.8,
                   height: isPlaying ? max(3.5, (compact ? 11 : 15) * heightFactor) : 3)
            .animation(
                isPlaying
                    ? Animation.easeInOut(duration: 0.44)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    : .easeOut(duration: 0.18),
                value: isPlaying
            )
    }
}

// MARK: - Album Artwork

struct AlbumArtView: View {
    let info: MediaInfo
    let accent: Color
    var size: CGFloat = 42
    var showBadge: Bool = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let data = info.artworkData, let nsImg = NSImage(data: data) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .foregroundColor(.white.opacity(0.65))
                    }
                    .frame(width: size, height: size)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            )

            if showBadge && info.hasContent {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.9))
                        .frame(width: 14, height: 14)
                    Image(systemName: info.sourceDisplayName == "Spotify" ? "waveform.circle.fill" : "music.note")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(info.sourceDisplayName == "Spotify" ? Color(hex: 0x1ED760) : .white)
                }
                .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Interactive Music Progress Scrubber (Inline Timestamp + Bar + Duration matching Video)

struct MusicScrubberView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaProvider
    var scale: CGFloat = 1.0
    @State private var isHovering = false
    @State private var dragPosition: Double?

    init(vm: NotchViewModel, scale: CGFloat = 1.0) {
        self.vm = vm
        self.media = vm.media
        self.scale = scale
    }

    var body: some View {
        let duration = max(1, media.info.duration > 0 ? media.info.duration : 180)
        let elapsed = dragPosition ?? media.info.elapsedTime
        let progress = min(1.0, max(0.0, elapsed / duration))
        let rightTimeText = vm.settings.showRemainingTime
            ? "-\(Format.duration(max(0, duration - elapsed)))"
            : Format.duration(duration)

        HStack(spacing: 7 * scale) {
            Text(Format.duration(elapsed))
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Color.white.opacity(0.48))
                .fixedSize(horizontal: true, vertical: false)

            GeometryReader { geo in
                let barHeight = (isHovering || dragPosition != nil ? 5.0 : 3.6) * scale
                let thumbDiameter = (isHovering || dragPosition != nil ? 9.0 : 0.0) * scale
                let fillWidth = max(0, min(geo.size.width, geo.size.width * CGFloat(progress)))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: barHeight)

                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: fillWidth, height: barHeight)

                    if isHovering || dragPosition != nil {
                        Circle()
                            .fill(Color.white)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .offset(x: max(0, min(geo.size.width - thumbDiameter, fillWidth - thumbDiameter * 0.5)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let ratio = min(1.0, max(0.0, Double(val.location.x / max(1, geo.size.width))))
                            dragPosition = ratio * duration
                        }
                        .onEnded { val in
                            let ratio = min(1.0, max(0.0, Double(val.location.x / max(1, geo.size.width))))
                            let newPos = ratio * duration
                            Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                            media.seek(to: newPos)
                            dragPosition = nil
                        }
                )
            }
            .frame(height: 12 * scale)
            .onHover { hovering in
                withAnimation(.spring(response: 0.20, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }

            Button {
                vm.settingsStore.settings.showRemainingTime.toggle()
            } label: {
                Text(rightTimeText)
                    .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Color.white.opacity(0.48))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Collapsed Pill (Hidden Strictly Under the Physical Camera Notch — Zero Desktop Expansion)

struct CollapsedPillView: View {
    @ObservedObject var vm: NotchViewModel

    init(vm: NotchViewModel) {
        self.vm = vm
    }

    var body: some View {
        Color.black.opacity(0.001)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering && vm.settings.openOnHover {
                    vm.onRequestExpand?()
                }
            }
            .onTapGesture {
                vm.onRequestExpand?()
            }
            .onDrop(of: [.fileURL, .plainText], delegate: TrayDropDelegate(vm: vm))
    }
}

// MARK: - Type-erased Shape helper

struct AnyShape: Shape, @unchecked Sendable {
    private let _path: @Sendable (CGRect) -> Path
    init<S: Shape & Sendable>(_ shape: S) {
        _path = { rect in shape.path(in: rect) }
    }
    func path(in rect: CGRect) -> Path { _path(rect) }
}

// MARK: - Expanded Panel (Matches Video 1:1 — Pure Black Notch, Horizontal Nook Strip & Dual Drop Zones)

struct ExpandedPanelView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let useNotchShape = vm.settings.notchStyle == "notch"
        let topEarRadius: CGFloat = 12
        let bottomRadius: CGFloat = 24
        let earInset: CGFloat = useNotchShape ? topEarRadius : 0
        let innerMargin: CGFloat = 14

        VStack(spacing: 6) {
            TopBarView(vm: vm)
                .frame(height: max(28, vm.pillBlendHeight))

            ZStack {
                if vm.isDraggingFilesOver {
                    NotchDragDropOverlayView(vm: vm)
                } else {
                    switch vm.activeTab {
                    case .nook:
                        HorizontalWidgetsStripView(vm: vm)
                    case .tray:
                        NotchTrayStripView(vm: vm)
                    case .shortcuts:
                        NotchShortcutsAndHUDStripView(vm: vm)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, earInset + innerMargin)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(isLight ? Color.white.opacity(0.10) : .black)

                if useNotchShape {
                    NotchShape(topCornerRadius: topEarRadius, bottomCornerRadius: bottomRadius)
                        .stroke(isLight ? Color.white.opacity(0.25) : Color.white.opacity(0.12), lineWidth: 1.0)
                } else {
                    RoundedRectangle(cornerRadius: bottomRadius, style: .continuous)
                        .strokeBorder(isLight ? Color.white.opacity(0.25) : Color.white.opacity(0.12), lineWidth: 1.0)
                }
            }
            .clipShape(
                useNotchShape
                    ? AnyShape(NotchShape(topCornerRadius: topEarRadius, bottomCornerRadius: bottomRadius))
                    : AnyShape(RoundedRectangle(cornerRadius: bottomRadius, style: .continuous))
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { vm.onHoverEnterPanel?() } else { vm.onHoverExitPanel?() }
        }
        .onDrop(of: [.fileURL, .plainText], delegate: TrayDropDelegate(vm: vm))
    }
}

// MARK: - Full-Width Drag-and-Drop Overlay ("Drop files here" with Blue Outer Dashed Lining Only, No Blue Shade or AirDrop)

struct NotchDragDropOverlayView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            Color(hex: 0x0a84ff),
                            style: StrokeStyle(lineWidth: 1.0, dash: [5, 4])
                        )
                )

            Text("Drop files here")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(hex: 0x0a84ff)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top Navigation Bar (Clean Nook & Tray Tabs on Left + Camera Clearance + Quick Actions on Right)

struct TopBarView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var sys = SystemMonitor.shared
    @ObservedObject private var store: Store

    init(vm: NotchViewModel) {
        self.vm = vm
        self.store = vm.store
    }

    var body: some View {
        let centerCutout = max(168, vm.hardwareNotchWidth)

        GeometryReader { geo in
            let wingWidth = max(150, (geo.size.width - centerCutout) / 2.0)

            HStack(spacing: 0) {
                // LEFT WING: Nook & Tray (plus Controls) matching Video Top-Left Tabs
                HStack(spacing: 14) {
                    cleanTabButton(tab: .nook, icon: "sparkles", title: "Nook", badge: nil)
                    cleanTabButton(tab: .tray, icon: "tray.fill", title: "Tray", badge: store.trayItems.isEmpty ? nil : store.trayItems.count)
                    cleanTabButton(tab: .shortcuts, icon: "slider.horizontal.3", title: "Controls", badge: nil)
                }
                .frame(width: wingWidth, alignment: .leading)

                // CENTER CLEARANCE FOR PHYSICAL CAMERA NOTCH
                Spacer().frame(width: centerCutout)

                // RIGHT WING: Size Preset Cycle + Subtle Status & Quick Action Icons
                HStack(spacing: 6) {
                    Spacer(minLength: 0)

                    Button {
                        Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                        let current = vm.settings.notchWidthPreset
                        let next: String = {
                            switch current {
                            case "compact": return "standard"
                            case "standard": return "wide"
                            default: return "compact"
                            }
                        }()
                        vm.settingsStore.settings.notchWidthPreset = next
                    } label: {
                        let sizeLabel: String = {
                            switch vm.settings.notchWidthPreset {
                            case "compact": return "Compact"
                            case "wide": return "Large"
                            default: return "Standard"
                            }
                        }()
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(sizeLabel)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                    .help("Cycle Notch & Widget Size (Compact / Standard / Large)")

                    Button {
                        Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                        vm.onOpenMirror?()
                    } label: {
                        Image(systemName: vm.mirror.isOn ? "web.camera.fill" : "web.camera")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(vm.mirror.isOn ? Color(hex: 0x30d158) : .white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(vm.mirror.isOn ? 0.18 : 0.08)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                    .help("Toggle Mirror")

                    Button {
                        Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                        vm.onOpenSettings?()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                    .help("OpenNook Settings")

                    Button {
                        vm.onRequestPin?()
                    } label: {
                        Image(systemName: vm.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(vm.pinned ? Color(hex: 0x0a84ff) : .white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(vm.pinned ? 0.18 : 0.08)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                    .help(vm.pinned ? "Unpin Notch" : "Pin Notch Open")
                }
                .frame(width: wingWidth, alignment: .trailing)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func cleanTabButton(tab: NotchViewModel.ActiveTab, icon: String, title: String, badge: Int?) -> some View {
        let isSelected = vm.activeTab == tab
        return Button {
            Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                vm.activeTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                    .fixedSize(horizontal: true, vertical: false)
                if let badge = badge {
                    Text("\(badge)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(hex: 0x0a84ff)))
                }
            }
            .foregroundColor(isSelected ? .white : Color.white.opacity(0.42))
            .padding(.vertical, 4)
        }
        .buttonStyle(ApplePressableButtonStyle())
    }
}

// MARK: - Responsive Non-Scrolling Nook Row (All Widgets Fit Together & Scale with Compact / Standard / Large)

struct HorizontalWidgetsStripView: View {
    @ObservedObject var vm: NotchViewModel

    private enum WidgetKind: Identifiable {
        case media, mirror, calendar, notes, timer, tasks
        var id: Self { self }

        var weight: CGFloat {
            switch self {
            case .media: return 1.00
            case .mirror: return 0.80
            case .calendar: return 1.04
            case .notes: return 0.96
            case .timer: return 1.04
            case .tasks: return 0.92
            }
        }
    }

    private var activeWidgets: [WidgetKind] {
        var list: [WidgetKind] = []
        if vm.settings.showMediaWidget { list.append(.media) }
        if vm.settings.showMirrorWidget { list.append(.mirror) }
        if vm.settings.showCalendarWidget { list.append(.calendar) }
        if vm.settings.showNotesWidget { list.append(.notes) }
        if vm.settings.showTimerWidget { list.append(.timer) }
        if vm.settings.showTasksWidget { list.append(.tasks) }
        return list
    }

    var body: some View {
        let widgets = activeWidgets
        let isCompact = vm.settings.notchWidthPreset == "compact"
        let spacing: CGFloat = isCompact ? 8 : 10

        GeometryReader { geo in
            if widgets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.45))
                    Text("No Nook widgets enabled — enable cards in Settings › Nook Widgets")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let cardHeight = max(100, geo.size.height)
                let totalSpacing = spacing * CGFloat(max(0, widgets.count - 1))
                let usableWidth = max(320, geo.size.width - totalSpacing)
                let hasMirror = widgets.contains(.mirror)
                let mirrorDiameter = min(cardHeight, max(86, round(usableWidth * (widgets.count >= 6 ? 0.14 : 0.16))))
                let nonMirrorWidgets = widgets.filter { $0 != .mirror }
                let nonMirrorWeightSum = max(0.01, nonMirrorWidgets.reduce(CGFloat(0)) { $0 + $1.weight })
                let remainingForCards = max(160, usableWidth - (hasMirror ? mirrorDiameter : 0))

                let avgCardWidth = remainingForCards / CGFloat(max(1, nonMirrorWidgets.count))
                let widthScale = avgCardWidth / 176.0
                let heightScale = cardHeight / 136.0
                let scale = min(max(min(widthScale, heightScale), 0.68), 1.16)

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(widgets) { kind in
                        switch kind {
                        case .mirror:
                            NotchMirrorPod(vm: vm, diameter: mirrorDiameter, scale: scale)
                                .frame(width: mirrorDiameter, height: cardHeight)
                        case .media:
                            let w = nonMirrorWidgets.isEmpty ? usableWidth : remainingForCards * (kind.weight / nonMirrorWeightSum)
                            NotchMediaCard(vm: vm, scale: scale)
                                .frame(width: w, height: cardHeight)
                                .clipped()
                        case .calendar:
                            let w = nonMirrorWidgets.isEmpty ? usableWidth : remainingForCards * (kind.weight / nonMirrorWeightSum)
                            NotchCalendarCard(vm: vm, cardWidth: w, scale: scale)
                                .frame(width: w, height: cardHeight)
                                .clipped()
                        case .notes:
                            let w = nonMirrorWidgets.isEmpty ? usableWidth : remainingForCards * (kind.weight / nonMirrorWeightSum)
                            NotchNotesCard(vm: vm, scale: scale)
                                .frame(width: w, height: cardHeight)
                                .clipped()
                        case .timer:
                            let w = nonMirrorWidgets.isEmpty ? usableWidth : remainingForCards * (kind.weight / nonMirrorWeightSum)
                            NotchTimerCard(vm: vm, scale: scale)
                                .frame(width: w, height: cardHeight)
                                .clipped()
                        case .tasks:
                            let w = nonMirrorWidgets.isEmpty ? usableWidth : remainingForCards * (kind.weight / nonMirrorWeightSum)
                            NotchTasksCard(vm: vm, scale: scale)
                                .frame(width: w, height: cardHeight)
                                .clipped()
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 1. Media Player Widget (Compact, Symmetrical, Never Overlaps Mirror)

struct NotchMediaCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaProvider
    var scale: CGFloat = 1.0

    init(vm: NotchViewModel, scale: CGFloat = 1.0) {
        self.vm = vm
        self.media = vm.media
        self.scale = scale
    }

    private var isLight: Bool { vm.isLightMode }

    var body: some View {
        let artSize = round(35 * scale)

        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 8 * scale) {
                Button {
                    media.openActivePlayerApp()
                } label: {
                    AlbumArtView(
                        info: media.info,
                        accent: vm.accent,
                        size: artSize,
                        showBadge: vm.settings.showSourceAppBadge
                    )
                }
                .buttonStyle(ApplePressableButtonStyle())
                .help("Open \(media.info.sourceDisplayName)")

                VStack(alignment: .leading, spacing: 1.5 * scale) {
                    Text(media.info.hasContent ? media.info.title : "Not Playing")
                        .font(.system(size: 11 * scale, weight: .bold, design: .rounded))                        .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                        .lineLimit(1)

                    Text(media.info.hasContent
                         ? (media.info.artist.isEmpty ? media.info.sourceDisplayName : media.info.artist)
                         : "Music · Spotify")
                        .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                AudioEqualizerView(
                    isPlaying: media.info.playing,
                    accent: .white.opacity(0.65),
                    compact: true,
                    style: vm.settings.visualizerStyle
                )
            }

            Spacer(minLength: 0)

            MusicScrubberView(vm: vm, scale: scale)

            Spacer(minLength: 0)

            HStack(spacing: 12 * scale) {
                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    media.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(media.info.isShuffling ? Color(hex: 0x0a84ff) : .white.opacity(0.55))
                }
                .buttonStyle(ApplePressableButtonStyle())

                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    media.previous()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 11.5 * scale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                .buttonStyle(ApplePressableButtonStyle())

                Button {
                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                    media.togglePlay()
                } label: {
                    Image(systemName: media.info.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14 * scale, weight: .bold))
                        .foregroundColor(.white)
                }
                .buttonStyle(ApplePressableButtonStyle())

                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    media.next()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 11.5 * scale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                .buttonStyle(ApplePressableButtonStyle())

                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    media.toggleRepeat()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(media.info.isRepeating ? Color(hex: 0x0a84ff) : .white.opacity(0.55))
                }
                .buttonStyle(ApplePressableButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, round(10 * scale))
        .padding(.vertical, round(9 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - 2. Circular Camera Mirror Pod (Matches Video 00:00 - 00:05)

struct NotchMirrorPod: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var mirror: MirrorService
    var diameter: CGFloat = 122
    var scale: CGFloat = 1.0
    @State private var isHoveringCircle = false

    init(vm: NotchViewModel, diameter: CGFloat = 122, scale: CGFloat = 1.0) {
        self.vm = vm
        self.mirror = vm.mirror
        self.diameter = diameter
        self.scale = scale
    }

    var body: some View {
        ZStack {
            // Persistent base circle so toggling Mirror on/off never destroys the view under the cursor
            ZStack {
                Circle()
                    .fill(isLight ? Color.white.opacity(0.72) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95))
                    .frame(width: diameter, height: diameter)

                Circle()
                    .fill(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.16))
                    .frame(width: diameter * (isHoveringCircle ? 0.56 : 0.48),
                           height: diameter * (isHoveringCircle ? 0.56 : 0.48))

                VStack(spacing: 3 * scale) {
                    Image(systemName: isHoveringCircle ? "hand.Wave.fill" : "web.camera.fill")
                        .font(.system(size: 14 * scale, weight: .semibold))
                        .foregroundColor(isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : .white.opacity(0.9))
                    if !isHoveringCircle {
                        Text("Mirror")
                            .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
                            .foregroundColor(isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.85))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    isHoveringCircle = hovering
                }
            }
            .onTapGesture {
                Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                mirror.toggle(!mirror.isOn)
            }

            if mirror.isOn {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: diameter, height: diameter)

                    if (mirror.isSessionReady || mirror.currentFrame != nil) && mirror.available {
                        CameraPreviewView(mirror: mirror, isMirrored: mirror.isMirrored)
                            .frame(width: diameter, height: diameter)
                            .clipShape(Circle())
                    } else if mirror.isRequestingPermission || (mirror.errorMessage == nil && !mirror.isSessionReady) {
                        VStack(spacing: 5 * scale) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                                .font(.system(size: 8.5 * scale, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                        .frame(width: diameter, height: diameter)
                        .background(Circle().fill(Color.black.opacity(0.88)))
                        .clipShape(Circle())
                    } else if !mirror.available {
                        VStack(spacing: 4 * scale) {
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 14 * scale, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                            Text(mirror.errorMessage ?? "Camera Off")
                                .font(.system(size: 8.5 * scale, weight: .bold, design: .rounded))
                                .foregroundColor(isLight ? Color(red: 0.30, green: 0.30, blue: 0.32) : .white.opacity(0.85))
                                .lineLimit(1)
                            Button {
                                mirror.openCameraPrivacySettings()
                            } label: {
                                Text("Allow")
                                    .font(.system(size: 8.5 * scale, weight: .bold, design: .rounded))
                                    .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .black)
                                    .padding(.horizontal, 9 * scale)
                                    .padding(.vertical, 3 * scale)
                                    .background(Capsule().fill(isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color.white))
                            }
                            .buttonStyle(ApplePressableButtonStyle())
                        }
                        .frame(width: diameter, height: diameter)
                        .background(Circle().fill(isLight ? Color.black.opacity(0.55) : Color.black.opacity(0.88)))
                        .clipShape(Circle())
                    }

                    if mirror.available {
                        Circle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: diameter, height: diameter)
                            .contentShape(Circle())
                            .onTapGesture {
                                Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                                vm.onHoverEnterPanel?()
                                mirror.toggle(false)
                            }
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - 3. Calendar Schedule Widget (Matches Video 00:00 - 00:08)

struct DayStripItem: Identifiable {
    let id: Int
    let weekday: String
    let dayString: String
    let isToday: Bool
    let isSelected: Bool
}

struct NotchCalendarCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var calProvider = CalendarProvider.shared
    var cardWidth: CGFloat = 212
    var scale: CGFloat = 1.0

    private var isLight: Bool { vm.isLightMode }

    private var daysAroundToday: [DayStripItem] {
        let cal = Calendar.current
        let today = Date()
        var items: [DayStripItem] = []
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "dd"
        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "EE"

        for offset in -2...2 {
            if let date = cal.date(byAdding: .day, value: offset, to: today) {
                let wd = String(weekFormatter.string(from: date).prefix(2)).uppercased()
                items.append(DayStripItem(
                    id: offset,
                    weekday: wd,
                    dayString: dayFormatter.string(from: date),
                    isToday: offset == 0,
                    isSelected: offset == calProvider.selectedDayOffset
                ))
            }
        }
        return items
    }

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: vm.now)
    }

    var body: some View {
        let visibleEvents = calProvider.events.filter {
            vm.settings.showAllDayEvents || !$0.isAllDay
        }

        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .center, spacing: 5 * scale) {
                Button {
                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                    calProvider.selectDayOffset(0)
                } label: {
                    Text(monthName)
                        .font(.system(size: 16 * scale, weight: .bold, design: .rounded))                            .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(ApplePressableButtonStyle())

                Spacer(minLength: 2)

                HStack(spacing: 2.5 * scale) {
                    ForEach(daysAroundToday) { item in
                        Button {
                            Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                            calProvider.selectDayOffset(item.id)
                        } label: {
                            VStack(spacing: 1.5 * scale) {
                                Text(item.weekday)
                                    .font(.system(size: 6.5 * scale, weight: .bold, design: .rounded))
                                    .foregroundColor(item.isSelected ? (isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : .white) : (isLight ? Color(red: 0.30, green: 0.30, blue: 0.32) : .white.opacity(0.42)))
                                    .lineLimit(1)

                                Text(item.dayString)
                                    .font(.system(size: 10 * scale, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundColor(item.isSelected ? (isLight ? Color(hex: 0x0a84ff) : .white) : (isLight ? Color(red: 0.30, green: 0.30, blue: 0.32) : .white.opacity(0.75)))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                Circle()
                                    .fill(item.isToday ? (item.isSelected ? (isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color.white) : Color(hex: 0x0a84ff)) : Color.clear)
                                    .frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: round(34 * scale))
                            .background(
                                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                    .fill(item.isSelected ? Color(hex: 0x0a84ff) : Color.clear)
                            )
                        }
                        .buttonStyle(ApplePressableButtonStyle())
                    }
                }
            }

            if !visibleEvents.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5 * scale) {
                        ForEach(visibleEvents.prefix(2)) { event in
                            HStack(spacing: 6 * scale) {
                                Capsule()
                                    .fill(event.isHappeningNow ? Color(hex: 0x30d158) : Color(hex: 0x0a84ff))
                                    .frame(width: 3, height: 22 * scale)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title)
                                        .font(.system(size: 10.5 * scale, weight: .semibold, design: .rounded))
                                        .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                                        .lineLimit(1)
                                    Text(event.timeLabel)
                                        .font(.system(size: 8.5 * scale, design: .rounded).monospacedDigit())
                                        .foregroundColor(isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : .white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                if let meetingURL = event.meetingURL {
                                    Button {
                                        NSWorkspace.shared.open(meetingURL)
                                    } label: {
                                        Text("Join")
                                            .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                                            .foregroundColor(isLight ? Color(hex: 0x0a84ff) : .white)
                                            .padding(.horizontal, 8 * scale)
                                            .padding(.vertical, 3 * scale)
                                            .background(Capsule().fill(Color(hex: 0x0a84ff)))
                                    }
                                    .buttonStyle(ApplePressableButtonStyle())
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 4 * scale) {
                    Spacer(minLength: 0)
                    Image(systemName: "tray")
                        .font(.system(size: 14 * scale))
                        .foregroundColor(isLight ? Color(red: 0.35, green: 0.35, blue: 0.38) : .white.opacity(0.32))
                    Text("Nothing for today")
                        .font(.system(size: 10.5 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : .white.opacity(0.42))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    calProvider.requestAccessAndLoad()
                }
            }
        }
        .padding(.horizontal, round(10 * scale))
        .padding(.vertical, round(8 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !calProvider.hasFetchedInitial {
                calProvider.requestAccessAndLoad()
            }
        }
    }
}

// MARK: - 4. Rich Notes Widget (Matches Video 00:05 - 00:13 with Aa / B / I / U / S & Trash Bar)

struct NotchNotesCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: Store
    var scale: CGFloat = 1.0
    @State private var text: String = ""
    @State private var hasLoaded = false
    @State private var isLargeText = false

    init(vm: NotchViewModel, scale: CGFloat = 1.0) {
        self.vm = vm
        self.store = vm.store
        self.scale = scale
    }

    private var isLight: Bool { vm.isLightMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Notes for me,\nNotes for you.")
                        .font(.system(size: (isLargeText ? 13 : 11) * scale, design: .rounded))
                        .foregroundColor(isLight ? Color(red: 0.35, green: 0.35, blue: 0.38) : .white.opacity(0.36))
                        .padding(.leading, 2)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                FocusableNoteTextView(text: $text, fontSize: round((isLargeText ? 13 : 11) * scale)) { focused in
                    vm.isEditingText = focused
                    if focused {
                        vm.onFocusTextField?()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: text) { newVal in
                    if hasLoaded {
                        store.updateNotes(newVal)
                    }
                }
            }

            // Bottom Formatting Toolbar matching Video (Aa, B, I, U, S + Trash)
            HStack(spacing: 10 * scale) {
                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    isLargeText.toggle()
                } label: {
                    Text("Aa")
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(isLargeText ? Color(hex: 0x0a84ff) : (isLight ? Color(red: 0.30, green: 0.30, blue: 0.32) : .white.opacity(0.55)))
                }
                .buttonStyle(ApplePressableButtonStyle())

                formatAction("B", weight: .bold) { wrapOrAppend("**") }
                formatAction("I", italic: true) { wrapOrAppend("_") }
                formatAction("U", underline: true) { wrapOrAppend("~") }
                formatAction("S", strikethrough: true) { wrapOrAppend("~~") }

                Spacer(minLength: 2)

                Button {
                    Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                    text = ""
                    store.updateNotes("")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10 * scale, weight: .semibold))                                                .foregroundColor(isLight ? Color(red: 0.35, green: 0.35, blue: 0.38) : .white.opacity(0.45))
                }
                .buttonStyle(ApplePressableButtonStyle())
                .help("Clear Note")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, round(12 * scale))
        .padding(.vertical, round(10 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isLight ? Color.white.opacity(0.72) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isLight
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.32), Color.white.opacity(0.14), Color.white.opacity(0.22)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: 0.9
                        )
                )
        )
        .onAppear {
            if !hasLoaded {
                text = store.notes
                hasLoaded = true
            }
        }
    }

    private func wrapOrAppend(_ token: String) {
        Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
        if text.isEmpty {
            text = "Notes for me,\nNotes for you."
        } else {
            text += " "
        }
        store.updateNotes(text)
    }

    private func formatAction(
        _ label: String,
        weight: Font.Weight = .semibold,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10 * scale, weight: weight, design: .serif))
                .italic(italic)
                .underline(underline)
                .strikethrough(strikethrough)
                .foregroundColor(isLight ? .white.opacity(0.55) : .black.opacity(0.45))
        }
        .buttonStyle(ApplePressableButtonStyle())
    }
}

// MARK: - 5. Multi-Timer Widget (Matches Video 00:07 - 00:13 with Blue 00h:00m:00s & Saved Presets List)

struct NotchTimerCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var timerModel: TimerModel
    var scale: CGFloat = 1.0
    @State private var timerTitle: String = ""
    @State private var showingSavedList: Bool = false
    @State private var savedTimers: [(label: String, seconds: Int)] = [
        ("15m", 900),
        ("5m", 300)
    ]

    init(vm: NotchViewModel, scale: CGFloat = 1.0) {
        self.vm = vm
        self.timerModel = vm.timerModel
        self.scale = scale
    }

    private var hours: Int { timerModel.state.remaining / 3600 }
    private var minutes: Int { (timerModel.state.remaining % 3600) / 60 }
    private var seconds: Int { timerModel.state.remaining % 60 }
    private var isLight: Bool { vm.isLightMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if showingSavedList {
                // Saved Timers List Mode (Video 00:11 - 00:13)
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            showingSavedList = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 9.5 * scale, weight: .bold))                        Text("Add Timer")
                                .font(.system(size: 10.5 * scale, weight: .semibold, design: .rounded))
                        }                        .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white).white.opacity(0.85))
                    }
                    .buttonStyle(ApplePressableButtonStyle())

                    Spacer()
                }

                Divider().background(Color.white.opacity(0.12))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5 * scale) {
                        ForEach(Array(savedTimers.enumerated()), id: \.offset) { _, preset in
                            HStack {
                                Image(systemName: "timer")
                                    .font(.system(size: 10 * scale))
                                    .foregroundColor(.white.opacity(0.5))
                                Text(preset.label)
                                    .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                Spacer()
                                Button {
                                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                                    timerModel.start(seconds: preset.seconds, label: preset.label)
                                    showingSavedList = false
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9 * scale, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 20 * scale, height: 20 * scale)
                                        .background(Circle().fill(Color.white.opacity(0.16)))
                                }
                                .buttonStyle(ApplePressableButtonStyle())
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                // Blue 00h : 00m : 00s Dial Mode (Video 00:07 - 00:10)
                HStack(spacing: 6 * scale) {
                    FocusableLineField(
                        placeholder: "Add Timer",
                        text: $timerTitle,
                        onSubmit: {},
                        onFocusChange: { focused in
                            vm.isEditingText = focused
                            if focused { vm.onFocusTextField?() }
                        }
                    )
                    .frame(height: 18 * scale)

                    Spacer(minLength: 2)

                    Button {
                        Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            showingSavedList.toggle()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 20 * scale, height: 20 * scale)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                    .help("View Saved Timers")
                }

                Spacer(minLength: 0)

                // Center Blue 00h : 00m : 00s Readout
                HStack(spacing: 2 * scale) {
                    blueTimerUnit(
                        value: hours,
                        unit: "h",
                        maxLimit: 99,
                        onCommit: { newH, autoStart in
                            timerModel.setCustomHMS(hours: newH, minutes: minutes, seconds: seconds, autoStart: autoStart)
                        },
                        onStep: { delta in timerModel.stepSeconds(delta * 3600) }
                    )

                    Text(":")
                        .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: 0x0a84ff).opacity(0.75))

                    blueTimerUnit(
                        value: minutes,
                        unit: "m",
                        maxLimit: 59,
                        onCommit: { newM, autoStart in
                            timerModel.setCustomHMS(hours: hours, minutes: newM, seconds: seconds, autoStart: autoStart)
                        },
                        onStep: { delta in timerModel.stepSeconds(delta * 60) }
                    )

                    Text(":")
                        .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: 0x0a84ff).opacity(0.75))

                    blueTimerUnit(
                        value: seconds,
                        unit: "s",
                        maxLimit: 59,
                        onCommit: { newS, autoStart in
                            timerModel.setCustomHMS(hours: hours, minutes: minutes, seconds: newS, autoStart: autoStart)
                        },
                        onStep: { delta in timerModel.stepSeconds(delta * 5) }
                    )
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                // Bottom Row: Preset Pills (15m, 5m) on Left + Reset & Blue Play Circle on Right
                HStack(spacing: 5 * scale) {
                    ForEach(Array(savedTimers.enumerated()), id: \.offset) { _, preset in
                        Button {
                            Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                            timerModel.start(seconds: preset.seconds, label: preset.label)
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.78))
                                .padding(.horizontal, 8 * scale)
                                .padding(.vertical, 3.5 * scale)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(ApplePressableButtonStyle())
                    }

                    Spacer(minLength: 2)

                    Button {
                        Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                        timerModel.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5 * scale, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 24 * scale, height: 24 * scale)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())

                    Button {
                        Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                        if timerModel.state.remaining == 0 {
                            timerModel.start(seconds: 300, label: timerTitle.isEmpty ? "5m Timer" : timerTitle)
                        } else {
                            timerModel.togglePause()
                        }
                    } label: {
                        Image(systemName: timerModel.state.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24 * scale, height: 24 * scale)
                            .background(Circle().fill(Color(hex: 0x0a84ff)))
                    }
                    .buttonStyle(ApplePressableButtonStyle())
                }
            }
        }
        .padding(.horizontal, round(12 * scale))
        .padding(.vertical, round(10 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isLight ? Color.white.opacity(0.72) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isLight
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.32), Color.white.opacity(0.14), Color.white.opacity(0.22)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: 0.9
                        )
                )
        )
    }

    private func blueTimerUnit(
        value: Int,
        unit: String,
        maxLimit: Int,
        onCommit: @escaping (Int, Bool) -> Void,
        onStep: @escaping (Int) -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            FocusableTimerDigitField(
                value: Binding(
                    get: { value },
                    set: { onCommit($0, false) }
                ),
                maxLimit: maxLimit,
                fontSize: round(16 * scale),
                isRunning: true,
                onCommitValue: { newVal, autoStart in
                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                    onCommit(newVal, autoStart)
                },
                onStepValue: { delta in
                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                    onStep(delta)
                },
                onFocusChange: { focused in
                    vm.isEditingText = focused
                    if focused { vm.onFocusTextField?() }
                }
            )
            .frame(width: 26 * scale, height: 22 * scale)

            Text(unit)
                .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: 0x0a84ff))
        }
    }
}

// MARK: - 6. To-Dos / Tasks Widget (Matches Video 00:09 - 00:13 with "New task..." Input & Checklist)

struct NotchTasksCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: Store
    var scale: CGFloat = 1.0
    @State private var draftTask: String = ""

    init(vm: NotchViewModel, scale: CGFloat = 1.0) {
        self.vm = vm
        self.store = vm.store
        self.scale = scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack(spacing: 6 * scale) {
                HStack(spacing: 4) {
                    FocusableLineField(
                        placeholder: "New task...",
                        text: $draftTask,
                        onSubmit: submitNewTask,
                        onFocusChange: { focused in
                            vm.isEditingText = focused
                            if focused { vm.onFocusTextField?() }
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: 18 * scale, maxHeight: 18 * scale)
                }
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 4 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .fill(isLight ? Color.white.opacity(0.72).opacity(0.22) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .strokeBorder(
                            isLight
                                        ? LinearGradient(
                                            colors: [Color.white.opacity(0.95), Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        : Color.white.opacity(0.12),
                                    lineWidth: 0.8
                                )
                        )
                )

                Button(action: submitNewTask) {
                    Image(systemName: "plus")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundColor(isLight ? Color(red: 0.30, green: 0.30, blue: 0.32) : .white.opacity(0.85))
                        .frame(width: 24 * scale, height: 24 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                .fill(isLight ? Color.white.opacity(0.72).opacity(0.18) : Color.white.opacity(0.10))
                        )
                }
                .buttonStyle(ApplePressableButtonStyle())
            }

            if store.tasks.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    Text("No open tasks")
                        .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : .white.opacity(0.38))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5 * scale) {
                        ForEach(store.tasks) { item in
                            HStack(spacing: 7 * scale) {
                                Button {
                                    Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                                    store.toggleTask(item.id)
                                } label: {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(item.done ? Color(hex: 0x0a84ff) : (isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : Color.white.opacity(0.38)), lineWidth: 1.3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(item.done ? Color(hex: 0x0a84ff) : Color.clear)
                                        )
                                        .frame(width: 13 * scale, height: 13 * scale)
                                        .overlay(
                                            Group {
                                                if item.done {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 8 * scale, weight: .bold))
                                                        .foregroundColor(.white)
                                                }
                                            }
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())

                                Text(item.title)
                                    .font(.system(size: 10.5 * scale, weight: .medium, design: .rounded))
                                    .strikethrough(item.done, color: isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.5))
                                    .foregroundColor(item.done ? (isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : .white.opacity(0.42)) : (isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white.opacity(0.9)))
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, round(11 * scale))
        .padding(.vertical, round(10 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isLight ? Color.white.opacity(0.72) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isLight
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.32), Color.white.opacity(0.14), Color.white.opacity(0.22)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: 0.9
                        )
                )
        )
    }

    private func submitNewTask() {
        let trimmed = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
        store.addTask(trimmed)
        draftTask = ""
    }
}

// MARK: - Notch Tray Strip View (Matches Video 00:16 - 00:28 Horizontal File Icon Shelf)

struct NotchTrayStripView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: Store
    @ObservedObject private var sys = SystemMonitor.shared

    init(vm: NotchViewModel) {
        self.vm = vm
        self.store = vm.store
    }

    var body: some View {
        ZStack {
            if store.trayItems.isEmpty {
                NotchDragDropOverlayView(vm: vm)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pickFilesFromFinder()
                    }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(store.trayItems) { item in
                                VStack(spacing: 5) {
                                    ZStack(alignment: .topTrailing) {
                                        Image(nsImage: sys.icon(forFile: item.path))
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        Button {
                                            Haptics.play(.generic, disabled: vm.settings.disableHaptics)
                                            store.removeTrayItem(item.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundColor(.white.opacity(0.85))
                                                .background(Circle().fill(Color.black.opacity(0.6)))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .offset(x: 5, y: -4)
                                    }

                                    Text(item.name)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.9))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(width: 68)
                                }
                                .padding(.top, 4)
                                .onTapGesture(count: 2) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                                }
                                .onDrag {
                                    if vm.settings.removeTrayItemAfterDrag {
                                        let id = item.id
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                            store.removeTrayItem(id)
                                        }
                                    }
                                    return NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider()
                                }
                            }

                            // Add Files quick tile at end of shelf
                            VStack(spacing: 6) {
                                Button {
                                    pickFilesFromFinder()
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
                                            .frame(width: 48, height: 48)
                                        Image(systemName: "plus")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                                .buttonStyle(ApplePressableButtonStyle())

                                Text("Add Files")
                                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFilesFromFinder() {
        vm.isEditingText = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Add Files to OpenNook Tray"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                vm.isEditingText = false
                guard response == .OK else { return }
                for url in panel.urls {
                    _ = store.addTrayItem(path: url.path, reverseOrder: vm.settings.reverseTrayOrder)
                }
                Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
            }
        }
    }
}

// MARK: - Controls Tab (Exact Top, Middle & Bottom Row Edge Alignment Across All 3 Columns)

struct NotchShortcutsAndHUDStripView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var sys = SystemMonitor.shared
    @State private var pickedHex: String? = nil
    @State private var isDarkAppearance: Bool = true

    var body: some View {
        let isLight = vm.isLightMode

        GeometryReader { geo in
            let isCompact = geo.size.width < 860
            let colSpacing: CGFloat = isCompact ? 8 : 10
            let rowSpacing: CGFloat = 8
            let rowHeight: CGFloat = max(44, (geo.size.height - rowSpacing) / 2.0)
            // Make circular buttons match rowHeight so top and bottom edges of all 3 columns align to the exact pixel!
            let circleBtnSize: CGFloat = rowHeight
            let circleSpacing: CGFloat = isCompact ? 8 : 10
            let rightColW: CGFloat = circleBtnSize * 3 + circleSpacing * 2
            let remainingW = max(340, geo.size.width - rightColW - colSpacing * 2)
            let leftColW = remainingW * 0.46
            let midColW = remainingW * 0.54

            HStack(spacing: colSpacing) {
                // LEFT COLUMN: Display & Sound Clear Liquid Glass Slider Pods
                VStack(spacing: rowSpacing) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Display")
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isLight ? Color(red: 0.45, green: 0.45, blue: 0.48) : .white.opacity(0.45))
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "sun.min.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.9))

                            TahoeControlSlider(
                                value: Binding(
                                    get: { sys.screenBrightness },
                                    set: { sys.setScreenBrightness($0, showHUD: false) }
                                ),
                                range: 0.05...1.0
                            )

                            Image(systemName: "sun.max.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.95))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(width: leftColW, height: rowHeight)                            .background(tahoeGlassCapsuleBackground(vm: vm, cornerRadius: 18, isLight: isLight))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Sound")
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                            Spacer()
                            Text(sys.audioOutputDeviceName)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundColor(isLight ? Color(red: 0.45, green: 0.45, blue: 0.48) : .white.opacity(0.5))
                                .lineLimit(1)
                        }

                        HStack(spacing: 8) {
                            Button {
                                sys.toggleMute()
                            } label: {
                                Image(systemName: sys.isMuted ? "speaker.slash.fill" : "speaker.fill")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.9))
                            }
                            .buttonStyle(PlainButtonStyle())

                            TahoeControlSlider(
                                value: Binding(
                                    get: { sys.isMuted ? 0 : sys.systemVolume },
                                    set: { sys.setSystemVolume($0, showHUD: false) }
                                ),
                                range: 0.0...1.0
                            )

                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white.opacity(0.95))

                            ZStack {
                                Circle()
                                    .fill(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.16))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : .white)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(width: leftColW, height: rowHeight)
                    .background(tahoeGlassCapsuleBackground(cornerRadius: 18, isLight: isLight))
                }
                .frame(width: leftColW, height: geo.size.height)

                // MIDDLE COLUMN: Clear Liquid Glass Pill Modules
                VStack(spacing: rowSpacing) {
                    HStack(spacing: 8) {
                        tahoePillModule(
                            icon: sys.isCaffeineActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                            title: "Caffeine",
                            subtitle: sys.isCaffeineActive ? "On · Awake" : "Off",
                            isActive: sys.isCaffeineActive,
                            activeBadgeColor: Color(hex: 0x0a84ff),
                            rowHeight: rowHeight,
                            isLight: isLight
                        ) {
                            sys.toggleCaffeine()
                        }

                        tahoePillModule(
                            icon: "camera.viewfinder",
                            title: "Screenshot",
                            subtitle: "Area to Tray",
                            isActive: false,
                            activeBadgeColor: .white,
                            rowHeight: rowHeight,
                            isLight: isLight
                        ) {
                            vm.onRequestCollapse?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                captureScreenshotToTray(interactive: true)
                            }
                        }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: 8) {
                        tahoePillModule(
                            icon: "eyedropper.halffull",
                            title: "Color Picker",
                            subtitle: pickedHex ?? "Sample HEX",
                            isActive: pickedHex != nil,
                            activeBadgeColor: Color(hex: 0x30d158),
                            rowHeight: rowHeight,
                            isLight: isLight
                        ) {
                            SystemShortcuts.pickColorToClipboard { hex in
                                if let hex = hex {
                                    pickedHex = hex
                                    vm.store.addClipboardSnippet(hex)
                                }
                            }
                        }

                        tahoePillModule(
                            icon: "camera.aperture",
                            title: "Round Mirror",
                            subtitle: vm.mirror.isOn ? "Active" : "FaceTime HD",
                            isActive: vm.mirror.isOn,
                            activeBadgeColor: Color(hex: 0x30d158),
                            rowHeight: rowHeight,
                            isLight: isLight
                        ) {
                            vm.activeTab = .nook
                            vm.onOpenMirror?()
                        }
                    }
                    .frame(height: rowHeight)
                }
                .frame(width: midColW, height: geo.size.height)

                // RIGHT COLUMN: Circular Clear Liquid Glass Icon Buttons (Aligned Top & Bottom with Rows)
                VStack(spacing: rowSpacing) {
                    HStack(spacing: circleSpacing) {
                        tahoeCircleButton(
                            icon: "circle.lefthalf.filled",
                            size: circleBtnSize,
                            isActive: isDarkAppearance,
                            tooltip: "Toggle Light / Dark Appearance",
                            isLight: isLight
                        ) {
                            isDarkAppearance.toggle()
                            SystemShortcuts.toggleDarkMode()
                        }

                        tahoeCircleButton(
                            icon: "display",
                            size: circleBtnSize,
                            isActive: false,
                            tooltip: "Full Screen Screenshot to Tray",
                            isLight: isLight
                        ) {
                            vm.onRequestCollapse?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                captureScreenshotToTray(interactive: false)
                            }
                        }

                        tahoeCircleButton(
                            icon: "apple.terminal",
                            size: circleBtnSize,
                            isActive: false,
                            tooltip: "Open Terminal",
                            isLight: isLight
                        ) {
                            SystemShortcuts.openTerminal()
                        }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: circleSpacing) {
                        tahoeCircleButton(
                            icon: "timer",
                            size: circleBtnSize,
                            isActive: vm.timerModel.state.running,
                            tooltip: "Start 5m Focus Timer",
                            isLight: isLight
                        ) {
                            if vm.timerModel.state.running {
                                vm.timerModel.togglePause()
                            } else {
                                vm.timerModel.start(seconds: 300, label: "5m Focus")
                            }
                        }

                        tahoeCircleButton(
                            icon: "lock.fill",
                            size: circleBtnSize,
                            isActive: false,
                            tooltip: "Lock Screen",
                            isLight: isLight
                        ) {
                            vm.onRequestCollapse?()
                            SystemShortcuts.lockScreen()
                        }

                        tahoeCircleButton(
                            icon: "trash",
                            size: circleBtnSize,
                            isActive: false,
                            tooltip: "Empty Trash",
                            isLight: isLight
                        ) {
                            SystemShortcuts.emptyTrash()
                        }
                    }
                    .frame(height: rowHeight)
                }
                .frame(width: rightColW, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tahoeGlassCapsuleBackground(vm: NotchViewModel, cornerRadius: CGFloat = 18, highlighted: Bool = false, isLight: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isLight ? Color.white.opacity(0.72) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isLight
                        ? LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.60),
                                Color.black.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [
                                highlighted ? Color(hex: 0x0a84ff).opacity(0.85) : Color.white.opacity(0.32),
                                Color.white.opacity(0.14),
                                Color.white.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                    lineWidth: highlighted ? 1.3 : 0.9
                )
        }
    }

    private func tahoePillModule(
        icon: String,
        title: String,
        subtitle: String,
        isActive: Bool,
        activeBadgeColor: Color,
        rowHeight: CGFloat,
        isLight: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.play(.generic, disabled: vm.settings.disableHaptics)
            action()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? (isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color.white) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.14)))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isActive ? (isLight ? .white : activeBadgeColor) : (isLight ? Color(red: 0.25, green: 0.25, blue: 0.28) : .white))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))                        .foregroundColor(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                        .lineLimit(1)                          Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundColor(isLight ? Color(red: 0.40, green: 0.40, blue: 0.44) : .white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)                    .background(tahoeGlassCapsuleBackground(vm: vm, cornerRadius: 18, highlighted: isActive, isLight: isLight))
        }
        .buttonStyle(ApplePressableButtonStyle())
    }

    private func tahoeCircleButton(
        icon: String,
        size: CGFloat,
        isActive: Bool,
        tooltip: String,
        isLight: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.play(.generic, disabled: vm.settings.disableHaptics)
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(isActive ? (isLight ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color.white) : (isLight ? Color.white.opacity(0.75) : Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.95)))
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isLight
                                    ? LinearGradient(
                                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.32),
                                            Color.white.opacity(0.14),
                                            Color.white.opacity(0.22)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                lineWidth: 0.9
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundColor(isActive ? (isLight ? .white : .black) : (isLight ? Color(red: 0.20, green: 0.20, blue: 0.22) : .white))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(ApplePressableButtonStyle())
        .help(tooltip)
    }

    private func captureScreenshotToTray(interactive: Bool) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let fileName = "Screenshot-\(formatter.string(from: Date())).png"
        let desktopDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fileURL = desktopDir.appendingPathComponent(fileName)

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = interactive ? ["-i", fileURL.path] : [fileURL.path]
            try? proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                DispatchQueue.main.async {
                    _ = vm.store.addTrayItem(path: fileURL.path, reverseOrder: vm.settings.reverseTrayOrder)
                    vm.activeTab = .tray
                    vm.onRequestExpand?()
                }
            }
        }
    }
}

// MARK: - SwiftUI Drop Delegate Fallback (Supports Multi-Item File Drops)

struct TrayDropDelegate: DropDelegate {
    let vm: NotchViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .plainText])
    }

    func dropEntered(info: DropInfo) {
        if vm.settings.autoOpenTrayOnDrag {
            vm.onRequestExpand?()
            vm.activeTab = .tray
        }
        vm.onHoverEnterPanel?()
    }

    func dropExited(info: DropInfo) {
        vm.onHoverExitPanel?()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    DispatchQueue.main.async {
                        _ = vm.store.addTrayItem(path: url.path, reverseOrder: vm.settings.reverseTrayOrder)
                        Haptics.play(.alignment, disabled: vm.settings.disableHaptics)
                    }
                    return
                }

                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var fileURL: URL?
                    if let url = item as? URL {
                        fileURL = url
                    } else if let nsurl = item as? NSURL {
                        fileURL = nsurl as URL
                    } else if let data = item as? Data {
                        fileURL = URL(dataRepresentation: data, relativeTo: nil)
                            ?? (String(data: data, encoding: .utf8).flatMap { URL(string: $0) })
                    } else if let str = item as? String {
                        fileURL = URL(fileURLWithPath: str)
                    }
                    if let fileURL = fileURL {
                        DispatchQueue.main.async {
                            _ = vm.store.addTrayItem(path: fileURL.path, reverseOrder: vm.settings.reverseTrayOrder)
                        }
                    }
                }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
}

// MARK: - Color helper

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }

    static func hex(_ v: UInt32) -> Color { Color(hex: v) }
}

// MARK: - Backward Compatibility Placeholders

typealias WidgetsGridView = HorizontalWidgetsStripView
typealias NowPlayingWidget = NotchMediaCard
typealias CalendarWidget = NotchCalendarCard
typealias TrayWidget = NotchTrayStripView
typealias TimerWidget = NotchTimerCard
typealias TasksWidget = NotchTasksCard
typealias FullShelfView = NotchTrayStripView
