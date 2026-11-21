import SwiftUI
import AppKit
import ServiceManagement

struct SettingsRootView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var selectedSection: SettingsSection = .notch

    enum SettingsSection: String, CaseIterable, Identifiable {
        case notch = "Notch & Behavior"
        case appearance = "Appearance"
        case media = "Media & Audio"
        case calendar = "Calendar"
        case tray = "Tray (Shelf)"
        case hud = "OSD & Live Activities"
        case widgets = "Nook Widgets"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .notch: return "rectangle.topthird.inset.filled"
            case .appearance: return "paintbrush.fill"
            case .media: return "music.note"
            case .calendar: return "calendar"
            case .tray: return "tray.full.fill"
            case .hud: return "slider.horizontal.below.rectangle"
            case .widgets: return "square.grid.2x2.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(hex: Settings.accentHex[settingsStore.settings.accentColorName] ?? 0x2f6fed))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("OpenNook")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("Dynamic Island for Mac")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().padding(.bottom, 4)

                ForEach(SettingsSection.allCases) { sec in
                    Button {
                        selectedSection = sec
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sec.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18)
                                .foregroundColor(selectedSection == sec ? .white : .secondary)
                            Text(sec.rawValue)
                                .font(.system(size: 12, weight: selectedSection == sec ? .semibold : .regular))
                                .foregroundColor(selectedSection == sec ? .white : .primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedSection == sec
                                      ? Color(hex: Settings.accentHex[settingsStore.settings.accentColorName] ?? 0x2f6fed)
                                      : Color.clear)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Spacer()

                Button {
                    settingsStore.resetToDefaults()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text("Reset Defaults")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(10)
            .frame(width: 185)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

            Divider()

            // Right Detail Form
            Form {
                switch selectedSection {
                case .notch:
                    Section("Hover & Gestures") {
                        Toggle("Open the notch when hovering", isOn: $settingsStore.settings.openOnHover)
                        HStack {
                            Text("Hover delay")
                            Spacer()
                            Slider(value: $settingsStore.settings.hoverDelay, in: 0.0...0.5, step: 0.04)
                                .frame(width: 140)
                            Text(String(format: "%.2fs", settingsStore.settings.hoverDelay))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        Toggle("Keep panel pinned open by default when clicked", isOn: $settingsStore.settings.pinnedOpenByDefault)
                        Toggle("Enable two-finger trackpad swipe gestures", isOn: $settingsStore.settings.enableSwipeGestures)
                        Toggle("Natural scroll gesture direction", isOn: $settingsStore.settings.naturalGestureDirection)
                    }
                    Section("Displays & Window") {
                        Toggle("Enable on displays without a notch (floating pill)", isOn: $settingsStore.settings.enableOnNonNotchScreens)
                        Toggle("Follow active pointer display", isOn: $settingsStore.settings.followMouseDisplay)
                        Toggle("Show in fullscreen applications", isOn: $settingsStore.settings.showInFullscreen)
                        Toggle("Hide notch from screenshots & screen recordings", isOn: $settingsStore.settings.hideFromScreenRecording)
                    }
                    Section("System") {
                        Toggle("Launch OpenNook at login", isOn: $settingsStore.settings.launchAtLogin)
                            .onChange(of: settingsStore.settings.launchAtLogin) { enabled in
                                if enabled {
                                    try? SMAppService.mainApp.register()
                                } else {
                                    try? SMAppService.mainApp.unregister()
                                }
                            }
                        Toggle("Keep Mac awake by default (Caffeine mode)", isOn: $settingsStore.settings.keepAwakeDefault)
                        Toggle("Disable Force Touch trackpad haptics", isOn: $settingsStore.settings.disableHaptics)
                    }

                case .appearance:
                    Section("Notch Silhouette & Sizing") {
                        Picker("Notch shape style", selection: $settingsStore.settings.notchStyle) {
                            Text("NotchNook Concave Ears").tag("notch")
                            Text("Floating Dynamic Pill").tag("floating")
                        }
                        Picker("Notch & Widget Size", selection: $settingsStore.settings.notchWidthPreset) {
                            Text("Compact (820 × 178pt)").tag("compact")
                            Text("Standard (960 × 198pt)").tag("standard")
                            Text("Large (1120 × 224pt)").tag("wide")
                        }
                        Stepper("Content padding: \(settingsStore.settings.contentPadding)pt",
                                value: $settingsStore.settings.contentPadding, in: 8...20, step: 2)
                    }
                    Section("Colors & Glass Material") {
                        HStack {
                            Text("Accent color")
                            Spacer()
                            ForEach(["blue", "purple", "pink", "red", "orange", "green", "cyan", "indigo", "mint"], id: \.self) { name in
                                Button {
                                    settingsStore.settings.accentColorName = name
                                } label: {
                                    Circle()
                                        .fill(Color(hex: Settings.accentHex[name] ?? 0x2f6fed))
                                        .overlay(
                                            Circle().strokeBorder(
                                                settingsStore.settings.accentColorName == name ? Color.white : .clear,
                                                lineWidth: 2
                                            )
                                        )
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        Toggle("Use dynamic album artwork tint when playing music", isOn: $settingsStore.settings.useDynamicAlbumTint)
                        HStack {
                            Text("OLED glass opacity")
                            Spacer()
                            Slider(value: $settingsStore.settings.glassOpacity, in: 0.80...1.0, step: 0.02)
                                .frame(width: 150)
                            Text("\(Int(settingsStore.settings.glassOpacity * 100))%")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    Section("Collapsed Notch Ears") {
                        Toggle("Show clock in right notch ear", isOn: $settingsStore.settings.showClockOnPill)
                        Toggle("Show mini music equalizer & song title in left ear", isOn: $settingsStore.settings.showMiniMusic)
                        Toggle("Show battery charging indicator in right ear", isOn: $settingsStore.settings.showBatteryOnPill)
                    }

                case .media:
                    Section("Now Playing Controller") {
                        Picker("Preferred music source", selection: $settingsStore.settings.preferredMusicApp) {
                            Text("Auto-Detect (MediaRemote + Scripting)").tag("auto")
                            Text("Apple Music").tag("music")
                            Text("Spotify").tag("spotify")
                        }
                        Picker("Audio visualizer style", selection: $settingsStore.settings.visualizerStyle) {
                            Text("Animated Equalizer Bars").tag("bars")
                            Text("Pulsing Studio Dots").tag("dots")
                        }
                        Toggle("Show source app badge on album artwork", isOn: $settingsStore.settings.showSourceAppBadge)
                        Toggle("Show remaining track time instead of total duration", isOn: $settingsStore.settings.showRemainingTime)
                        Toggle("Sneak peek live activity when song changes", isOn: $settingsStore.settings.showSneakPeekOnTrackChange)
                    }

                case .calendar:
                    Section("Schedule & Meetings") {
                        Toggle("Show all-day events in agenda", isOn: $settingsStore.settings.showAllDayEvents)
                        Toggle("Include Apple Reminders in schedule", isOn: $settingsStore.settings.showRemindersInCalendar)
                        Toggle("Auto-highlight happening-now meetings in collapsed notch", isOn: $settingsStore.settings.autoScrollToNextEvent)
                        Picker("First day of week", selection: $settingsStore.settings.weekStartDay) {
                            Text("System Default").tag("system")
                            Text("Sunday").tag("sunday")
                            Text("Monday").tag("monday")
                        }
                    }

                case .tray:
                    Section("File Shelf & AirDrop") {
                        Toggle("Automatically open Tray when dragging files to notch", isOn: $settingsStore.settings.autoOpenTrayOnDrag)
                        Toggle("Keep newest dropped files at the front", isOn: $settingsStore.settings.reverseTrayOrder)
                        Toggle("Remove file from Tray after dragging out", isOn: $settingsStore.settings.removeTrayItemAfterDrag)
                        Toggle("Clear all Tray items when quitting OpenNook", isOn: $settingsStore.settings.clearTrayOnQuit)
                        Toggle("Save copied text snippets to Nook Clipboard history", isOn: $settingsStore.settings.enableClipboardWatch)
                    }

                case .hud:
                    Section("OSD Replacement & Live Activities") {
                        Toggle("Enable inline Notch HUD for Volume, Brightness & Keyboard", isOn: $settingsStore.settings.enableHUDReplacement)
                        Toggle("Display numeric percentage next to HUD bar", isOn: $settingsStore.settings.showHUDPercentage)
                        Toggle("Show Live Activity when charger is connected/disconnected", isOn: $settingsStore.settings.enableBatteryLiveActivity)
                        Toggle("Show Live Activity for Caffeine & Timer completions", isOn: $settingsStore.settings.enableBluetoothLiveActivity)
                    }

                case .widgets:
                    Section("Visible Nook Cards") {
                        Toggle("Music Player & Scrubber", isOn: $settingsStore.settings.showMediaWidget)
                        Toggle("FaceTime HD Camera Mirror Pod", isOn: $settingsStore.settings.showMirrorWidget)
                        Toggle("Calendar Week Strip & Meeting Join", isOn: $settingsStore.settings.showCalendarWidget)
                        Toggle("Notes Scratchpad & Formatting Bar", isOn: $settingsStore.settings.showNotesWidget)
                        Toggle("Focus Timer", isOn: $settingsStore.settings.showTimerWidget)
                        Toggle("To-Dos & Tasks Checklist", isOn: $settingsStore.settings.showTasksWidget)
                    }

                case .about:
                    Section("OpenNook") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("2.0.0 (NotchNook + Boring.Notch Edition)")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("License")
                            Spacer()
                            Text("MIT · 100% Free & Open Source")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Architecture")
                            Spacer()
                            Text("Native AppKit + SwiftUI · Universal macOS")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 480)
    }
}

/// Wraps Settings in an observable box that persists changes and notifies listeners.
final class SettingsStore: ObservableObject {
    @Published var settings: Settings {
        didSet {
            settings.save()
            onSettingsChanged?(settings)
        }
    }

    var onSettingsChanged: ((Settings) -> Void)?

    init(initial: Settings? = nil) {
        self.settings = initial ?? Settings.load()
    }

    func resetToDefaults() {
        self.settings = Settings()
    }
}
