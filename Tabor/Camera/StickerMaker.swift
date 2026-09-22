import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

/// Turns a catch photo into a die-cut sticker: lifts the vehicle off the background
/// (the same foreground-instance model as "lift subject" in Photos), adds a thick white
/// border that follows its silhouette, and crops tight. Output is a transparent PNG.
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

    static func sticker(from data: Data, options: Options = Options()) -> CGImage? {
        try? make(from: data, options: options).get()
    }

    static func make(from data: Data, options: Options = Options()) -> Result<CGImage, Failure> {
        // Downsample + apply EXIF orientation in one go.
        guard let cg = PhotoStore.downsample(data, maxPixel: Int(options.maxSide)) else { return .failure(.decode) }
        return make(from: cg, options: options)
    }

    static func make(from cg: CGImage, options: Options = Options()) -> Result<CGImage, Failure> {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(.lifting(error.localizedDescription))
        }
        guard let obs = request.results?.first, let instance = largestInstance(obs) else { return .failure(.noSubject) }
        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try obs.generateScaledMaskForImage(forInstances: [instance], from: handler)
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

    /// The vehicle is almost always the biggest lifted subject; people and cars are smaller.
    private static func largestInstance(_ obs: VNInstanceMaskObservation) -> Int? {
        let buf = obs.instanceMask
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return obs.allInstances.first }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        var counts = [Int: Int]()
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w where row[x] != 0 { counts[Int(row[x]), default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key ?? obs.allInstances.first
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
