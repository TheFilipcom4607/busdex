import AVFoundation
import SwiftUI
import Vision

/// Owns the capture session, runs live OCR on video frames and takes stills.
/// One shared instance, so hopping between tabs reuses the configured session.
@Observable
final class CameraModel: NSObject, @unchecked Sendable {
    static let shared = CameraModel()

    enum Status { case idle, running, denied, unavailable }

    private(set) var status: Status = .idle
    /// A fleet number that has been stable across several frames.
    private(set) var reading: Int?
    private(set) var torchOn = false
    /// Zoom as the Camera app shows it: 1 = main lens, 0.5 = ultra-wide, 5 = telephoto.
    private(set) var zoom: CGFloat = 1
    /// One stop per physical lens (plus 2× on phones whose main sensor crops cleanly),
    /// e.g. [0.5, 1, 2, 5] on an iPhone 16 Pro.
    private(set) var zoomStops: [CGFloat] = [1]
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Device zoom factor that the UI calls 1× (the main lens on a virtual device).
    @ObservationIgnored private var zoomScale: CGFloat = 1

    /// Read from the vision queue; guarded by `lock`.
    var mode: CatchMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue }; visionQueue.async { self.voter.reset() } }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "tabor.camera.session")
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "tabor.camera.vision")
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var _mode: CatchMode = .auto
    @ObservationIgnored private var voter = NumberVoter(window: 6, needed: 3)
    @ObservationIgnored private var lastOCR = Date.distantPast
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var photoContinuation: CheckedContinuation<Data?, Never>?
    /// Tracks how the phone is held so stills and OCR stay upright even though the UI is portrait-only.
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var _captureAngle: CGFloat = 90

    @ObservationIgnored private var _lastFrame: [TextObservation] = []
    @ObservationIgnored private var _nearby: [NearbyVehicle] = []
    @ObservationIgnored private var _lastCaptureError: String?

    /// Horizon-level rotation for captured frames, in degrees. Guarded by `lock`.
    var captureAngle: CGFloat { lock.withLock { _captureAngle } }
    /// What live OCR saw in the most recent frame it read (for debug mode).
    var lastFrame: [TextObservation] { lock.withLock { _lastFrame } }
    /// Live vehicles around you, from `LiveFleetService`; live OCR leans towards them.
    var nearby: [NearbyVehicle] {
        get { lock.withLock { _nearby } }
        set { lock.withLock { _nearby = newValue } }
    }
    /// Why the last `capture()` came back empty, if it did.
    var lastCaptureError: String? { lock.withLock { _lastCaptureError } }

    // MARK: - Lifecycle

    @MainActor
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        case .authorized: break
        default: status = .denied; return
        }
        let ok = await withCheckedContinuation { cont in
            sessionQueue.async {
                let ok = self.configure()
                if ok, !self.session.isRunning { self.session.startRunning() }
                cont.resume(returning: ok)
            }
        }
        status = ok ? .running : .unavailable
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        Task { @MainActor in
            self.reading = nil
            self.torchOn = false
        }
    }

    /// Called on sessionQueue.
    private func configure() -> Bool {
        if configured { return true }
        guard let cam = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        session.addOutput(videoOutput)
        session.commitConfiguration()

        // A virtual (multi-lens) device hands off between the physical cameras by itself as
        // the zoom factor crosses each switch-over point, so 0.5× really is the ultra-wide
        // and 5× the telephoto — not a digital crop of the main lens.
        let switchOvers = cam.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = cam.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let scale = hasUltraWide ? (switchOvers.first ?? 1) : 1
        var stops = Set(([1] + switchOvers).map { ($0 / scale * 10).rounded() / 10 })
        if hasUltraWide { stops.insert(0.5) }
        // The 48MP main sensor gives a clean 2× crop (like the Camera app); add it when the
        // next lens is further than that.
        if let tele = stops.filter({ $0 > 1 }).min(), tele > 2.5 { stops.insert(2) } else if stops.count == 1 { stops.insert(2) }
        let maxUI = min(cam.maxAvailableVideoZoomFactor / scale, max(stops.max() ?? 1, 2) * 3)
        let minUI = cam.minAvailableVideoZoomFactor / scale

        // Buses are big and far: continuous focus, and start on the main lens (1×).
        try? cam.lockForConfiguration()
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = true }
        cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(scale, cam.maxAvailableVideoZoomFactor))
        cam.unlockForConfiguration()
        zoomScale = scale
        let sortedStops = stops.filter { $0 >= minUI - 0.01 && $0 <= maxUI + 0.01 }.sorted()
        Task { @MainActor in
            self.zoomStops = sortedStops
            self.zoomRange = minUI...max(minUI, maxUI)
            self.zoom = 1
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) {
            [weak self] c, _ in
            guard let self else { return }
            let angle = c.videoRotationAngleForHorizonLevelCapture
            lock.withLock { self._captureAngle = angle }
        }
        rotation = coordinator

        device = cam
        configured = true
        return true
    }

    // MARK: - Controls

    func toggleTorch() {
        guard let d = device, d.hasTorch else { return }
        let on = !torchOn
        sessionQueue.async {
            try? d.lockForConfiguration()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        }
        torchOn = on
    }

    var hasTorch: Bool { device?.hasTorch ?? false }

    /// Sets the zoom in Camera-app terms (0.5, 1, 2, 5…). Buttons ramp smoothly; pinch
    /// sets it directly so it tracks the fingers.
    func setZoom(_ value: CGFloat, smooth: Bool) {
        guard let d = device else { return }
        let ui = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = ui
        let factor = min(max(ui * zoomScale, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
        sessionQueue.async {
            guard (try? d.lockForConfiguration()) != nil else { return }
            if smooth { d.ramp(toVideoZoomFactor: factor, withRate: 12) } else { d.videoZoomFactor = factor }
            d.unlockForConfiguration()
        }
    }

    func focus(at devicePoint: CGPoint) {
        guard let d = device else { return }
        sessionQueue.async {
            try? d.lockForConfiguration()
            // Refocus around the tapped point but keep tracking: the next bus is never
            // at the same distance, so a one-shot focus lock would leave it blurry.
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = devicePoint
                d.focusMode = d.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = devicePoint
                d.exposureMode = .continuousAutoExposure
            }
            d.unlockForConfiguration()
        }
    }

    /// Full-resolution JPEG/HEIC data.
    func capture() async -> Data? {
        await withCheckedContinuation { cont in
            sessionQueue.async {
                guard self.session.isRunning, self.photoContinuation == nil else {
                    self.lock.withLock {
                        self._lastCaptureError = self.session.isRunning ? "a capture was already in flight" : "session not running"
                    }
                    cont.resume(returning: nil)
                    return
                }
                self.photoContinuation = cont
                if let conn = self.photoOutput.connection(with: .video) {
                    let angle = self.captureAngle
                    if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .balanced
                if let d = self.device, d.hasFlash { settings.flashMode = .off }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Lets the user clear a stuck reading (e.g. after correcting it by hand).
    func resetReading() {
        visionQueue.async { self.voter.reset() }
        reading = nil
    }
}

// MARK: - Live OCR

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // ~5 reads a second is plenty and keeps the phone cool.
        let now = Date()
        guard !busy, now.timeIntervalSince(lastOCR) > 0.2,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        lastOCR = now
        defer { busy = false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .init(bufferAngle: captureAngle))
        try? handler.perform([request])

        let observations = TextReader.observations(from: request.results ?? [])
        lock.withLock { _lastFrame = observations }
        let candidates = NumberExtractor.candidates(in: observations, mode: mode, catalog: Fleet.catalog)
        let best = LiveHints.adjust(candidates, nearby: nearby).candidates.max { $0.score < $1.score }?.number
        let stable = voter.push(best)
        Task { @MainActor in
            if let stable, stable != self.reading { self.reading = stable }
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        lock.withLock {
            _lastCaptureError = error.map { $0.localizedDescription } ?? (data == nil ? "no file data in the photo" : nil)
        }
        sessionQueue.async {
            self.photoContinuation?.resume(returning: data)
            self.photoContinuation = nil
        }
    }
}

// MARK: - Still images

enum TextReader {
    static func observations(from results: [VNRecognizedTextObservation]) -> [TextObservation] {
        results.flatMap { obs in
            obs.topCandidates(2).map {
                TextObservation(text: $0.string, confidence: $0.confidence, height: Double(obs.boundingBox.height))
            }
        }
    }

    /// Everything a still read saw, for debug mode.
    struct Report: Sendable {
        var number: Int?
        /// "full", "tiles", "none", or "decode-failed".
        var pass: String
        var full: [TextObservation] = []
        var tiles: [TextObservation] = []
        var candidates: [(number: Int, score: Double)] = []
        /// What the live feed changed about the candidates.
        var live = LiveHints.Adjustment()
        var duration: TimeInterval = 0
    }

    /// Accurate OCR over a captured or imported photo. Returns the best fleet number.
    static func bestNumber(in data: Data, mode: CatchMode) async -> Int? {
        await read(data, mode: mode, nearby: []).number
    }

    /// Full frame first; if nothing is found, re-read overlapping 3×3 tiles so small
    /// numbers on a whole-vehicle shot get enough pixels (e.g. yellow-on-black "4425").
    /// `nearby` (live vehicles around you) boosts and rescues candidates, see `LiveHints`.
    static func read(_ data: Data, mode: CatchMode, nearby: [NearbyVehicle]) async -> Report {
        await Task.detached(priority: .userInitiated) {
            let start = Date()
            guard let image = UIImage(data: data), let cg = image.cgImage else { return Report(pass: "decode-failed") }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            var report = Report(pass: "full")
            report.full = read(cg, orientation: orientation, roi: nil)
            report.candidates = NumberExtractor.candidates(in: report.full, mode: mode, catalog: Fleet.catalog)
            if report.candidates.isEmpty {
                report.pass = "tiles"
                for y in [0.0, 0.3, 0.6] {
                    for x in [0.0, 0.3, 0.6] {
                        report.tiles += read(cg, orientation: orientation, roi: CGRect(x: x, y: y, width: 0.4, height: 0.4))
                    }
                }
                report.candidates = NumberExtractor.candidates(in: report.tiles, mode: mode, catalog: Fleet.catalog)
            }
            (report.candidates, report.live) = LiveHints.adjust(report.candidates, nearby: nearby)
            report.number = report.candidates.max { $0.score < $1.score }?.number
            if report.number == nil { report.pass = "none" }
            report.duration = Date().timeIntervalSince(start)
            return report
        }.value
    }

    private static func read(_ cg: CGImage, orientation: CGImagePropertyOrientation, roi: CGRect?) -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Fleet numbers are often small on a whole-vehicle shot (~1.5% of the frame);
        // Vision's default floor of 1/32 skips them.
        request.minimumTextHeight = 0.008
        if let roi { request.regionOfInterest = roi }
        try? VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
        let scale = Double(roi?.height ?? 1)
        return (request.results ?? []).flatMap { obs in
            obs.topCandidates(2).map {
                TextObservation(text: $0.string, confidence: $0.confidence, height: Double(obs.boundingBox.height) * scale)
            }
        }
    }
}

extension CGImagePropertyOrientation {
    /// Orientation of a raw (landscape) camera buffer, given the capture rotation angle.
    init(bufferAngle: CGFloat) {
        switch Int(bufferAngle.rounded()) {
        case 0: self = .up
        case 180: self = .down
        case 270: self = .left
        default: self = .right
        }
    }

    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint) -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?

        @objc func tapped(_ g: UITapGestureRecognizer) {
            onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: g.location(in: self)))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(PreviewView.tapped)))
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.onTap = onTap
    }
}
