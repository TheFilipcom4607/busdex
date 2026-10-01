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
        case decode, lifting(String), noSubject, onlyPeople, mask(String), tinySubject, render

        var description: String {
            switch self {
            case .decode: "couldn't decode the photo"
            case .lifting(let e): "subject lifting failed: \(e)"
            case .noSubject: "no subject found"
            case .onlyPeople: "only people lifted, none with the number on"
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

        /// Exactly which pixels are people, worked out the first time a cut needs it.
        private(set) lazy var personMask: CVPixelBuffer? = {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? handler.perform([request])
            return request.results?.first?.pixelBuffer
        }()
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

    /// People who stand out of the object's outline, as in front of the bus: the lifter
    /// merges whoever touches the bus into it. Passengers behind the windows sit inside
    /// the outline, so they stay. Also returns that outline (without the people), and
    /// `below`: the ground around each of those people under the vehicle's bottom edge, where
    /// what they ride or stand by (a bike, a pole's foot) sticks out.
    static func standing(in lift: Lift, instance: Int) -> (people: [CGRect], outline: CGRect, below: [CGRect]) {
        let none = ([CGRect](), CGRect.zero, [CGRect]())
        guard !lift.people.isEmpty else { return none }
        let buf = lift.observation.instanceMask
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return none }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let boxes = lift.people.map { r in
            (x0: Int(r.minX * CGFloat(w)), x1: Int(r.maxX * CGFloat(w)), y0: Int(r.minY * CGFloat(h)), y1: Int(r.maxY * CGFloat(h)))
        }
        // A bike reaches out sideways from its rider; the vehicle's bottom edge is measured
        // away from all that.
        let around = boxes.map { b in (x0: b.x0 - (b.x1 - b.x0), x1: b.x1 + (b.x1 - b.x0)) }
        var bottom = -1
        // The outline of the object without the people, and how much of it each person is.
        var minX = w, minY = h, maxX = -1, maxY = -1, pixels = 0
        var inside = [Int](repeating: 0, count: boxes.count)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w where Int(row[x]) == instance {
                pixels += 1
                var person = false
                for (i, b) in boxes.enumerated() where x >= b.x0 && x < b.x1 && y >= b.y0 && y < b.y1 {
                    inside[i] += 1
                    person = true
                }
                if !person {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                if !around.contains(where: { x >= $0.x0 && x < $0.x1 }) { bottom = max(bottom, y) }
            }
        }
        // Mostly people (or nothing but): it's a person's sticker, leave it whole.
        guard maxX >= minX, Double(inside.reduce(0, +)) < Double(pixels) * SubjectPicker.personLimit else { return none }
        let outline = CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                             width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
        let grown = outline.insetBy(dx: -outline.width * 0.05, dy: -outline.height * 0.05)
        let people = lift.people.indices.filter { inside[$0] > 0 && !grown.contains(lift.people[$0]) }
        // A margin under the bottom edge, for the vehicle's own shadow and tyres.
        let floor = bottom < 0 ? 1 : CGFloat(bottom) / CGFloat(h) + 0.02
        let below = people.map { i -> CGRect in
            let b = lift.people[i]
            return CGRect(x: b.minX - b.width, y: floor, width: b.width * 3, height: max(0, 1 - floor))
        }.filter { $0.height > 0 }
        return (people.map { lift.people[$0] }, grown, below)
    }

    /// One object of the lift as a sticker, without anyone standing in front of it.
    static func cut(_ lift: Lift, instance: Int, options: Options = Options()) -> Result<CGImage, Failure> {
        let cg = lift.image
        var maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try lift.observation.generateScaledMaskForImage(forInstances: [instance], from: lift.handler)
        } catch {
            return .failure(.mask(error.localizedDescription))
        }

        let image = CIImage(cgImage: cg)
        let full = image.extent
        let erase = standing(in: lift, instance: instance)
        if !erase.people.isEmpty, let people = lift.personMask,
           let without = erasing(erase.people, outside: erase.outline, below: erase.below, people: people, from: maskBuffer, extent: full) {
            maskBuffer = without
        }
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

    /// The mask minus the people's own pixels inside `boxes` (normalised, top-left origin),
    /// grown a little so no fringe of them is left on the edge, and minus whatever else of
    /// those boxes lies outside the object's `outline`: crumbs of shoe or shadow. Hard-edged,
    /// and without islands the cut leaves behind.
    private static func erasing(_ boxes: [CGRect], outside outline: CGRect, below: [CGRect], people: CVPixelBuffer,
                                from mask: CVPixelBuffer, extent full: CGRect) -> CVPixelBuffer? {
        // Core Image counts from the bottom.
        let pixels = { (b: CGRect) in
            CGRect(x: b.minX * full.width, y: (1 - b.maxY) * full.height, width: b.width * full.width, height: b.height * full.height)
        }
        let p = CIImage(cvPixelBuffer: people)
        let scaled = p.transformed(by: CGAffineTransform(scaleX: full.width / p.extent.width, y: full.height / p.extent.height))
        let black = CIImage(color: .black).cropped(to: full)
        let area = boxes.reduce(black) { CIImage(color: .white).cropped(to: pixels($1)).composited(over: $0) }
        // Where segmentation is only half sure, it's still the person: a soft edge left a ghost.
        let sure = CIFilter.colorThreshold()
        sure.inputImage = scaled.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: area])
        sure.threshold = 0.15
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = sure.outputImage
        grow.radius = Float(max(3, full.width * 0.008))
        guard let person = grow.outputImage?.cropped(to: full) else { return nil }
        let beyond = below.reduce(CIImage(color: .black).cropped(to: pixels(outline)).composited(over: area)) {
            CIImage(color: .white).cropped(to: pixels($1)).composited(over: $0)
        }
        let keep = person.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: beyond])
            .cropped(to: full)
            .applyingFilter("CIColorInvert")
        let out = CIImage(cvPixelBuffer: mask)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
            .cropped(to: full)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(full.width), Int(full.height), kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let buffer else { return nil }
        context.render(out, to: buffer, bounds: full, colorSpace: nil)
        dropIslands(buffer)
        return buffer
    }

    /// Clears every patch of the mask under a twentieth the size of the biggest one: what's
    /// left of a person after the cut, cut off from the vehicle. A vehicle split in two by
    /// someone standing in front keeps both halves.
    private static func dropIslands(_ buf: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let px = base.assumingMemoryBound(to: UInt8.self)
        var label = [Int32](repeating: 0, count: w * h)
        var sizes: [Int] = [0]
        var stack: [Int] = []
        for start in 0..<(w * h) where label[start] == 0 && px[(start / w) * stride + start % w] > 127 {
            let id = Int32(sizes.count)
            var count = 0
            label[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let j = ny * w + nx
                    if label[j] == 0, px[ny * stride + nx] > 127 { label[j] = id; stack.append(j) }
                }
            }
            sizes.append(count)
        }
        guard let biggest = sizes.max(), biggest > 0 else { return }
        for y in 0..<h {
            for x in 0..<w {
                let l = Int(label[y * w + x])
                // Soft edge pixels (≤127) belong to no patch; keep them only beside a kept one.
                if l == 0 ? px[y * stride + x] > 0 && !keptNear(x, y) : sizes[l] * 20 < biggest {
                    px[y * stride + x] = 0
                }
            }
        }

        func keptNear(_ x: Int, _ y: Int) -> Bool {
            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let l = Int(label[ny * w + nx])
                    if l != 0, sizes[l] * 20 >= biggest { return true }
                }
            }
            return false
        }
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
        guard let pick = StickerMaker.rank(lift, numberBox: numberBox) else {
            return .failure(lift.observation.allInstances.isEmpty ? .noSubject : .onlyPeople)
        }
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
