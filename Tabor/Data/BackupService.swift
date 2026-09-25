import Foundation
import SwiftData

/// Writes the whole book (sightings, hand-picked models, photos and stickers) to one ZIP,
/// and merges such a ZIP back in.
enum BackupService {
    /// Builds `TABOR backup <date>.zip` in the temporary folder, for the share sheet.
    static func export(_ manifest: BackupManifest) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TABOR backup \(stamp.string(from: manifest.exported)).zip")
        try? FileManager.default.removeItem(at: url)
        let zip = try ZipWriter(url: url)
        try zip.add(path: BackupManifest.fileName, data: manifest.encoded(), modified: manifest.exported)
        for file in manifest.files {
            // One file at a time, so memory stays flat however big the book is.
            try autoreleasepool {
                guard let data = try? Data(contentsOf: PhotoStore.url(file)) else { return }
                try zip.add(path: BackupManifest.photosFolder + file, data: data)
            }
        }
        try zip.finish()
        return url
    }

    /// Reads a backup and restores the photos it carries; the caller inserts the records.
    static func read(_ url: URL) throws -> BackupManifest {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try ZipReader(url: url)
        guard let path = zip.path(endingWith: BackupManifest.fileName) else { throw BackupError.missingManifest }
        let manifest = try BackupManifest.decode(zip.read(path))
        // Photos sit next to the manifest (inside a folder if the ZIP was re-made by Finder).
        let root = String(path.dropLast(BackupManifest.fileName.count))
        for file in manifest.files where isPlainName(file) && !PhotoStore.exists(file) {
            try autoreleasepool {
                let entry = root + BackupManifest.photosFolder + file
                guard zip.contains(entry) else { return }
                try PhotoStore.write(zip.read(entry), name: file)
            }
        }
        return manifest
    }

    static func manifest(sightings: [Sighting], manual: [ManualAssignment]) -> BackupManifest {
        BackupManifest(sightings: sightings.map { s in
            BackupManifest.Sighting(id: s.id, number: s.number, modelId: s.modelId, date: s.date,
                                    latitude: s.latitude, longitude: s.longitude, street: s.street,
                                    district: s.district, line: s.line, photoFile: s.photoFile,
                                    stickerFile: s.stickerFile, weatherCode: s.weatherCode,
                                    temperature: s.temperature)
        }, manual: manual.map { .init(number: $0.number, modelId: $0.modelId) })
    }

    /// Only bare file names land in the photo folder: no "../" tricks from a crafted ZIP.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }
}

extension ModelContext {
    /// Adds what a backup holds that this book doesn't. Returns how many sightings were new.
    @discardableResult
    func restore(_ backup: BackupManifest, into sightings: [Sighting], manual: [ManualAssignment]) throws -> Int {
        let merged = backup.merge(existingIds: Set(sightings.map(\.id)), existingManual: Set(manual.map(\.number)))
        for r in merged.sightings {
            let s = Sighting(id: r.id, number: r.number, modelId: r.modelId, date: r.date, line: r.line,
                             photoFile: r.photoFile.flatMap(existingFile), stickerFile: r.stickerFile.flatMap(existingFile))
            s.latitude = r.latitude
            s.longitude = r.longitude
            s.street = r.street
            s.district = r.district
            s.weatherCode = r.weatherCode
            s.temperature = r.temperature
            insert(s)
        }
        for a in merged.manual { insert(ManualAssignment(number: a.number, modelId: a.modelId)) }
        try save()
        return merged.sightings.count
    }

    private func existingFile(_ name: String) -> String? {
        BackupService.isPlainName(name) && PhotoStore.exists(name) ? name : nil
    }
}
