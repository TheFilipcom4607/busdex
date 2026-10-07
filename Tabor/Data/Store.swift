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
    /// A coupled tram's second car, added with the car you shot: that car's number. Only a
    /// link for display and badges; each car keeps its own files and can go on its own.
    var pairedWith: Int?
    /// Picked on the vehicle page as the picture the book shows for this vehicle, instead of
    /// the newest. Only one per vehicle is set; if two ever are, the newest wins.
    var cover: Bool?

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

    var hasPicture: Bool { stickerFile != nil || photoFile != nil }

    var record: SightingRecord {
        SightingRecord(number: number, modelId: modelId, date: date, line: line, district: district, street: street,
                       latitude: latitude, longitude: longitude, weatherCode: weatherCode, temperature: temperature,
                       hasSticker: stickerFile != nil, pairedWith: pairedWith)
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
        let container: ModelContainer
        if let synced = try? open(.automatic) {
            container = synced
        } else {
            do {
                container = try open(.none)
            } catch {
                fatalError("Can't open the catch store: \(error)")
            }
        }
        // Before any screen reads the book, so nothing shows a catch under a model it left.
        followSplits(in: ModelContext(container), catalog: Fleet.catalog)
        return container
    }()

    static let splitsSeenKey = "huntSplitsSeen"

    /// When a model has been split (the 120N family into Tramicus, Swing and Swing Duo),
    /// moves catches and hand-picked numbers to the part that has their number, and adds the
    /// new parts to a HUNT filter that had the old model picked. That last step happens once
    /// per part, so taking one out of the filter afterwards sticks.
    static func followSplits(in context: ModelContext, catalog: FleetCatalog, defaults: UserDefaults = .standard) {
        var changed = false
        for s in (try? context.fetch(FetchDescriptor<Sighting>())) ?? [] {
            if let to = catalog.moved(modelId: s.modelId, number: s.number) { s.modelId = to; changed = true }
        }
        for a in (try? context.fetch(FetchDescriptor<ManualAssignment>())) ?? [] {
            if let to = catalog.moved(modelId: a.modelId, number: a.number) { a.modelId = to; changed = true }
        }
        if changed { try? context.save() }

        let parts = catalog.models.filter { !$0.formerly.isEmpty }
        var seen = Set(defaults.stringArray(forKey: splitsSeenKey) ?? [])
        guard !parts.allSatisfy({ seen.contains($0.id) }) else { return }
        if let raw = defaults.string(forKey: "huntTargets") {
            var targets = HuntTargets(rawValue: raw)
            for m in parts where !seen.contains(m.id) && !targets.models.isDisjoint(with: m.formerly) {
                targets.models.insert(m.id)
            }
            defaults.set(targets.rawValue, forKey: "huntTargets")
        }
        seen.formUnion(parts.map(\.id))
        defaults.set(Array(seen).sorted(), forKey: splitsSeenKey)
    }
}

extension Array where Element == Sighting {
    var stats: CollectionStats { CollectionStats(sightings: map(\.record)) }

    func of(number: Int, modelId: String) -> [Sighting] {
        filter { $0.number == number && $0.modelId == modelId }.sorted { $0.date > $1.date }
    }

    /// The sighting picked for the book, if it still has a picture.
    func cover(number: Int, modelId: String) -> Sighting? {
        of(number: number, modelId: modelId).first { $0.cover == true && $0.hasPicture }
    }

    /// The vehicle's photo: the picked sighting's, else the most recent one.
    func photo(number: Int, modelId: String) -> String? {
        let list = of(number: number, modelId: modelId)
        if let c = list.first(where: { $0.cover == true && $0.hasPicture }), let p = c.photoFile { return p }
        return list.lazy.compactMap(\.photoFile).first
    }

    /// The vehicle's die-cut sticker: the picked sighting's (none if it has only a photo, so
    /// that photo shows), else the newest.
    func sticker(number: Int, modelId: String) -> String? {
        let list = of(number: number, modelId: modelId)
        if let c = list.first(where: { $0.cover == true && $0.hasPicture }) { return c.stickerFile }
        return list.lazy.compactMap(\.stickerFile).first
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
