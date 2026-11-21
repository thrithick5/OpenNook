import Foundation
import Combine
import SwiftUI
import AppKit
import AVFoundation
import CoreImage

// MARK: - Timer

@MainActor
final class TimerModel: ObservableObject {
    @Published var state = CountdownState(totalSeconds: 300, remaining: 300, running: false, label: "5m Focus")
    private var ticker: Timer?
    var onFinished: () -> Void = {}

    func start(seconds: Int, label: String) {
        let clamped = max(1, seconds)
        state.start(totalSeconds: clamped, label: label)
        startTicking()
    }

    func startPreset(minutes: Int) {
        let lbl = minutes == 25 ? "25m Pomodoro" : "\(minutes)m Focus"
        start(seconds: minutes * 60, label: lbl)
    }

    /// Sets custom hours, minutes, and seconds from keyboard typing or scroll wheel without forcing auto-start unless requested.
    func setCustomHMS(hours: Int, minutes: Int, seconds: Int, autoStart: Bool = false) {
        let h = max(0, min(99, hours))
        let m = max(0, min(999, minutes))
        let s = max(0, min(999, seconds))
        let total = max(0, h * 3600 + m * 60 + s)
        stopTicking()
        state.totalSeconds = max(1, total)
        state.remaining = total
        state.label = "Custom Timer"
        if autoStart && total > 0 {
            state.running = true
            startTicking()
        } else {
            state.running = false
        }
    }

    func togglePause() {
        if state.running {
            stopTicking()
            state.running = false
        } else if state.remaining > 0 {
            state.totalSeconds = max(state.totalSeconds, state.remaining)
            state.running = true
            startTicking()
        } else {
            start(seconds: 300, label: "5m Focus")
        }
    }

    func reset() {
        stopTicking()
        state = CountdownState(totalSeconds: 0, remaining: 0, running: false)
    }

    func addMinutes(_ minutes: Int) {
        if state.running || state.remaining > 0 {
            state.remaining = max(0, state.remaining + minutes * 60)
            state.totalSeconds = max(state.totalSeconds, state.remaining)
        } else {
            let next = max(60, minutes * 60)
            state.remaining = next
            state.totalSeconds = next
            state.label = "\(next / 60)m Focus"
        }
    }

    func stepSeconds(_ delta: Int) {
        let next = max(0, state.remaining + delta)
        state.remaining = next
        state.totalSeconds = max(state.totalSeconds, next)
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.state.tick(1)
                if !self.state.running && self.state.remaining == 0 {
                    self.stopTicking()
                    NSSound(named: "Glass")?.play()
                    self.onFinished()
                }
            }
        }
        ticker = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - Mirror (Dual Hardware PreviewLayer + CGImage Frame Pipeline — Never Black & Never Crashes on Re-Toggle)

final class MirrorService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isOn = false
    @Published var available = false
    @Published var isSessionReady = false
    @Published var isRequestingPermission = false
    @Published var isMirrored = true
    @Published var zoomFactor: CGFloat = 1.0
    @Published var errorMessage: String? = nil
    @Published var currentFrame: CGImage? = nil
    @Published var lastInteractionDate: Date = .distantPast

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.opennook.mirror.session", qos: .userInitiated)
    private let videoOutputQueue = DispatchQueue(label: "com.opennook.mirror.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private var activeToggleToken: Int = 0
    private let tokenLock = NSLock()

    override init() {
        super.init()
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        available = (auth == .authorized)
    }

    private func nextToken() -> Int {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        activeToggleToken &+= 1
        return activeToggleToken
    }

    private func isCurrentToken(_ token: Int) -> Bool {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return token == activeToggleToken
    }

    func toggle(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        let token = nextToken()

        if !on {
            DispatchQueue.main.async {
                self.lastInteractionDate = Date()
                self.isOn = false
                self.isSessionReady = false
                self.currentFrame = nil
                self.errorMessage = nil
                completion?(false)
            }
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                if !self.isCurrentToken(token) { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
            return
        }

        DispatchQueue.main.async {
            self.lastInteractionDate = Date()
            self.isOn = true
            self.errorMessage = nil
        }

        let hasPlistDesc = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        let auth = AVCaptureDevice.authorizationStatus(for: .video)

        switch auth {
        case .authorized:
            configureAndStartSession(token: token, completion: completion)
        case .notDetermined:
            guard hasPlistDesc else {
                DispatchQueue.main.async {
                    self.available = false
                    self.isSessionReady = false
                    self.errorMessage = "Camera permission missing"
                    completion?(false)
                }
                return
            }
            DispatchQueue.main.async {
                self.isRequestingPermission = true
            }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isRequestingPermission = false
                    self.lastInteractionDate = Date()
                    guard self.isCurrentToken(token) else { return }
                    if granted {
                        self.configureAndStartSession(token: token, completion: completion)
                    } else {
                        self.available = false
                        self.isSessionReady = false
                        self.errorMessage = "Allow Camera in Settings"
                        completion?(false)
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.available = false
                self.isSessionReady = false
                self.errorMessage = "Allow Camera in Settings"
                completion?(false)
            }
        @unknown default:
            DispatchQueue.main.async {
                self.available = false
                self.isSessionReady = false
                self.errorMessage = "Camera unavailable"
                completion?(false)
            }
        }
    }

    private func configureAndStartSession(token: Int, completion: ((Bool) -> Void)?) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isCurrentToken(token) else { return }

            if !self.isConfigured || self.session.inputs.isEmpty {
                guard let device = self.discoverCameraDevice() else {
                    DispatchQueue.main.async {
                        guard self.isCurrentToken(token) else { return }
                        self.available = false
                        self.isSessionReady = false
                        self.errorMessage = "No camera detected"
                        completion?(false)
                    }
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()

                    for oldInput in Array(self.session.inputs) {
                        self.session.removeInput(oldInput)
                    }
                    for oldOutput in Array(self.session.outputs) {
                        self.session.removeOutput(oldOutput)
                    }

                    if self.session.canSetSessionPreset(.high) {
                        self.session.sessionPreset = .high
                    } else if self.session.canSetSessionPreset(.medium) {
                        self.session.sessionPreset = .medium
                    } else if self.session.canSetSessionPreset(.low) {
                        self.session.sessionPreset = .low
                    }

                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                    }

                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)

                    if self.session.canAddOutput(self.videoOutput) {
                        self.session.addOutput(self.videoOutput)
                    }

                    self.session.commitConfiguration()
                    self.isConfigured = true
                } catch {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        guard self.isCurrentToken(token) else { return }
                        self.available = false
                        self.isSessionReady = false
                        self.errorMessage = "Camera unavailable"
                        completion?(false)
                    }
                    return
                }
            }

            guard self.isCurrentToken(token) else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                guard self.isCurrentToken(token) else { return }
                self.available = true
                self.isSessionReady = true
                self.errorMessage = nil
                completion?(true)
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isOn else { return }
            self.currentFrame = cgImage
            if !self.isSessionReady {
                self.isSessionReady = true
            }
        }
    }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func discoverCameraDevice() -> AVCaptureDevice? {
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return front
        }
        if let anyDefault = AVCaptureDevice.default(for: .video) {
            return anyDefault
        }
        if #available(macOS 14.0, *) {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            return discovery.devices.first
        } else {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            return discovery.devices.first
        }
    }
}

// MARK: - Circular Camera Preview (Center-Origin Layer + SwiftUI CGImage Frame Overlay)
// Never uses SwiftUI .scaleEffect(x: -1) on an AppKit NSViewRepresentable (which flipped around (0,0) into negative X space!).

struct CameraPreviewView: View {
    @ObservedObject var mirror: MirrorService
    var isMirrored: Bool = true

    init(mirror: MirrorService, isMirrored: Bool = true) {
        self.mirror = mirror
        self.isMirrored = isMirrored
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                // 1. Hardware AVCaptureVideoPreviewLayer with proper center-anchor transform (anchorPoint = 0.5, 0.5)
                if mirror.isSessionReady {
                    CenterAnchoredPreviewLayerView(session: mirror.session, isMirrored: isMirrored)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // 2. Direct CGImage frame feed (guarantees visible frames even if previewLayer is still warming up)
                if let cgImage = mirror.currentFrame {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(x: isMirrored ? -1.0 : 1.0, y: 1.0)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct CenterAnchoredPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    final class ContainerNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var mirrored: Bool = true

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.wantsLayer = true
            self.layer?.masksToBounds = true
            self.layer?.backgroundColor = NSColor.black.cgColor

            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            self.layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(session: AVCaptureSession, isMirrored: Bool) {
            if previewLayer.session !== session {
                previewLayer.session = session
            }
            self.mirrored = isMirrored
            applyCenterTransform()
        }

        override func layout() {
            super.layout()
            applyCenterTransform()
        }

        private func applyCenterTransform() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.bounds = bounds
            previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            previewLayer.transform = CATransform3DMakeScale(mirrored ? -1.0 : 1.0, 1.0, 1.0)
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> ContainerNSView {
        let v = ContainerNSView()
        v.update(session: session, isMirrored: isMirrored)
        return v
    }

    func updateNSView(_ nsView: ContainerNSView, context: Context) {
        nsView.update(session: session, isMirrored: isMirrored)
    }
}
