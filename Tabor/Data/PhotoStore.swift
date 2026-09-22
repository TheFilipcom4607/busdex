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

    /// "heic" for library imports shot on an iPhone, "jpg" for camera catches — so shared
    /// files open everywhere with the right type.
    static func fileExtension(of data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let id = CGImageSourceGetType(src),
              let ext = UTType(id as String)?.preferredFilenameExtension
        else { return "jpg" }
        return ext == "jpeg" ? "jpg" : ext
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
