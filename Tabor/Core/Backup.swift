import Foundation

/// The JSON inside a TABOR backup ZIP (`tabor-backup.json`, next to a `photos/` folder).
public struct BackupManifest: Codable, Sendable {
    public struct Sighting: Codable, Hashable, Sendable {
        public var id: UUID
        public var number: Int
        public var modelId: String
        public var date: Date
        public var latitude: Double?
        public var longitude: Double?
        public var street: String?
        public var district: String?
        public var line: String?
        public var photoFile: String?
        public var stickerFile: String?
        public var weatherCode: Int?
        public var temperature: Double?

        public init(id: UUID, number: Int, modelId: String, date: Date, latitude: Double? = nil,
                    longitude: Double? = nil, street: String? = nil, district: String? = nil,
                    line: String? = nil, photoFile: String? = nil, stickerFile: String? = nil,
                    weatherCode: Int? = nil, temperature: Double? = nil) {
            self.id = id
            self.number = number
            self.modelId = modelId
            self.date = date
            self.latitude = latitude
            self.longitude = longitude
            self.street = street
            self.district = district
            self.line = line
            self.photoFile = photoFile
            self.stickerFile = stickerFile
            self.weatherCode = weatherCode
            self.temperature = temperature
        }
    }

    public struct Assignment: Codable, Hashable, Sendable {
        public var number: Int
        public var modelId: String

        public init(number: Int, modelId: String) {
            self.number = number
            self.modelId = modelId
        }
    }

    public static let currentVersion = 1
    public static let fileName = "tabor-backup.json"
    public static let photosFolder = "photos/"

    public var version: Int
    public var exported: Date
    public var sightings: [Sighting]
    public var manual: [Assignment]

    public init(exported: Date = Date(), sightings: [Sighting], manual: [Assignment]) {
        version = Self.currentVersion
        self.exported = exported
        self.sightings = sightings
        self.manual = manual
    }

    /// Every photo and sticker file the backup refers to.
    public var files: [String] {
        Array(Set(sightings.flatMap { [$0.photoFile, $0.stickerFile].compactMap { $0 } })).sorted()
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let m = try d.decode(BackupManifest.self, from: data)
        guard m.version <= currentVersion else { throw BackupError.newerVersion(m.version) }
        return m
    }

    /// What an import adds to a book that already holds `existingIds` and `existingManual`:
    /// importing the same backup twice changes nothing, and hand-picked models already on
    /// this phone win over the backup's.
    public func merge(existingIds: Set<UUID>, existingManual: Set<Int>) -> (sightings: [Sighting], manual: [Assignment]) {
        var seen = existingIds
        let newSightings = sightings.filter { seen.insert($0.id).inserted }
        var numbers = existingManual
        let newManual = manual.filter { numbers.insert($0.number).inserted }
        return (newSightings, newManual)
    }
}

public enum BackupError: Error, LocalizedError, Equatable {
    case newerVersion(Int)
    case missingManifest

    public var errorDescription: String? {
        switch self {
        case .newerVersion: String(localized: "This backup was made by a newer version of TABOR. Update the app first.")
        case .missingManifest: String(localized: "That file isn't a TABOR backup.")
        }
    }
}
