import Foundation

/// A storage-agnostic view of one sighting, so the stats can be computed and tested
/// without SwiftData.
public struct SightingRecord: Hashable, Sendable {
    public let number: Int
    public let modelId: String
    public let date: Date

    public init(number: Int, modelId: String, date: Date) {
        self.number = number
        self.modelId = modelId
        self.date = date
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

    /// Share of all known-size fleets that has been caught, 0...1.
    public func fleetShare(catalog: FleetCatalog) -> Double {
        let total = catalog.totalFleet
        guard total > 0 else { return 0 }
        let counted = vehicles.filter { catalog.model(id: $0.modelId) != nil }.count
        return Double(counted) / Double(total)
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
    public static func string(_ n: Int) -> String {
        let tens = (n / 10) % 10, ones = n % 10
        let suffix = tens == 1 ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
        return "\(n)\(suffix)"
    }
}

public enum RevealHint {
    /// The green hint line on the reveal screen. `owned` includes the new catch.
    public static func text(model: VehicleModel, number: Int, owned: Set<Int>,
                            isNewVehicle: Bool, timesSeen: Int) -> String {
        guard isNewVehicle else {
            return "Seen it before — that's sighting #\(timesSeen) of \(number). It still counts toward your streak."
        }
        let modelLeft = model.numbers.filter { !owned.contains($0) }
        if modelLeft.isEmpty { return "That's every \(model.name) in Warsaw. Model complete." }
        if let batch = model.batch(containing: number), model.batches.count > 1, let year = batch.year {
            let left = batch.numbers.filter { !owned.contains($0) }
            switch left.count {
            case 0: return "That completes the \(year) batch of \(model.name). \(modelLeft.count) left in other batches."
            case 1: return "One more — \(left[0]) — and the \(year) batch is done."
            default: return "\(left.count) left in the \(year) batch, \(modelLeft.count) \(model.name) to find overall."
            }
        }
        if modelLeft.count == 1 { return "One more — \(modelLeft[0]) — and every \(model.name) is yours." }
        if owned.count == 1 { return "Your first \(model.name). \(modelLeft.count) more of them are out there." }
        return "\(owned.count) of \(model.fleet) \(model.name) caught — \(modelLeft.count) still to find."
    }
}
