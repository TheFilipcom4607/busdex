import Foundation

/// A stretch of the book the stats screen looks at.
public enum StatsPeriod: Hashable, Sendable {
    case all
    case year(Int)
    case month(year: Int, month: Int)

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        switch self {
        case .all: return true
        case .year(let y): return calendar.component(.year, from: date) == y
        case .month(let y, let m):
            let c = calendar.dateComponents([.year, .month], from: date)
            return c.year == y && c.month == m
        }
    }

    /// All time, then every year and every month with a catch in it, newest first.
    public static func available(_ dates: [Date], calendar: Calendar) -> [StatsPeriod] {
        let ym = Set(dates.map { calendar.dateComponents([.year, .month], from: $0) })
            .compactMap { c in c.year.flatMap { y in c.month.map { (y, $0) } } }
            .sorted { $0 > $1 }
        let years = Array(Set(ym.map(\.0))).sorted(by: >)
        return [.all] + years.map { .year($0) } + ym.map { .month(year: $0.0, month: $0.1) }
    }
}

public struct StreakRun: Hashable, Sendable {
    public let days: Int
    public let start: Date
    public let end: Date
}

extension Streak {
    /// The longest run of consecutive days with a catch.
    public static func best(_ dates: [Date], calendar: Calendar = .current) -> StreakRun? {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        guard var start = days.first else { return nil }
        var best = StreakRun(days: 1, start: start, end: start)
        var run = 1
        for (prev, day) in zip(days, days.dropFirst()) {
            if calendar.date(byAdding: .day, value: 1, to: prev) == day {
                run += 1
            } else {
                run = 1
                start = day
            }
            if run > best.days { best = StreakRun(days: run, start: start, end: day) }
        }
        return best
    }
}

public struct RankedItem: Hashable, Sendable {
    public let name: String
    public let count: Int
}

public struct ModelCount: Hashable, Sendable {
    public let modelId: String
    public let catches: Int
    /// Distinct vehicles of the model in the whole book, whatever the period.
    public let owned: Int
}

public struct VehicleCount: Hashable, Sendable {
    public let number: Int
    public let modelId: String
    public let times: Int
}

/// A catch and the year its vehicle was built.
public struct AgedCatch: Hashable, Sendable {
    public let record: SightingRecord
    public let year: Int
}

public struct StatsRecords: Sendable {
    public let busiestDay: Date?
    public let busiestCount: Int
    /// Other days with as many catches.
    public let busiestTies: [Date]
    public let bestStreak: StreakRun?
    public let first: SightingRecord?
    /// The first sighting of the vehicle from the smallest fleet.
    public let rarest: SightingRecord?
    /// Only once a vehicle has been seen more than once.
    public let mostSeen: VehicleCount?
    public let oldest: AgedCatch?
    public let newest: AgedCatch?
    public let coldest: SightingRecord?
    public let warmest: SightingRecord?
    /// Years since the vehicles you caught were built, and the same for the whole regular fleet.
    public let averageAge: Double?
    public let fleetAverageAge: Double?
}

/// Everything the stats screen and the Stats widget show for one period.
///
/// A coupled tram's second car counts as a vehicle (it's in the book), but not as a catch of
/// its own: it was caught in the same shot, so hours, days, lines and places skip it.
public struct PeriodStats: Sendable {
    public let period: StatsPeriod
    public let catches: Int
    public let vehicles: Int
    public let newVehicles: Int
    public let models: Int
    public let newModels: Int
    public let daysOut: Int
    public let lines: Int
    public let depots: Int
    public let buses: Int
    public let trams: Int
    /// All time: the share of the fleet caught. A year or a month: the share it added.
    public let fleetShare: Double
    /// Catches per day, keyed by the day's start.
    public let perDay: [Date: Int]
    /// Catches by hour of the day, 0–23.
    public let hours: [Int]
    /// Catches by weekday, indexed by `Calendar` weekday − 1 (Sunday first).
    public let weekdays: [Int]
    public let topModels: [ModelCount]
    public let topLines: [RankedItem]
    public let topPlaces: [RankedItem]
    public let topDepots: [RankedItem]
    public let topVehicles: [VehicleCount]
    public let operators: [RankedItem]
    public let records: StatsRecords

    public static let topCount = 5

    public init(_ all: [SightingRecord], period: StatsPeriod, catalog: FleetCatalog,
                now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        let inPeriod = all.filter { period.contains($0.date, calendar: calendar) }
        let events = inPeriod.filter { $0.pairedWith == nil }

        // When each vehicle and model first went into the book, over all time.
        var firstSeen: [String: Date] = [:]
        var modelFirst: [String: Date] = [:]
        var ownedByModel: [String: Set<Int>] = [:]
        for r in all {
            let key = "\(r.modelId)#\(r.number)"
            firstSeen[key] = min(firstSeen[key] ?? r.date, r.date)
            modelFirst[r.modelId] = min(modelFirst[r.modelId] ?? r.date, r.date)
            ownedByModel[r.modelId, default: []].insert(r.number)
        }

        var seen: [String: (number: Int, modelId: String, times: Int, first: SightingRecord)] = [:]
        for r in inPeriod.sorted(by: { $0.date < $1.date }) {
            let key = "\(r.modelId)#\(r.number)"
            if var v = seen[key] {
                v.times += 1
                seen[key] = v
            } else {
                seen[key] = (r.number, r.modelId, 1, r)
            }
        }
        let vehicleList = Array(seen.values)
        let newKeys = seen.keys.filter { firstSeen[$0].map { period.contains($0, calendar: calendar) } ?? false }

        catches = events.count
        vehicles = seen.count
        newVehicles = newKeys.count
        models = Set(inPeriod.map(\.modelId)).count
        newModels = modelFirst.filter { period.contains($0.value, calendar: calendar) }.count
        let days = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        perDay = days.mapValues(\.count)
        daysOut = days.count
        lines = Set(events.compactMap(\.line)).count

        let models = vehicleList.map { (v: $0, model: catalog.model(id: $0.modelId)) }
        buses = models.filter { $0.model?.kind == .bus }.count
        trams = models.filter { $0.model?.kind == .tram }.count
        let batches = models.compactMap { m in m.model?.batch(containing: m.v.number).map { (m.v, $0) } }
        depots = Set(batches.filter { !$0.1.depotName.isEmpty }.map { $0.1.depotCode + $0.1.depotName }).count

        let total = catalog.totalFleet
        if total > 0 {
            let counted = period == .all ? Array(seen.keys) : newKeys
            let regular = counted.filter { key in
                seen[key].flatMap { catalog.model(id: $0.modelId) }?.regular ?? false
            }
            fleetShare = Double(regular.count) / Double(total)
        } else {
            fleetShare = 0
        }

        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        for r in events {
            hours[calendar.component(.hour, from: r.date)] += 1
            weekdays[calendar.component(.weekday, from: r.date) - 1] += 1
        }
        self.hours = hours
        self.weekdays = weekdays

        topModels = Dictionary(grouping: events, by: \.modelId)
            .map { ModelCount(modelId: $0.key, catches: $0.value.count, owned: ownedByModel[$0.key]?.count ?? 0) }
            .sorted { $0.catches != $1.catches ? $0.catches > $1.catches : $0.modelId < $1.modelId }
            .prefix(Self.topCount).map { $0 }
        topLines = Self.rank(events.compactMap(\.line), limit: 6)
        topPlaces = Self.rank(events.compactMap(\.district))
        topDepots = Self.rank(batches.compactMap { $0.1.depotName.isEmpty ? nil : $0.1.depotName })
        operators = Self.rank(batches.compactMap { $0.1.operator }, limit: .max)
        let byTimes = vehicleList.sorted {
            $0.times != $1.times ? $0.times > $1.times : $0.first.date < $1.first.date
        }
        topVehicles = byTimes.prefix(Self.topCount).map { VehicleCount(number: $0.number, modelId: $0.modelId, times: $0.times) }

        // Records
        let busiest = perDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        let rarest = vehicleList.min { a, b in
            let fa = catalog.model(id: a.modelId)?.fleet ?? .max
            let fb = catalog.model(id: b.modelId)?.fleet ?? .max
            return fa != fb ? fa < fb : a.first.date < b.first.date
        }
        let aged = vehicleList.compactMap { v -> AgedCatch? in
            catalog.model(id: v.modelId)?.batch(containing: v.number)?.year.map { AgedCatch(record: v.first, year: $0) }
        }
        let thisYear = calendar.component(.year, from: now)
        var fleetYears = 0, fleetCount = 0
        for m in catalog.models where m.regular {
            for b in m.batches { if let y = b.year { fleetYears += y * b.numbers.count; fleetCount += b.numbers.count } }
        }
        let withTemp = events.filter { $0.temperature != nil }
        records = StatsRecords(
            busiestDay: busiest?.key, busiestCount: busiest?.value ?? 0,
            busiestTies: perDay.filter { $0.value == busiest?.value && $0.key != busiest?.key }.keys.sorted(),
            bestStreak: Streak.best(events.map(\.date), calendar: calendar),
            first: events.min { $0.date < $1.date },
            rarest: rarest?.first,
            mostSeen: byTimes.first.flatMap { $0.times > 1 ? VehicleCount(number: $0.number, modelId: $0.modelId, times: $0.times) : nil },
            oldest: aged.min { $0.year != $1.year ? $0.year < $1.year : $0.record.date < $1.record.date },
            newest: aged.max { $0.year != $1.year ? $0.year < $1.year : $0.record.date > $1.record.date },
            coldest: withTemp.min { $0.temperature! < $1.temperature! },
            warmest: withTemp.max { $0.temperature! < $1.temperature! },
            averageAge: aged.isEmpty ? nil : Double(thisYear) - Double(aged.map(\.year).reduce(0, +)) / Double(aged.count),
            fleetAverageAge: fleetCount == 0 ? nil : Double(thisYear) - Double(fleetYears) / Double(fleetCount))
    }

    /// Most frequent first; ties alphabetically, so the order doesn't jump between launches.
    static func rank(_ names: [String], limit: Int = topCount) -> [RankedItem] {
        Dictionary(grouping: names, by: { $0 })
            .map { RankedItem(name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }

    /// Catches per day over the whole book, for the calendar, which pages through months
    /// whatever the period.
    public static func perDay(_ all: [SightingRecord], calendar: Calendar = .current) -> [Date: Int] {
        Dictionary(grouping: all.filter { $0.pairedWith == nil }) { calendar.startOfDay(for: $0.date) }
            .mapValues(\.count)
    }
}

/// "On this day" for the Memories widget: the catch to look back on for a given day.
public enum Memory {
    public enum Kind: String, Codable, Sendable {
        case yearAgo, monthAgo, weekAgo, first, random
    }

    /// The days whose catches can come back on `day`: a year, a month and a week before it.
    public static func anniversaries(of day: Date, calendar: Calendar = .current) -> [(Kind, Date)] {
        let start = calendar.startOfDay(for: day)
        return [(Kind.yearAgo, DateComponents(year: -1)), (.monthAgo, DateComponents(month: -1)), (.weekAgo, DateComponents(day: -7))]
            .compactMap { kind, delta in calendar.date(byAdding: delta, to: start).map { (kind, $0) } }
    }

    /// Which memory a day shows: the oldest anniversary that had a catch; otherwise the first
    /// catch once a week and a random one on the other days.
    public static func pick(for day: Date, hasCatches: (Date) -> Bool, randomCount: Int,
                            calendar: Calendar = .current) -> (kind: Kind, day: Date?, index: Int)? {
        if let hit = anniversaries(of: day, calendar: calendar).first(where: { hasCatches($0.1) }) {
            return (hit.0, hit.1, 0)
        }
        let n = Int(calendar.startOfDay(for: day).timeIntervalSince1970 / 86_400)
        if n % 7 == 0 || randomCount == 0 { return (.first, nil, 0) }
        return (.random, nil, ((n &* 2_654_435_761) & 0x7fff_ffff) % randomCount)
    }
}
