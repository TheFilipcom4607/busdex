import Foundation

/// Photos shared to TABOR from another app (#34). The share extension can't run the catch
/// itself (too little memory for the sticker cut), so it leaves the photo's own bytes, EXIF
/// date and place included, in the App Group and opens the app, which catches it like a photo
/// picked from the library.
enum ShareInbox {
    /// What the extension opens; the app also checks the inbox whenever it comes to the front.
    static let url = URL(string: "\(WidgetLink.scheme)://shared")!

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Keeps only this photo: the last one shared is the one you meant.
    static func save(_ data: Data, fileExtension: String) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = fileExtension.isEmpty ? "jpg" : fileExtension.lowercased()
        try data.write(to: folder.appendingPathComponent("\(UUID().uuidString).\(ext)"), options: .atomic)
    }

    static var isEmpty: Bool {
        guard let folder else { return true }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty
    }

    /// The photo waiting, if any, and the inbox emptied: each share is caught once.
    static func take() -> Data? {
        guard let folder,
              let file = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first
        else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        return try? Data(contentsOf: file)
    }
}
