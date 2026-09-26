import Foundation
import ImageIO
import UIKit

/// Debug mode (Me → Settings): every shot — failed reads, retakes and capture errors
/// included — gets its own folder in Documents/Debug with the photo, the sticker and an
/// `info.json` of what the camera, OCR and sticker cutter saw and what you did next.
/// Browse it in Files › On My iPhone › TABOR, or share it all as a ZIP from Settings.
final class DebugRecord: @unchecked Sendable {
    static let enabledKey = "debugMode"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Debug", isDirectory: true)

    struct Obs: Codable {
        let text: String
        let confidence: Float
        let height: Double
    }

    struct Candidate: Codable {
        let number: Int
        let score: Double
    }

    struct OCR: Codable {
        var pass: String
        var result: Int?
        var durationMs: Int
        var candidates: [Candidate]
        var full: [Obs]
        var tiles: [Obs]
    }

    struct Sticker: Codable {
        var ok: Bool
        var durationMs: Int
        var failure: String?
    }

    struct Event: Codable {
        let at: Date
        let what: String
        var number: Int?
        var modelId: String?
        var line: String?
    }

    /// What the live GPS feed knew at the shutter, and what it changed.
    struct Live: Codable {
        var status: String
        /// Seconds between the feed's last refresh and the shot.
        var snapshotAge: Int?
        /// "TRAM 4235 · line 33 · 60 m", nearest first.
        var nearby: [String] = []
        var boosted: [Int] = []
        var rescued: [LiveHints.Rescue] = []
        /// "ambiguous: a, b → certain: b" when a nearby vehicle settled the model.
        var resolved: String?
        /// "live" when the line came from the feed, "none" when it couldn't.
        var lineSource: String?
    }

    struct Info: Codable {
        var id: String
        var date: Date
        var source: String
        var mode: String
        var app: String
        var device: String
        var system: String
        var error: String?
        var image: [String: String] = [:]
        /// Number live OCR had locked when the shutter fired.
        var liveReading: Int?
        /// Raw text from the last live frame before the shutter.
        var liveFrame: [Obs]?
        var captureAngle: Double?
        /// Live OCR's frame size, the region it read (normalised) and the camera's heat level.
        var liveOCR: String?
        /// How the shot was cropped to the viewfinder brackets.
        var crop: String?
        var torch: Bool?
        /// The read that decided the number ("live" skips it).
        var ocr: OCR?
        /// With a live lock, the still is re-read in the background to compare.
        var stillCheck: OCR?
        var match: String?
        var suggestedModel: String?
        var sticker: Sticker?
        var geotag: String?
        var live: Live?
        var events: [Event] = []
    }

    let folder: URL
    private var info: Info
    private let queue = DispatchQueue(label: "tabor.debug")

    private static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Starts a record if debug mode is on; nil otherwise, so call sites stay one-liners.
    static func begin(source: String, mode: CatchMode) -> DebugRecord? {
        guard isEnabled else { return nil }
        return DebugRecord(source: source, mode: mode)
    }

    private init(source: String, mode: CatchMode) {
        let now = Date()
        let id = String(UUID().uuidString.prefix(8))
        folder = Self.root.appendingPathComponent("\(Self.folderName.string(from: now)) \(source) \(id)", isDirectory: true)
        let bundle = Bundle.main.infoDictionary ?? [:]
        info = Info(id: id, date: now, source: source, mode: mode.rawValue,
                    app: "\(bundle["CFBundleShortVersionString"] ?? "?") (\(bundle["CFBundleVersion"] ?? "?"))",
                    device: Self.machine, system: "iOS \(UIDevice.current.systemVersion)")
        queue.async {
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.write()
        }
    }

    // MARK: - Recording

    func update(_ change: @escaping @Sendable (inout Info) -> Void) {
        queue.async {
            change(&self.info)
            self.write()
        }
    }

    func log(_ what: String, number: Int? = nil, modelId: String? = nil, line: String? = nil) {
        let e = Event(at: Date(), what: what, number: number, modelId: modelId, line: line)
        update { $0.events.append(e) }
    }

    func attach(photo data: Data) {
        let ext = PhotoStore.fileExtension(of: data)
        let meta = Self.imageInfo(data)
        queue.async {
            try? data.write(to: self.folder.appendingPathComponent("photo.\(ext)"))
            self.info.image = meta
            self.write()
        }
    }

    /// The uncropped camera frame, when the shot was cropped to the brackets.
    func attach(original data: Data) {
        queue.async { try? data.write(to: self.folder.appendingPathComponent("photo-full.jpg")) }
    }

    func attach(sticker png: Data) {
        queue.async { try? png.write(to: self.folder.appendingPathComponent("sticker.png")) }
    }

    private func write() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let json = try? enc.encode(info) else { return }
        try? json.write(to: folder.appendingPathComponent("info.json"), options: .atomic)
    }

    // MARK: - Helpers

    static func obs(_ list: [TextObservation]) -> [Obs] {
        list.map { Obs(text: $0.text, confidence: $0.confidence, height: ($0.height * 10_000).rounded() / 10_000) }
    }

    static func ocr(_ r: TextReader.Report) -> OCR {
        OCR(pass: r.pass, result: r.number, durationMs: Int(r.duration * 1000),
            candidates: r.candidates.sorted { $0.score > $1.score }
                .map { Candidate(number: $0.number, score: ($0.score * 1000).rounded() / 1000) },
            full: obs(r.full), tiles: obs(r.tiles))
    }

    static func describe(_ m: ModelMatch) -> String {
        switch m {
        case .certain(let v): "certain: \(v.id)"
        case .ambiguous(let vs): "ambiguous: " + vs.map(\.id).joined(separator: ", ")
        case .unknown: "unknown"
        }
    }

    private static var machine: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func imageInfo(_ data: Data) -> [String: String] {
        var out = ["bytes": "\(data.count)", "type": PhotoStore.fileExtension(of: data)]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return out }
        if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] { out["pixels"] = "\(w)×\(h)" }
        if let o = props[kCGImagePropertyOrientation] { out["exifOrientation"] = "\(o)" }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let d = exif[kCGImagePropertyExifDateTimeOriginal] { out["exifDate"] = "\(d)" }
            if let lens = exif[kCGImagePropertyExifLensModel] { out["lens"] = "\(lens)" }
        }
        out["gps"] = props[kCGImagePropertyGPSDictionary] == nil ? "no" : "yes"
        return out
    }

    // MARK: - Managing the folder

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) ?? 0
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Zips the whole Debug folder into a temporary file for the share sheet.
    static func exportZip() -> URL? {
        guard count > 0 else { return nil }
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &error) { zipped in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("TABOR debug \(folderName.string(from: Date())).zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipped, to: dest)) != nil { result = dest }
        }
        return result
    }
}
