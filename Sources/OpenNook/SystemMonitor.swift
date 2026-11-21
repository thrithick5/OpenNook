import Foundation
import AppKit
import SwiftUI
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import CoreAudio

// MARK: - System Monitor (Battery, HUD, Volume, Hardware Display Brightness, Caffeine, Clipboard, RAM)

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    struct BatteryStatus: Equatable {
        var percentage: Int = 100
        var isCharging: Bool = false
        var isPluggedIn: Bool = true
        var isLowPowerMode: Bool = false
        var timeRemainingMinutes: Int? = nil
        var powerSourceName: String = "AC Power"

        var iconName: String {
            if isCharging { return "battery.100.bolt" }
            switch percentage {
            case 88...100: return "battery.100"
            case 63..<88: return "battery.75"
            case 38..<63: return "battery.50"
            case 13..<38: return "battery.25"
            default: return "battery.0"
            }
        }

        var statusLabel: String {
            if isCharging { return "Charging · \(percentage)%" }
            if isPluggedIn { return "Plugged In · \(percentage)%" }
            if let mins = timeRemainingMinutes, mins > 0 {
                let h = mins / 60
                let m = mins % 60
                return h > 0 ? "\(percentage)% (\(h)h \(m)m left)" : "\(percentage)% (\(m)m left)"
            }
            return "\(percentage)%"
        }
    }

    @Published var battery = BatteryStatus()
    @Published var systemVolume: Double = 0.65
    @Published var isMuted: Bool = false
    @Published var screenBrightness: Double = 0.80
    @Published var keyboardBacklight: Double = 0.50
    @Published var isCaffeineActive: Bool = false
    @Published var activeAlert: LiveActivityAlert? = nil
    @Published var audioOutputDeviceName: String = "MacBook Air Speakers"
    @Published var cpuUsagePercent: Int = 8
    @Published var memoryUsagePercent: Int = 42

    // DisplayServices private framework dynamic bindings for real MacBook brightness control
    private typealias DSGetBrightnessFunc = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetBrightnessFunc = @convention(c) (UInt32, Float) -> Int32
    private var dsHandle: UnsafeMutableRawPointer?
    private var dsGetBrightness: DSGetBrightnessFunc?
    private var dsSetBrightness: DSSetBrightnessFunc?

    // Cached File Icons
    private var iconCache: [String: NSImage] = [:]

    private var pollTimer: Timer?
    private var alertDismissWork: DispatchWorkItem?
    private var mediaKeyMonitor: Any?
    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    private var sleepAssertionID: IOPMAssertionID = 0
    private var wasChargingLastPoll: Bool? = nil

    var onClipboardCaptured: ((String) -> Void)?

    init() {
        loadDisplayServices()
        refreshBattery()
        refreshAudioOutputDevice()
        refreshSystemVolume()
        refreshScreenBrightness()
        refreshSystemStats()
    }

    private func loadDisplayServices() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        dsHandle = handle
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            dsGetBrightness = unsafeBitCast(sym, to: DSGetBrightnessFunc?.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            dsSetBrightness = unsafeBitCast(sym, to: DSSetBrightnessFunc?.self)
        }
    }

    func icon(forFile path: String) -> NSImage {
        if let cached = iconCache[path] {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = img
        return img
    }

    func startMonitoring(store: Store, settings: Settings) {
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        onClipboardCaptured = { [weak store] text in
            store?.addClipboardSnippet(text)
        }

        if settings.keepAwakeDefault && !isCaffeineActive {
            toggleCaffeine(true, showHUD: false)
        }

        setupMediaKeyInterception()

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshBattery(triggerAlertIfChanged: true)
                self.refreshSystemVolume()
                self.refreshScreenBrightness()
                self.checkClipboard()
                self.refreshSystemStats()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let m = mediaKeyMonitor {
            NSEvent.removeMonitor(m)
            mediaKeyMonitor = nil
        }
        toggleCaffeine(false, showHUD: false)
    }

    // MARK: - Live Activity / HUD Banner Presentation

    func presentAlert(_ alert: LiveActivityAlert, duration: TimeInterval = 2.1) {
        alertDismissWork?.cancel()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            activeAlert = alert
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                if self?.activeAlert?.id == alert.id {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        self?.activeAlert = nil
                    }
                }
            }
        }
        alertDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Battery Inspection via IOKit

    func refreshBattery(triggerAlertIfChanged: Bool = false) {
        var next = BatteryStatus()
        next.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let first = sources.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any] {

            let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maxCap = max(1, desc[kIOPSMaxCapacityKey as String] as? Int ?? 100)
            next.percentage = min(100, max(0, (capacity * 100) / maxCap))

            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            next.isPluggedIn = (state == kIOPSACPowerValue)
            next.isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            next.powerSourceName = next.isPluggedIn ? "AC Power" : "Battery"

            if let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int, timeToEmpty > 0 {
                next.timeRemainingMinutes = timeToEmpty
            } else if let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int, timeToFull > 0 {
                next.timeRemainingMinutes = timeToFull
            }
        }

        if let prevCharging = wasChargingLastPoll, prevCharging != next.isCharging, triggerAlertIfChanged {
            presentAlert(LiveActivityAlert(
                kind: .battery,
                title: next.isCharging ? "Charging" : (next.isPluggedIn ? "Power Connected" : "On Battery"),
                subtitle: "\(next.percentage)%",
                icon: next.iconName,
                value: Double(next.percentage) / 100.0,
                accentHex: next.isCharging ? 0x30d158 : 0xff9f0a
            ))
        }
        wasChargingLastPoll = next.isCharging
        if battery != next {
            battery = next
        }
    }

    // MARK: - Direct CoreAudio System Volume & Output

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var defaultDeviceID = AudioDeviceID(0)
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &defaultDeviceID
        )
        return status == noErr ? defaultDeviceID : 0
    }

    func refreshSystemVolume() {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return }

        var vol: Float32 = Float32(systemVolume)
        var volSize = UInt32(MemoryLayout<Float32>.size)
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &volAddr) {
                if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
                    let nextVol = Double(min(1.0, max(0.0, vol)))
                    if abs(systemVolume - nextVol) > 0.005 {
                        systemVolume = nextVol
                    }
                    break
                }
            }
        }

        var muteVal: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddr),
           AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muteVal) == noErr {
            let nextMute = (muteVal != 0)
            if isMuted != nextMute {
                isMuted = nextMute
            }
        }
    }

    func setSystemVolume(_ newVolume: Double, showHUD: Bool = true) {
        let clamped = min(1.0, max(0.0, newVolume))
        systemVolume = clamped
        isMuted = (clamped <= 0.001)

        let deviceID = defaultOutputDeviceID()
        if deviceID != 0 {
            var vol = Float32(clamped)
            let volSize = UInt32(MemoryLayout<Float32>.size)
            var wroteCoreAudio = false
            for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
                var volAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                if AudioObjectHasProperty(deviceID, &volAddr) {
                    if AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, volSize, &vol) == noErr {
                        wroteCoreAudio = true
                    }
                }
            }
            var muteVal: UInt32 = isMuted ? 1 : 0
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(deviceID, &muteAddr) {
                AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
            }
            if !wroteCoreAudio {
                let pct = Int(round(clamped * 100))
                DispatchQueue.global(qos: .utility).async {
                    NSAppleScript(source: "set volume output volume \(pct)")?.executeAndReturnError(nil)
                }
            }
        }

        if showHUD {
            let pct = Int(round(clamped * 100))
            let icon: String
            if isMuted || clamped == 0 {
                icon = "speaker.slash.fill"
            } else if clamped < 0.33 {
                icon = "speaker.wave.1.fill"
            } else if clamped < 0.66 {
                icon = "speaker.wave.2.fill"
            } else {
                icon = "speaker.wave.3.fill"
            }
            presentAlert(LiveActivityAlert(
                kind: .volume,
                title: "Volume",
                subtitle: isMuted ? "Silent" : "\(pct)%",
                icon: icon,
                value: clamped
            ))
        }
    }

    func toggleMute(showHUD: Bool = true) {
        isMuted.toggle()
        let deviceID = defaultOutputDeviceID()
        if deviceID != 0 {
            var muteVal: UInt32 = isMuted ? 1 : 0
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(deviceID, &muteAddr) {
                AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
            }
        }
        if showHUD {
            presentAlert(LiveActivityAlert(
                kind: .volume,
                title: isMuted ? "Silent" : "Sound On",
                subtitle: isMuted ? "Muted" : "\(Int(round(systemVolume * 100)))%",
                icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: isMuted ? 0 : systemVolume,
                accentHex: isMuted ? 0xff453a : nil
            ))
        }
    }

    // MARK: - Real Hardware Display Brightness via DisplayServices

    func refreshScreenBrightness() {
        guard let getFn = dsGetBrightness else { return }
        var val: Float = Float(screenBrightness)
        if getFn(CGMainDisplayID(), &val) == 0 {
            let next = Double(min(1.0, max(0.05, val)))
            if abs(screenBrightness - next) > 0.005 {
                screenBrightness = next
            }
        }
    }

    func setScreenBrightness(_ newBrightness: Double, showHUD: Bool = true) {
        let clamped = min(1.0, max(0.05, newBrightness))
        screenBrightness = clamped
        if let setFn = dsSetBrightness {
            _ = setFn(CGMainDisplayID(), Float(clamped))
        }
        let pct = Int(round(clamped * 100))
        if showHUD {
            presentAlert(LiveActivityAlert(
                kind: .brightness,
                title: "Display",
                subtitle: "\(pct)%",
                icon: clamped > 0.5 ? "sun.max.fill" : "sun.min.fill",
                value: clamped,
                accentHex: 0xffd60a
            ))
        }
    }

    func setKeyboardBacklight(_ newLevel: Double, showHUD: Bool = true) {
        let clamped = min(1.0, max(0.0, newLevel))
        keyboardBacklight = clamped
        let pct = Int(round(clamped * 100))
        if showHUD {
            presentAlert(LiveActivityAlert(
                kind: .backlight,
                title: "Keyboard",
                subtitle: "\(pct)%",
                icon: clamped > 0.1 ? "light.max" : "light.min",
                value: clamped
            ))
        }
    }

    func refreshAudioOutputDevice() {
        let defaultDeviceID = defaultOutputDeviceID()
        guard defaultDeviceID != 0 else { return }

        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(defaultDeviceID, &nameAddr, 0, nil, &nameSize, &unmanagedName) == noErr,
           let cfStr = unmanagedName?.takeUnretainedValue() {
            let str = cfStr as String
            if !str.isEmpty && audioOutputDeviceName != str {
                audioOutputDeviceName = str
            }
        }
    }

    // MARK: - Media / System Key HUD Listener

    private func setupMediaKeyInterception() {
        guard mediaKeyMonitor == nil else { return }
        mediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data1 = event.data1
            let keyCode = Int((data1 & 0xFFFF0000) >> 16)
            let keyFlags = (data1 & 0x0000FFFF)
            let isKeyDown = (((keyFlags & 0xFF00) >> 8) == 0xA)
            guard isKeyDown else { return }

            Task { @MainActor in
                guard let self = self else { return }
                switch keyCode {
                case 0: // NX_KEYTYPE_SOUND_UP
                    self.setSystemVolume(min(1.0, self.systemVolume + 0.0625), showHUD: true)
                case 1: // NX_KEYTYPE_SOUND_DOWN
                    self.setSystemVolume(max(0.0, self.systemVolume - 0.0625), showHUD: true)
                case 7: // NX_KEYTYPE_MUTE
                    self.toggleMute(showHUD: true)
                case 2: // NX_KEYTYPE_BRIGHTNESS_UP
                    self.setScreenBrightness(min(1.0, self.screenBrightness + 0.0625), showHUD: true)
                case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
                    self.setScreenBrightness(max(0.05, self.screenBrightness - 0.0625), showHUD: true)
                case 21: // NX_KEYTYPE_ILLUMINATION_UP
                    self.setKeyboardBacklight(min(1.0, self.keyboardBacklight + 0.1), showHUD: true)
                case 22: // NX_KEYTYPE_ILLUMINATION_DOWN
                    self.setKeyboardBacklight(max(0.0, self.keyboardBacklight - 0.1), showHUD: true)
                default:
                    break
                }
            }
        }
    }

    // MARK: - Caffeine (Prevent Display & System Sleep)

    func toggleCaffeine(_ active: Bool? = nil, showHUD: Bool = true) {
        let target = active ?? !isCaffeineActive
        if target == isCaffeineActive { return }

        if target {
            let reason = "OpenNook Caffeine Mode keeping Mac awake" as CFString
            var assertionID: IOPMAssertionID = 0
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            if success == kIOReturnSuccess {
                sleepAssertionID = assertionID
            }
            isCaffeineActive = true
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                sleepAssertionID = 0
            }
            isCaffeineActive = false
        }

        if showHUD {
            presentAlert(LiveActivityAlert(
                kind: .caffeine,
                title: isCaffeineActive ? "Caffeine On" : "Caffeine Off",
                subtitle: isCaffeineActive ? "Stay Awake" : "Sleep Normal",
                icon: isCaffeineActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                accentHex: 0xff9f0a
            ))
        }
    }

    // MARK: - Clipboard Watcher

    func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pb.changeCount
        if let str = pb.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onClipboardCaptured?(trimmed)
            }
        }
    }

    // MARK: - Lightweight System Stats (CPU & Memory Pressure)

    func refreshSystemStats() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let active = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count)
            let total = max(1, active + UInt64(stats.free_count + stats.inactive_count))
            let nextMem = Int(min(99, max(10, (active * 100) / total)))
            if memoryUsagePercent != nextMem {
                memoryUsagePercent = nextMem
            }
        }
    }
}
