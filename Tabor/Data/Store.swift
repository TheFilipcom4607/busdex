import Foundation
import SwiftData

// CloudKit sync needs every property optional or defaulted, and no unique constraints.
@Model
final class Sighting {
    var id: UUID = UUID()
    var number: Int = 0
    var modelId: String = ""
    var date: Date = Date.now
    var latitude: Double?
    var longitude: Double?
    /// Street name from reverse geocoding, e.g. "Rakowiecka".
    var street: String?
    /// District, e.g. "Mokotów".
    var district: String?
    var line: String?
    var photoFile: String?
    /// Die-cut PNG (vehicle lifted off the background with a white border).
    var stickerFile: String?
    /// WMO weather code and °C at the catch, filled in from Open-Meteo for the weather badges.
    var weatherCode: Int?
    var temperature: Double?

    init(id: UUID = UUID(), number: Int, modelId: String, date: Date = .now, line: String? = nil,
         photoFile: String? = nil, stickerFile: String? = nil) {
        self.id = id
        self.number = number
        self.modelId = modelId
        self.date = date
        self.line = line
        self.photoFile = photoFile
        self.stickerFile = stickerFile
    }

    var record: SightingRecord {
        SightingRecord(number: number, modelId: modelId, date: date, line: line, district: district, street: street,
                       latitude: latitude, longitude: longitude, weatherCode: weatherCode, temperature: temperature,
                       hasSticker: stickerFile != nil)
    }
}

/// Numbers the user tied to a model by hand — they override the prefix table.
/// Not `.unique` (CloudKit can't enforce it): writers update an existing row instead, and
/// `map` tolerates the duplicates two synced phones can still produce.
@Model
final class ManualAssignment {
    var number: Int = 0
    var modelId: String = ""

    init(number: Int, modelId: String) {
        self.number = number
        self.modelId = modelId
    }
}

enum Fleet {
    /// The bundled snapshot, or a newer one downloaded from GitHub (see `FleetUpdater`).
    /// Picked once per launch; if neither loads, the app opens with an empty catalog.
    static let catalog: FleetCatalog = {
        let bundled = Bundle.main.url(forResource: "fleet", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(FleetCatalog.validated)
        var downloaded: FleetCatalog?
        if let data = try? Data(contentsOf: FleetUpdater.downloadedURL) {
            downloaded = FleetCatalog.validated(json: data)
            // Unreadable: drop it so the next check downloads a fresh copy.
            if downloaded == nil { try? FileManager.default.removeItem(at: FleetUpdater.downloadedURL) }
        }
        return FleetCatalog.preferred(bundled: bundled, downloaded: downloaded) ?? .empty
    }()
}

enum TaborStore {
    static let models: [any PersistentModel.Type] = [Sighting.self, ManualAssignment.self]

    /// Syncs through iCloud when the app has the CloudKit entitlement and the user is signed
    /// in; otherwise (or if the CloudKit store can't open) the same store stays local.
    static let container: ModelContainer = {
        let schema = Schema(models)
        // `groupContainer: .none` keeps the store where it has always been: the default,
        // `.automatic`, would move it into the widget's App Group and strand existing catches.
        func open(_ cloud: ModelConfiguration.CloudKitDatabase) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, groupContainer: .none,
                                                                               cloudKitDatabase: cloud))
        }
        if let synced = try? open(.automatic) { return synced }
        do {
            return try open(.none)
        } catch {
            fatalError("Can't open the catch store: \(error)")
        }
    }()
}

extension Array where Element == Sighting {
    var stats: CollectionStats { CollectionStats(sightings: map(\.record)) }

    func of(number: Int, modelId: String) -> [Sighting] {
        filter { $0.number == number && $0.modelId == modelId }.sorted { $0.date > $1.date }
    }

    /// Best photo for a vehicle: the most recent sighting that has one.
    func photo(number: Int, modelId: String) -> String? {
        of(number: number, modelId: modelId).lazy.compactMap(\.photoFile).first
    }

    /// The vehicle's die-cut sticker, newest first.
    func sticker(number: Int, modelId: String) -> String? {
        of(number: number, modelId: modelId).lazy.compactMap(\.stickerFile).first
    }
}

extension ModelContext {
    /// Records a hand-picked model for a number, updating the existing row if there is one.
    func assign(number: Int, to modelId: String, existing: [ManualAssignment]) {
        let rows = existing.filter { $0.number == number }
        if let first = rows.first {
            first.modelId = modelId
            rows.dropFirst().forEach { delete($0) }
        } else {
            insert(ManualAssignment(number: number, modelId: modelId))
        }
    }

    /// Deletes a sighting with its photo and sticker files.
    func deleteSighting(_ s: Sighting) {
        [s.photoFile, s.stickerFile].compactMap { $0 }.forEach(PhotoStore.delete)
        delete(s)
    }
}

extension Array where Element == ManualAssignment {
    var map: [Int: String] { Dictionary(map { ($0.number, $0.modelId) }, uniquingKeysWith: { _, b in b }) }
}
