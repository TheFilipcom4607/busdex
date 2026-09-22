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

    public init(id: String, name: String, make: String, code: String? = nil, kind: VehicleKind,
                operators: [String], fleet: Int, firstYear: Int?, lastYear: Int?, batches: [Batch]) {
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
    }

    public var numbers: [Int] { batches.flatMap(\.numbers).sorted() }

    public var yearsDisplay: String? {
        guard let a = firstYear else { return nil }
        guard let b = lastYear, b != a else { return String(a) }
        return "\(a)—\(b)"
    }

    public var rangeDisplay: String { NumberSpan.display(numbers) }

    public var tier: Tier { Tier.of(fleet: fleet) }

    public func batch(containing number: Int) -> Batch? {
        batches.first { $0.numbers.contains(number) }
    }
}

public struct Depot: Codable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let kind: VehicleKind
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
        }
    }
}

public struct FleetData: Codable, Sendable {
    public let source: String
    public let fetched: String?
    public let models: [VehicleModel]
    public let depots: [Depot]
}
