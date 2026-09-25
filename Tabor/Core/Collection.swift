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

    public init(number: Int, modelId: String, date: Date, line: String? = nil, district: String? = nil) {
        self.number = number
        self.modelId = modelId
        self.date = date
        self.line = line
        self.district = district
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

    /// Caught vehicles that count toward the fleet total (vintage and unknown models don't).
    public func fleetCaught(catalog: FleetCatalog) -> Int {
        vehicles.filter { catalog.model(id: $0.modelId).map { !$0.vintage } ?? false }.count
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

// MARK: - Achievements

/// A collection goal with its progress, e.g. "Line hopper · 23/50".
public struct Achievement: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case batch, legendary, districts, tramDay, lines, depot
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let progress: Int
    public let goal: Int

    public var earned: Bool { goal > 0 && progress >= goal }
    public var fraction: Double { goal > 0 ? min(Double(progress) / Double(goal), 1) : 0 }
}

public enum Achievements {
    /// Warsaw's 18 districts (dzielnice).
    public static let districts = [
        "Bemowo", "Białołęka", "Bielany", "Mokotów", "Ochota", "Praga-Południe", "Praga-Północ",
        "Rembertów", "Śródmieście", "Targówek", "Ursus", "Ursynów", "Wawer", "Wesoła", "Wilanów",
        "Włochy", "Wola", "Żoliborz",
    ]
    public static let tramsInADay = 10
    public static let linesGoal = 50

    /// Every badge, earned or not: the fixed goals first, then one per depot.
    public static func evaluate(_ sightings: [SightingRecord], catalog: FleetCatalog,
                                calendar: Calendar = .current) -> [Achievement] {
        let owned = Dictionary(grouping: sightings, by: \.modelId).mapValues { Set($0.map(\.number)) }
        return [fullBatch(owned, catalog), legendary(owned, catalog), everyDistrict(sightings),
                tramDay(sightings, catalog, calendar), lines(sightings)]
            + depots(owned, catalog)
    }

    /// Closest delivery batch to completion (at least two vehicles, so it's a real batch).
    static func fullBatch(_ owned: [String: Set<Int>], _ catalog: FleetCatalog) -> Achievement {
        var best: (have: Int, size: Int, label: String)?
        for m in catalog.models {
            let mine = owned[m.id] ?? []
            for b in m.batches where b.numbers.count >= 2 {
                let have = b.numbers.filter(mine.contains).count
                guard have > 0 else { continue }
                let better = best.map { Double(have) / Double(b.numbers.count) > Double($0.have) / Double($0.size) } ?? true
                if better { best = (have, b.numbers.count, [b.year.map(String.init), m.name].compactMap { $0 }.joined(separator: " ")) }
            }
        }
        let detail = best.map { "Every vehicle of one delivery batch. Closest: \($0.label)" }
            ?? "Every vehicle of one delivery batch"
        return Achievement(id: "full-batch", kind: .batch, title: "Full batch", detail: detail,
                           progress: best?.have ?? 0, goal: best?.size ?? 1)
    }

    static func legendary(_ owned: [String: Set<Int>], _ catalog: FleetCatalog) -> Achievement {
        let models = catalog.models.filter { $0.tier == .legendary }
        let have = models.filter { !(owned[$0.id] ?? []).isEmpty }.count
        return Achievement(id: "legendary-all", kind: .legendary, title: "All \(models.count) legendary",
                           detail: "One of every LEGENDARY model", progress: have, goal: models.count)
    }

    static func everyDistrict(_ sightings: [SightingRecord]) -> Achievement {
        let found = Set(sightings.compactMap { $0.district.flatMap(district(of:)) })
        return Achievement(id: "every-district", kind: .districts, title: "Every district",
                           detail: "A catch in all \(districts.count) districts of Warsaw",
                           progress: found.count, goal: districts.count)
    }

    static func tramDay(_ sightings: [SightingRecord], _ catalog: FleetCatalog, _ calendar: Calendar) -> Achievement {
        let trams = sightings.filter { catalog.model(id: $0.modelId)?.kind == .tram }
        let perDay = Dictionary(grouping: trams) { calendar.startOfDay(for: $0.date) }
            .mapValues { Set($0.map { "\($0.modelId)#\($0.number)" }).count }
        return Achievement(id: "trams-day", kind: .tramDay, title: "Tram day",
                           detail: "\(tramsInADay) different trams in one day",
                           progress: perDay.values.max() ?? 0, goal: tramsInADay)
    }

    static func lines(_ sightings: [SightingRecord]) -> Achievement {
        let lines = Set(sightings.compactMap { $0.line?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty })
        return Achievement(id: "lines-50", kind: .lines, title: "Line hopper",
                           detail: "Caught on \(linesGoal) different lines", progress: lines.count, goal: linesGoal)
    }

    /// One badge per depot: a vehicle of every model based there, caught from that depot's batches.
    static func depots(_ owned: [String: Set<Int>], _ catalog: FleetCatalog) -> [Achievement] {
        catalog.depots.compactMap { d in
            let models = catalog.models.filter { m in
                !m.vintage && m.kind == d.kind && m.batches.contains { $0.depotCode == d.code && $0.depotName == d.name }
            }
            guard !models.isEmpty else { return nil }
            let have = models.filter { m in
                let mine = owned[m.id] ?? []
                return m.batches.contains { $0.depotCode == d.code && $0.depotName == d.name && $0.numbers.contains(where: mine.contains) }
            }.count
            let name = d.code.isEmpty ? d.name : "\(d.code) \(d.name)"
            return Achievement(id: "depot-\(d.kind.rawValue)-\(d.code)-\(d.name)", kind: .depot, title: name,
                               detail: "Every \(d.kind.rawValue.lowercased()) model at the depot",
                               progress: have, goal: models.count)
        }
    }

    /// Maps a geocoder's area name to its district: "Stary Mokotów" → "Mokotów",
    /// "Praga Południe" → "Praga-Południe". Neighbourhood names (e.g. "Muranów") don't map.
    public static func district(of area: String) -> String? {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "-", with: " ").lowercased()
                .split(separator: " ").joined(separator: " ")
        }
        let words = " \(norm(area)) "
        return districts.first { words.contains(" \(norm($0)) ") }
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
        if model.vintage {
            let left = model.numbers.filter { !owned.contains($0) }.count
            let more = left == 0 ? "That's all of them." : "\(left) more to find."
            return "A vintage \(model.kind.rawValue.lowercased()) — it only comes out on tourist lines. Nice timing. \(more)"
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
