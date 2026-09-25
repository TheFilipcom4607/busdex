import Foundation

public enum VehicleKind: String, Codable, Sendable, CaseIterable {
    case bus = "BUS"
    case tram = "TRAM"
}

/// Vehicles of one model delivered in the same production year — the design's
/// "2024 BATCH · R-1 WORONICZA · 1970—1987" section.
public struct Batch: Codable, Hashable, Sendable {
    public let year: Int?
    public let depotCode: String
    public let depotName: String
    public let numbers: [Int]

    public init(year: Int?, depotCode: String, depotName: String, numbers: [Int]) {
        self.year = year
        self.depotCode = depotCode
        self.depotName = depotName
        self.numbers = numbers
    }

    public var rangeDisplay: String { NumberSpan.display(numbers) }

    /// "R-1 WORONICZA", or just the depot name when it has no R-code.
    public var depotDisplay: String {
        (depotCode.isEmpty ? depotName : "\(depotCode) \(depotName)").uppercased()
    }
}

public struct VehicleModel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let make: String
    /// ZTM's own "make type" string, e.g. "MAN A23" for the Lion's City G.
    public let code: String?
    public let kind: VehicleKind
    public let operators: [String]
    /// Vehicles of this model in the ZTM database.
    public let fleet: Int
    public let firstYear: Int?
    public let lastYear: Int?
    public let batches: [Batch]
    /// Tourist-line / museum stock: only out on summer weekends or special events.
    public let vintage: Bool
    /// On loan for a trial run: out for a few weeks, then gone.
    public let onTest: Bool
    /// Where a test vehicle runs, e.g. "LINE 106 · ALSO 122, 123 · TRIAL UNTIL 30 SEP 2026".
    public let runs: String?

    public init(id: String, name: String, make: String, code: String? = nil, kind: VehicleKind,
                operators: [String], fleet: Int, firstYear: Int?, lastYear: Int?, batches: [Batch],
                vintage: Bool = false, onTest: Bool = false, runs: String? = nil) {
        self.id = id
        self.name = name
        self.make = make
        self.code = code
        self.kind = kind
        self.operators = operators
        self.fleet = fleet
        self.firstYear = firstYear
        self.lastYear = lastYear
        self.batches = batches
        self.vintage = vintage
        self.onTest = onTest
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, make, code, kind, operators, fleet, firstYear, lastYear, batches, vintage, onTest, runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        make = try c.decode(String.self, forKey: .make)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        kind = try c.decode(VehicleKind.self, forKey: .kind)
        operators = try c.decode([String].self, forKey: .operators)
        fleet = try c.decode(Int.self, forKey: .fleet)
        firstYear = try c.decodeIfPresent(Int.self, forKey: .firstYear)
        lastYear = try c.decodeIfPresent(Int.self, forKey: .lastYear)
        batches = try c.decode([Batch].self, forKey: .batches)
        vintage = try c.decodeIfPresent(Bool.self, forKey: .vintage) ?? false
        onTest = try c.decodeIfPresent(Bool.self, forKey: .onTest) ?? false
        runs = try c.decodeIfPresent(String.self, forKey: .runs)
    }

    public var numbers: [Int] { batches.flatMap(\.numbers).sorted() }

    public var yearsDisplay: String? {
        guard let a = firstYear else { return nil }
        guard let b = lastYear, b != a else { return String(a) }
        return "\(a)—\(b)"
    }

    public var rangeDisplay: String { NumberSpan.display(numbers) }

    /// Regular service stock: what the fleet %, the set badges and the rarity tiers are
    /// about. Vintage and test vehicles are extras on the side.
    public var regular: Bool { !vintage && !onTest }

    /// Vintage and test stock get their own tier whatever their size: they aren't rare,
    /// they're seasonal or passing through.
    public var tier: Tier { vintage ? .vintage : onTest ? .onTest : Tier.of(fleet: fleet) }

    /// Where to find a vintage or test vehicle, e.g. "TOURIST LINES T & 36 · SUMMER WEEKENDS".
    public var whereToFind: String? {
        if vintage {
            return kind == .tram ? "TOURIST LINES T & 36 · SUMMER WEEKENDS" : "TOURIST LINE 100 & EVENTS · SUMMER WEEKENDS"
        }
        return onTest ? runs : nil
    }

    public func batch(containing number: Int) -> Batch? {
        batches.first { $0.numbers.contains(number) }
    }
}

public struct Depot: Codable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let kind: VehicleKind

    public init(code: String, name: String, kind: VehicleKind) {
        self.code = code
        self.name = name
        self.kind = kind
    }
}

public enum NumberSpan {
    /// "1940—1987", "#14" for a single vehicle, "" for none.
    public static func display(_ numbers: [Int]) -> String {
        guard let lo = numbers.min(), let hi = numbers.max() else { return "" }
        return lo == hi ? "#\(lo)" : "\(lo)—\(hi)"
    }
}

public enum Tier: String, Sendable, CaseIterable {
    case legendary = "LEGENDARY"
    case gold = "GOLD"
    case rare = "RARE"
    case common = "COMMON"
    case vintage = "VINTAGE"
    case onTest = "ON TEST"

    /// Thresholds from the design prototype's `tierOf`.
    public static func of(fleet: Int) -> Tier {
        if fleet <= 12 { return .legendary }
        if fleet <= 48 { return .gold }
        if fleet <= 80 { return .rare }
        return .common
    }

    /// Lower sorts rarer.
    public var rank: Int {
        switch self {
        case .legendary: 0
        case .gold: 1
        case .rare: 2
        case .common: 3
        case .vintage: 4
        case .onTest: 5
        }
    }
}

public struct FleetData: Codable, Sendable {
    public let source: String
    public let fetched: String?
    public let models: [VehicleModel]
    public let depots: [Depot]

    public init(source: String, fetched: String?, models: [VehicleModel], depots: [Depot]) {
        self.source = source
        self.fetched = fetched
        self.models = models
        self.depots = depots
    }
}
