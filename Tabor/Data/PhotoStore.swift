import ImageIO
import Photos
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Catch photos and stickers. They live in the store as `StoredFile`s, so iCloud syncs them
/// with the catches; the names are what sightings point at. Stickers load as downsampled
/// thumbnails.
enum PhotoStore {
    /// Where builds before iCloud sync kept them as loose files. Reads still look here until
    /// `moveFolderIntoStore` has taken them in.
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Photos", isDirectory: true)
    }()

    private static let cache = NSCache<NSString, UIImage>()
    private static let aspects = NSCache<NSString, NSNumber>()

    /// Goes up when files may have arrived from iCloud. Thumbnails read it, so a sticker
    /// that synced in after its catch shows up without the screen being reopened.
    @MainActor static let revision = Revision()

    @Observable final class Revision {
        var value = 0
    }

    // A context per call: what it fetches (whole photos) goes when it does, instead of piling
    // up in a long-lived one.
    private static func fetch(_ name: String, in context: ModelContext) -> [StoredFile] {
        (try? context.fetch(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.name == name }))) ?? []
    }

    static func save(_ data: Data, ext: String = "jpg") -> String? {
        let name = UUID().uuidString + "." + ext
        do {
            try write(data, name: name)
            return name
        } catch {
            return nil
        }
    }

    static func data(_ file: String) -> Data? {
        let context = ModelContext(TaborStore.container)
        if let data = fetch(file, in: context).lazy.compactMap(\.data).first { return data }
        return try? Data(contentsOf: dir.appendingPathComponent(file))
    }

    static func exists(_ file: String) -> Bool {
        let context = ModelContext(TaborStore.container)
        let count = (try? context.fetchCount(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.name == file }))) ?? 0
        return count > 0 || FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
    }

    /// Stores a file under a given name (restoring a backup keeps the original names).
    static func write(_ data: Data, name: String) throws {
        let context = ModelContext(TaborStore.container)
        context.insert(StoredFile(name: name, data: data))
        try context.save()
    }

    static func delete(_ file: String) {
        let context = ModelContext(TaborStore.container)
        fetch(file, in: context).forEach(context.delete)
        try? context.save()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        cache.removeAllObjects()
    }

    /// Removes every stored photo and sticker.
    static func deleteAll() {
        let context = ModelContext(TaborStore.container)
        try? context.delete(model: StoredFile.self)
        try? context.save()
        try? FileManager.default.removeItem(at: dir)
        cache.removeAllObjects()
    }

    /// Takes the loose files of builds before iCloud sync into the store, a few at a time, and
    /// deletes each once it's safely in. Only files a catch points at: anything else is a
    /// leftover that iCloud shouldn't carry, and stays where it is.
    static func moveFolderIntoStore() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { return }
        let context = ModelContext(TaborStore.container)
        let sightings = (try? context.fetch(FetchDescriptor<Sighting>())) ?? []
        let used = Set(sightings.flatMap { [$0.photoFile, $0.stickerFile] }.compactMap { $0 })
        let moving = names.filter(used.contains)
        for start in stride(from: 0, to: moving.count, by: 8) {
            let ok: Bool = autoreleasepool {
                let context = ModelContext(TaborStore.container)
                var moved: [String] = []
                for name in moving[start..<min(start + 8, moving.count)] {
                    let url = dir.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url) else { continue }
                    if fetch(name, in: context).isEmpty { context.insert(StoredFile(name: name, data: data)) }
                    moved.append(name)
                }
                do { try context.save() } catch { return false }
                moved.forEach { try? fm.removeItem(at: dir.appendingPathComponent($0)) }
                return true
            }
            // Can't save (disk full?): the rest stay as files, still read from the folder.
            guard ok else { return }
        }
    }

    /// The book's own copy of a catch: the app never shows it bigger than a screen, so it keeps
    /// 1600 px on the long side as HEIC, 300–400 KB instead of 1–2 MB of JPEG (JPEG at the same
    /// size would need to look visibly worse). Upright, with its metadata. The shot saved to
    /// Photos stays full size. Nil if it can't be re-encoded or wouldn't be smaller.
    static func compact(_ data: Data, maxPixel: Int = 1600, quality: Double = 0.6) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // Drawn upright already: drop the rotation and the old size from the metadata.
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        props[kCGImageDestinationLossyCompressionQuality] = quality
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        // Already small (an old or low-res photo): the original is as good and no bigger.
        return out.length < data.count ? out as Data : nil
    }

    /// "heic" for the book's own copies and imports shot on an iPhone, "jpg" for other shots — so shared
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
        guard let r = Viewfinder.region(of: frame, in: viewSize, imageSize: CGSize(width: iw, height: ih)) else { return nil }
        let rect = CGRect(x: r.minX * iw, y: r.minY * ih, width: r.width * iw, height: r.height * ih).integral
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

    /// Width over height as the photo is seen (EXIF rotation applied), from its header alone.
    static func aspect(_ file: String) -> Double? {
        if let hit = aspects.object(forKey: file as NSString) { return hit.doubleValue }
        guard let data = data(file), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0
        else { return nil }
        // Orientations 5–8 are turned a quarter.
        let turned = (props[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        let aspect = turned ? h / w : w / h
        aspects.setObject(aspect as NSNumber, forKey: file as NSString)
        return aspect
    }

    @MainActor static func thumbnail(_ file: String, maxPixel: Int) -> UIImage? {
        _ = revision.value
        let key = "\(file)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = data(file), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
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
