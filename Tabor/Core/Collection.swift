import Foundation

/// A storage-agnostic view of one sighting, so the stats can be computed and tested
/// without SwiftData.
public struct SightingRecord: Hashable, Sendable {
    public let number: Int
    public let modelId: String
    public let date: Date
    public let line: String?
    /// Reverse-geocoded district, e.g. "Mokotów" (or a finer area like "Stary Mokotów").
    public let district: String?
    public let street: String?
    public let latitude: Double?
    public let longitude: Double?
    /// WMO weather code at the time of the catch (see `Weather`).
    public let weatherCode: Int?
    /// °C at the time of the catch.
    public let temperature: Double?
    public let hasSticker: Bool

    public init(number: Int, modelId: String, date: Date, line: String? = nil, district: String? = nil,
                street: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                weatherCode: Int? = nil, temperature: Double? = nil, hasSticker: Bool = false) {
        self.number = number
        self.modelId = modelId
        self.date = date
        self.line = line
        self.district = district
        self.street = street
        self.latitude = latitude
        self.longitude = longitude
        self.weatherCode = weatherCode
        self.temperature = temperature
        self.hasSticker = hasSticker
    }
}

public struct OwnedVehicle: Hashable, Sendable {
    public let number: Int
    public let modelId: String
    public let timesSeen: Int
    public let firstSeen: Date
    public let lastSeen: Date
}

public struct CollectionStats: Sendable {
    public let vehicles: [OwnedVehicle]
    private let byModel: [String: [OwnedVehicle]]

    public init(sightings: [SightingRecord]) {
        let groups = Dictionary(grouping: sightings) { "\($0.modelId)#\($0.number)" }
        vehicles = groups.values.map { g in
            let dates = g.map(\.date)
            return OwnedVehicle(number: g[0].number, modelId: g[0].modelId, timesSeen: g.count,
                                firstSeen: dates.min()!, lastSeen: dates.max()!)
        }.sorted { $0.number < $1.number }
        byModel = Dictionary(grouping: vehicles, by: \.modelId)
    }

    public var caught: Int { vehicles.count }

    public func owned(modelId: String) -> [OwnedVehicle] { byModel[modelId] ?? [] }
    public func ownedCount(modelId: String) -> Int { byModel[modelId]?.count ?? 0 }
    public var modelsTouched: Int { byModel.count }

    public func vehicle(number: Int, modelId: String) -> OwnedVehicle? {
        byModel[modelId]?.first { $0.number == number }
    }

    /// Owned vehicles ordered rarest model first, then by earliest catch.
    public func rarest(catalog: FleetCatalog, limit: Int) -> [OwnedVehicle] {
        vehicles.sorted { a, b in
            let fa = catalog.model(id: a.modelId)?.fleet ?? .max
            let fb = catalog.model(id: b.modelId)?.fleet ?? .max
            if fa != fb { return fa < fb }
            return a.firstSeen < b.firstSeen
        }.prefix(limit).map { $0 }
    }

    /// Caught vehicles that count toward the fleet total (vintage, test and unknown models don't).
    public func fleetCaught(catalog: FleetCatalog) -> Int {
        vehicles.filter { catalog.model(id: $0.modelId).map { $0.regular } ?? false }.count
    }

    /// Share of all known-size fleets that has been caught, 0...1.
    public func fleetShare(catalog: FleetCatalog) -> Double {
        let total = catalog.totalFleet
        guard total > 0 else { return 0 }
        return Double(fleetCaught(catalog: catalog)) / Double(total)
    }
}

public enum Streak {
    /// Consecutive calendar days with at least one sighting, ending today or yesterday.
    public static func days(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor), days.contains(y) else { return 0 }
            cursor = y
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
}

public enum Ordinal {
    /// "3rd" in English, "3." in Polish: the suffix is looked up, so a language without
    /// English's st/nd/rd just maps them all to one.
    public static func string(_ n: Int) -> String {
        let tens = (n / 10) % 10, ones = n % 10
        let suffix = tens == 1 ? String(localized: "ordinal.th", defaultValue: "th")
            : ones == 1 ? String(localized: "ordinal.st", defaultValue: "st")
            : ones == 2 ? String(localized: "ordinal.nd", defaultValue: "nd")
            : ones == 3 ? String(localized: "ordinal.rd", defaultValue: "rd")
            : String(localized: "ordinal.th", defaultValue: "th")
        return "\(n)\(suffix)"
    }
}

public enum RevealHint {
    /// The green hint line on the reveal screen. `owned` includes the new catch.
    /// Model names are kept after the word "model" in the sentences, so languages that
    /// decline nouns never have to bend a name like "Solaris Urbino 18".
    public static func text(model: VehicleModel, number: Int, owned: Set<Int>,
                            isNewVehicle: Bool, timesSeen: Int) -> String {
        let name = model.name
        guard isNewVehicle else {
            return String(localized: "Seen it before — that's sighting #\(timesSeen) of \(String(number)). It still counts toward your streak.")
        }
        if model.vintage {
            let left = model.numbers.filter { !owned.contains($0) }.count
            let intro = model.kind == .tram
                ? String(localized: "A vintage tram — it only comes out on tourist lines. Nice timing.")
                : String(localized: "A vintage bus — it only comes out on tourist lines. Nice timing.")
            let more = left == 0 ? String(localized: "That's all of them.") : String(localized: "\(left) more to find.")
            return "\(intro) \(more)"
        }
        if model.onTest {
            return String(localized: "Caught on its trial run — it's only in Warsaw for a few weeks. Nice timing.")
        }
        let modelLeft = model.numbers.filter { !owned.contains($0) }
        if modelLeft.isEmpty { return String(localized: "That's every \(name) in Warsaw. Model complete.") }
        if let batch = model.batch(containing: number), model.batches.count > 1, let year = batch.year {
            let left = batch.numbers.filter { !owned.contains($0) }
            let y = String(year)
            switch left.count {
            case 0: return String(localized: "That completes the \(y) batch of \(name). \(modelLeft.count) left in other batches.")
            case 1: return String(localized: "One more — \(String(left[0])) — and the \(y) batch is done.")
            default: return String(localized: "\(left.count) left in the \(y) batch, \(modelLeft.count) \(name) to find overall.")
            }
        }
        if modelLeft.count == 1 { return String(localized: "One more — \(String(modelLeft[0])) — and every \(name) is yours.") }
        if owned.count == 1 { return String(localized: "Your first \(name). \(modelLeft.count) more of them are out there.") }
        return String(localized: "\(owned.count) of \(model.fleet) \(name) caught — \(modelLeft.count) still to find.")
    }
}
