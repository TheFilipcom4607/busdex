import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Catch photos live in Application Support; stickers load downsampled thumbnails.
enum PhotoStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let cache = NSCache<NSString, UIImage>()

    static func save(_ data: Data, ext: String = "jpg") -> String? {
        let name = UUID().uuidString + "." + ext
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func url(_ file: String) -> URL { dir.appendingPathComponent(file) }

    /// Removes every stored photo and sticker (the folder itself stays).
    static func deleteAll() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
        cache.removeAllObjects()
    }

    /// "heic" for library imports shot on an iPhone, "jpg" for camera catches — so shared
    /// files open everywhere with the right type.
    static func fileExtension(of data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let id = CGImageSourceGetType(src),
              let ext = UTType(id as String)?.preferredFilenameExtension
        else { return "jpg" }
        return ext == "jpeg" ? "jpg" : ext
    }

    /// Crops a camera shot to the part shown inside `frame`, given the preview filled a view
    /// of `viewSize` (aspect-fill, like the capture preview). Re-encodes as an upright JPEG,
    /// keeping the EXIF/GPS metadata.
    static func crop(_ data: Data, viewSize: CGSize, frame: CGRect) -> Data? {
        guard viewSize.width > 0, viewSize.height > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Full-size, upright decode.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let iw = CGFloat(upright.width), ih = CGFloat(upright.height)
        let scale = max(viewSize.width / iw, viewSize.height / ih)
        let offX = (viewSize.width - iw * scale) / 2, offY = (viewSize.height - ih * scale) / 2
        let rect = CGRect(x: (frame.minX - offX) / scale, y: (frame.minY - offY) / scale,
                          width: frame.width / scale, height: frame.height / scale)
            .intersection(CGRect(x: 0, y: 0, width: iw, height: ih)).integral
        guard rect.width > 100, rect.height > 100, let cut = upright.cropping(to: rect) else { return nil }

        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyPixelWidth] = nil
        meta[kCGImagePropertyPixelHeight] = nil
        meta[kCGImageDestinationLossyCompressionQuality] = 0.92
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cut, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Decodes a downsampled, upright copy of an image without touching the full-res pixels.
    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func thumbnail(_ file: String, maxPixel: Int) -> UIImage? {
        let key = "\(file)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url(file) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Date and GPS position embedded in a photo, if any (imported shots).
    static func metadata(_ data: Data) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil) }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            date = f.date(from: s)
        }
        guard let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return (date, nil, nil) }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
        return (date, lat, lon)
    }

    /// Adds the full-res shot to the system photo library (add-only permission).
    static func saveToGallery(_ data: Data) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
