import AVFoundation
import SwiftUI
import Vision

/// Owns the capture session, runs live OCR on video frames and takes stills.
@Observable
final class CameraModel: NSObject, @unchecked Sendable {
    enum Status { case idle, running, denied, unavailable }

    private(set) var status: Status = .idle
    /// A fleet number that has been stable across several frames.
    private(set) var reading: Int?
    private(set) var torchOn = false

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

        // Buses are big and far: keep continuous focus and a touch of zoom on multi-cam
        // devices so the ultra-wide doesn't take over.
        try? cam.lockForConfiguration()
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = true }
        if let switchOver = cam.virtualDeviceSwitchOverVideoZoomFactors.first {
            cam.videoZoomFactor = CGFloat(truncating: switchOver)
        }
        cam.unlockForConfiguration()

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

    func focus(at devicePoint: CGPoint) {
        guard let d = device else { return }
        sessionQueue.async {
            try? d.lockForConfiguration()
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = devicePoint
                d.focusMode = .autoFocus
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
                guard self.session.isRunning else { cont.resume(returning: nil); return }
                self.photoContinuation = cont
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
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right)
        try? handler.perform([request])

        let observations = TextReader.observations(from: request.results ?? [])
        let best = NumberExtractor.best(in: observations, mode: mode, catalog: Fleet.catalog)
        let stable = voter.push(best)
        Task { @MainActor in
            if let stable, stable != self.reading { self.reading = stable }
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
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

    /// Accurate OCR over a captured or imported photo. Returns the best fleet number.
    /// Full frame first; if nothing is found, re-read overlapping 3×3 tiles so small
    /// numbers on a whole-vehicle shot get enough pixels (e.g. yellow-on-black "4425").
    static func bestNumber(in data: Data, mode: CatchMode) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            let full = read(cg, orientation: orientation, roi: nil)
            if let n = NumberExtractor.best(in: full, mode: mode, catalog: Fleet.catalog) { return n }
            var tiles: [TextObservation] = []
            for y in [0.0, 0.3, 0.6] {
                for x in [0.0, 0.3, 0.6] {
                    tiles += read(cg, orientation: orientation, roi: CGRect(x: x, y: y, width: 0.4, height: 0.4))
                }
            }
            return NumberExtractor.best(in: tiles, mode: mode, catalog: Fleet.catalog)
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
