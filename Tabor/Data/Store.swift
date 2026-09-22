import Foundation
import SwiftData

@Model
final class Sighting {
    var id: UUID
    var number: Int
    var modelId: String
    var date: Date
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

    init(number: Int, modelId: String, date: Date = .now, line: String? = nil, photoFile: String? = nil,
         stickerFile: String? = nil) {
        id = UUID()
        self.number = number
        self.modelId = modelId
        self.date = date
        self.line = line
        self.photoFile = photoFile
        self.stickerFile = stickerFile
    }

    var record: SightingRecord { SightingRecord(number: number, modelId: modelId, date: date) }
}

/// Numbers the user tied to a model by hand — they override the prefix table.
@Model
final class ManualAssignment {
    @Attribute(.unique) var number: Int
    var modelId: String

    init(number: Int, modelId: String) {
        self.number = number
        self.modelId = modelId
    }
}

enum Fleet {
    static let catalog: FleetCatalog = {
        guard let url = Bundle.main.url(forResource: "fleet", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? FleetCatalog(json: data)
        else { fatalError("fleet.json missing or malformed") }
        return catalog
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

extension Array where Element == ManualAssignment {
    var map: [Int: String] { Dictionary(map { ($0.number, $0.modelId) }, uniquingKeysWith: { _, b in b }) }
}
