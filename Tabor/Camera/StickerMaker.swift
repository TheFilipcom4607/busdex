import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

/// Turns a catch photo into a die-cut sticker: lifts the vehicle off the background
/// (the same foreground-instance model as "lift subject" in Photos), adds a thick white
/// border that follows its silhouette, and crops tight. Output is a transparent PNG.
/// Lifting (the slow part) and cutting are separate, so the cut can wait for the fleet
/// number's position and a wrong pick can be re-cut without lifting again.
enum StickerMaker {
    struct Options {
        /// Longest side of the working image; stickers never render bigger than this.
        var maxSide: CGFloat = 1400
        /// White border thickness, relative to the cut-out's longest side.
        var border: CGFloat = 0.034
    }

    /// Why no sticker came out — recorded by debug mode.
    enum Failure: Error, CustomStringConvertible {
        case decode, lifting(String), noSubject, mask(String), tinySubject, render

        var description: String {
            switch self {
            case .decode: "couldn't decode the photo"
            case .lifting(let e): "subject lifting failed: \(e)"
            case .noSubject: "no subject found"
            case .mask(let e): "mask generation failed: \(e)"
            case .tinySubject: "subject too small"
            case .render: "rendering the sticker failed"
            }
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Everything the lifter found in one photo, kept so it can be cut more than once.
    final class Lift: @unchecked Sendable {
        let image: CGImage
        let observation: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        /// Detected people, normalised, top-left origin.
        let people: [CGRect]

        init(image: CGImage, observation: VNInstanceMaskObservation, handler: VNImageRequestHandler, people: [CGRect]) {
            self.image = image
            self.observation = observation
            self.handler = handler
            self.people = people
        }
    }

    static func lift(_ data: Data, options: Options = Options()) -> Result<Lift, Failure> {
        // Downsample + apply EXIF orientation in one go, the same upright image OCR reads.
        guard let cg = PhotoStore.downsample(data, maxPixel: Int(options.maxSide)) else { return .failure(.decode) }
        return lift(cg)
    }

    static func lift(_ cg: CGImage) -> Result<Lift, Failure> {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request, humans])
        } catch {
            return .failure(.lifting(error.localizedDescription))
        }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return .failure(.noSubject) }
        let people = (humans.results ?? []).map { b in
            CGRect(x: b.boundingBox.minX, y: 1 - b.boundingBox.maxY, width: b.boundingBox.width, height: b.boundingBox.height)
        }
        return .success(Lift(image: cg, observation: obs, handler: handler, people: people))
    }

    /// Each lifted object, measured against the number's box and the people in the photo.
    static func subjects(of lift: Lift, numberBox: CGRect?) -> [Subject] {
        let buf = lift.observation.instanceMask
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return [] }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let toPixels = { (r: CGRect) in
            (x0: Int(r.minX * CGFloat(w)), x1: Int((r.maxX * CGFloat(w)).rounded(.up)),
             y0: Int(r.minY * CGFloat(h)), y1: Int((r.maxY * CGFloat(h)).rounded(.up)))
        }
        let number = numberBox.map(toPixels)
        let people = lift.people.map(toPixels)
        struct Tally { var pixels = 0, inNumber = 0, inPerson = 0, sumX = 0, sumY = 0
                       var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1 }
        // Labels are bytes: one slot each, no hashing in a loop over every pixel.
        var tallies = [Tally](repeating: Tally(), count: 256)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w where row[x] != 0 {
                let l = Int(row[x])
                tallies[l].pixels += 1
                tallies[l].sumX += x
                tallies[l].sumY += y
                if x < tallies[l].minX { tallies[l].minX = x }
                if x > tallies[l].maxX { tallies[l].maxX = x }
                if y < tallies[l].minY { tallies[l].minY = y }
                if y > tallies[l].maxY { tallies[l].maxY = y }
                if let n = number, x >= n.x0, x < n.x1, y >= n.y0, y < n.y1 { tallies[l].inNumber += 1 }
                if people.contains(where: { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }) { tallies[l].inPerson += 1 }
            }
        }
        let numberArea = number.map { max(1, ($0.x1 - $0.x0) * ($0.y1 - $0.y0)) } ?? 1
        let fw = CGFloat(w), fh = CGFloat(h)
        return tallies.indices.filter { tallies[$0].pixels > 0 }.map { label in
            let t = tallies[label]
            return Subject(label: label, pixels: t.pixels,
                    box: CGRect(x: CGFloat(t.minX) / fw, y: CGFloat(t.minY) / fh,
                                width: CGFloat(t.maxX - t.minX + 1) / fw, height: CGFloat(t.maxY - t.minY + 1) / fh),
                    centroid: CGPoint(x: CGFloat(t.sumX) / CGFloat(t.pixels) / fw, y: CGFloat(t.sumY) / CGFloat(t.pixels) / fh),
                    numberCover: Double(t.inNumber) / Double(numberArea),
                    personShare: Double(t.inPerson) / Double(t.pixels))
        }
    }

    /// The objects worth cutting, best first, for a number at `numberBox` (if it was found).
    static func rank(_ lift: Lift, numberBox: CGRect?) -> (order: [Int], reason: PickReason)? {
        let buf = lift.observation.instanceMask
        return SubjectPicker.rank(subjects(of: lift, numberBox: numberBox), numberBox: numberBox,
                                  framePixels: CVPixelBufferGetWidth(buf) * CVPixelBufferGetHeight(buf))
    }

    /// One object of the lift as a sticker.
    static func cut(_ lift: Lift, instance: Int, options: Options = Options()) -> Result<CGImage, Failure> {
        let cg = lift.image
        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try lift.observation.generateScaledMaskForImage(forInstances: [instance], from: lift.handler)
        } catch {
            return .failure(.mask(error.localizedDescription))
        }

        let image = CIImage(cgImage: cg)
        let full = image.extent
        guard let box = boundingBox(of: maskBuffer), box.width > 20, box.height > 20 else { return .failure(.tinySubject) }

        // The white border scales with the subject, not the photo.
        let r = max(6, max(box.width, box.height) * options.border)
        let pad = r * 1.6

        // Soften the model's hard edge just a touch so the cut doesn't look jagged.
        let mask = CIImage(cvPixelBuffer: maskBuffer)
            .applyingGaussianBlur(sigma: 0.8)
            .cropped(to: full)

        // Work on a canvas padded on every side so the border can grow past the frame.
        let canvas = full.insetBy(dx: -pad, dy: -pad)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let paddedMask = mask.composited(over: CIImage(color: .black).cropped(to: canvas))

        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = paddedMask
        dilate.radius = Float(r)
        let outline = (dilate.outputImage ?? paddedMask)
            .applyingGaussianBlur(sigma: Double(r) * 0.18)
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.2])

        let white = CIFilter.blendWithMask()
        white.inputImage = CIImage(color: .white).cropped(to: canvas)
        white.backgroundImage = clear
        white.maskImage = outline

        let cut = CIFilter.blendWithMask()
        cut.inputImage = image
        cut.backgroundImage = clear
        cut.maskImage = paddedMask

        guard let whiteLayer = white.outputImage, let cutLayer = cut.outputImage else { return .failure(.render) }
        let crop = CGRect(x: box.minX - pad, y: full.height - box.maxY - pad,
                          width: box.width + pad * 2, height: box.height + pad * 2)
        let composed = cutLayer.composited(over: whiteLayer).cropped(to: crop)
        guard let out = context.createCGImage(composed, from: crop, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return .failure(.render) }
        return .success(out)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Bounding box of the mask in top-left-origin pixel coordinates.
    private static func boundingBox(of buf: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let isFloat = CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent32Float
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base.advanced(by: y * stride)
            for x in 0..<w {
                let v: Float = isFloat ? row.assumingMemoryBound(to: Float.self)[x]
                                       : Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                if v > 0.5 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// A catch's sticker and what it would take to cut a different object instead.
struct StickerCut: Sendable {
    var png: Data
    let lift: StickerMaker.Lift
    /// Labels worth cutting, best first; `index` is the one showing.
    let order: [Int]
    var index = 0
    let reason: PickReason

    var canRecut: Bool { order.count > 1 }

    /// The best object, falling to the next whenever one won't cut (too small, say).
    static func make(_ lift: StickerMaker.Lift, numberBox: CGRect?) -> Result<StickerCut, StickerMaker.Failure> {
        guard let pick = StickerMaker.rank(lift, numberBox: numberBox) else { return .failure(.noSubject) }
        var failure = StickerMaker.Failure.noSubject
        for (i, label) in pick.order.enumerated() {
            switch StickerMaker.cut(lift, instance: label) {
            case .success(let cg):
                guard let png = StickerMaker.pngData(cg) else { return .failure(.render) }
                return .success(StickerCut(png: png, lift: lift, order: pick.order, index: i, reason: pick.reason))
            case .failure(let f):
                failure = f
            }
        }
        return .failure(failure)
    }

    /// The next object in line, wrapping round; nil when none of the others will cut.
    func next() -> StickerCut? {
        for step in 1..<max(order.count, 1) {
            let i = (index + step) % order.count
            if let cg = try? StickerMaker.cut(lift, instance: order[i]).get(), let png = StickerMaker.pngData(cg) {
                var out = self
                out.png = png
                out.index = i
                return out
            }
        }
        return nil
    }
}
