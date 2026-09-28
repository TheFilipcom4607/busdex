import Foundation

public enum VehicleKind: String, Codable, Sendable, CaseIterable {
    case bus = "BUS"
    case tram = "TRAM"

    /// The caps label shown on tags. `rawValue` is stored and parsed, so it never changes.
    public var name: String {
        switch self {
        case .bus: String(localized: "BUS", comment: "Vehicle kind tag")
        case .tram: String(localized: "TRAM", comment: "Vehicle kind tag")
        }
    }
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
    /// When a test vehicle is here, e.g. "ON TRIAL SEP 2026": shown where the build year
    /// would be, which for a demo bus is neither known nor the point.
    public let trial: String?
    /// `runs` and `trial` in Polish. Hand-written in fetch_fleet.py; older fleet files lack them.
    public let runsPl: String?
    public let trialPl: String?
    /// From the city's open data; older fleet files and vehicles it doesn't list have none.
    public let specs: ModelSpecs?
    /// Vehicles not in ZTM's usual paint, by fleet number (JSON keys are strings), from a
    /// hand-checked list in fetch_fleet.py; see `Livery`.
    public let liveries: [String: String]?

    public init(id: String, name: String, make: String, code: String? = nil, kind: VehicleKind,
                operators: [String], fleet: Int, firstYear: Int?, lastYear: Int?, batches: [Batch],
                vintage: Bool = false, onTest: Bool = false, runs: String? = nil, trial: String? = nil,
                runsPl: String? = nil, trialPl: String? = nil, specs: ModelSpecs? = nil, liveries: [String: String]? = nil) {
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
        self.trial = trial
        self.runsPl = runsPl
        self.trialPl = trialPl
        self.specs = specs
        self.liveries = liveries
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, make, code, kind, operators, fleet, firstYear, lastYear, batches, vintage, onTest, runs, trial,
             runsPl, trialPl, specs, liveries
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
        trial = try c.decodeIfPresent(String.self, forKey: .trial)
        runsPl = try c.decodeIfPresent(String.self, forKey: .runsPl)
        trialPl = try c.decodeIfPresent(String.self, forKey: .trialPl)
        // Optional extras: a malformed one is dropped rather than failing the whole file.
        specs = try? c.decodeIfPresent(ModelSpecs.self, forKey: .specs)
        liveries = try? c.decodeIfPresent([String: String].self, forKey: .liveries)
    }

    /// A special paint job, if this vehicle has one.
    public func livery(of number: Int) -> Livery? { liveries?[String(number)].flatMap { Livery(rawValue: $0) } }

    /// `trial` in the app's language.
    public var trialDisplay: String? { AppLanguage.polish ? trialPl ?? trial : trial }

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
            return kind == .tram ? String(localized: "TOURIST LINES T & 36 · SUMMER WEEKENDS")
                : String(localized: "TOURIST LINE 100 & EVENTS · SUMMER WEEKENDS")
        }
        return onTest ? (AppLanguage.polish ? runsPl ?? runs : runs) : nil
    }

    public func batch(containing number: Int) -> Batch? {
        batches.first { $0.numbers.contains(number) }
    }
}

/// What the city's open data says about a model (from the type most of its vehicles are).
public struct ModelSpecs: Codable, Hashable, Sendable {
    /// Millimetres.
    public let length: Int?
    public let drive: Drive?
    public let seats: Int?
    /// Seated and standing.
    public let places: Int?
    public let airCon: Bool?
    public let floor: Floor?

    public init(length: Int? = nil, drive: Drive? = nil, seats: Int? = nil, places: Int? = nil,
                airCon: Bool? = nil, floor: Floor? = nil) {
        self.length = length
        self.drive = drive
        self.seats = seats
        self.places = places
        self.airCon = airCon
        self.floor = floor
    }

    private enum CodingKeys: String, CodingKey { case length, drive, seats, places, airCon, floor }

    /// A drive or floor added in a later version is skipped, not fatal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        length = try c.decodeIfPresent(Int.self, forKey: .length)
        drive = (try? c.decodeIfPresent(String.self, forKey: .drive))?.flatMap { Drive(rawValue: $0) }
        seats = try c.decodeIfPresent(Int.self, forKey: .seats)
        places = try c.decodeIfPresent(Int.self, forKey: .places)
        airCon = try c.decodeIfPresent(Bool.self, forKey: .airCon)
        floor = (try? c.decodeIfPresent(String.self, forKey: .floor))?.flatMap { Floor(rawValue: $0) }
    }

    /// 11947 mm is "11.9", 18000 mm "18": metres, to a tenth.
    public var metres: Double? { length.map { (Double($0) / 100).rounded() / 10 } }

    public enum Drive: String, Codable, Sendable {
        case diesel, electric, hydrogen, cng, lng, hybrid

        public var name: String {
            switch self {
            case .diesel: String(localized: "DIESEL", comment: "Drive")
            case .electric: String(localized: "ELECTRIC", comment: "Drive")
            case .hydrogen: String(localized: "HYDROGEN", comment: "Drive")
            case .cng: String(localized: "CNG", comment: "Drive: compressed natural gas")
            case .lng: String(localized: "LNG", comment: "Drive: liquefied natural gas")
            case .hybrid: String(localized: "HYBRID", comment: "Drive")
            }
        }
    }

    public enum Floor: String, Codable, Sendable {
        case low = "LF", lowEntry = "LE", high = "HF"

        public var name: String {
            switch self {
            case .low: String(localized: "Low floor")
            case .lowEntry: String(localized: "Low entry")
            case .high: String(localized: "High floor")
            }
        }
    }
}

/// A paint job other than ZTM's red and yellow. Only what photos confirm: the city's own paint
/// data is years out of date.
public enum Livery: String, Sendable, CaseIterable {
    /// The Urbino 18 hybrids' grey with a red skirt.
    case greyRed
    /// The blue of the suburban (L) lines: whole models wear it, so it's no badge.
    case suburbanBlue

    public var name: String {
        switch self {
        case .greyRed: String(localized: "GREY & RED")
        case .suburbanBlue: String(localized: "SUBURBAN BLUE")
        }
    }

    /// One vehicle standing out from its fleet, rather than a whole model's colours.
    public var special: Bool { self != .suburbanBlue }
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

/// Which of the app's languages it's running in: the string catalog iOS picked, not the
/// region, so a Polish phone set to English gets the English fleet notes.
public enum AppLanguage {
    public static var polish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("pl") == true }
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

    /// The caps label. `rawValue` is stored (the HUNT filter), so it stays English.
    public var name: String {
        switch self {
        case .legendary: String(localized: "LEGENDARY", comment: "Rarity tier")
        case .gold: String(localized: "GOLD", comment: "Rarity tier")
        case .rare: String(localized: "RARE", comment: "Rarity tier")
        case .common: String(localized: "COMMON", comment: "Rarity tier")
        case .vintage: String(localized: "VINTAGE", comment: "Rarity tier: tourist/museum vehicles")
        case .onTest: String(localized: "ON TEST", comment: "Rarity tier: vehicles on a trial run")
        }
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
    public var sourcePl: String? = nil
    public let fetched: String?
    public let models: [VehicleModel]
    public let depots: [Depot]

    public init(source: String, sourcePl: String? = nil, fetched: String?, models: [VehicleModel], depots: [Depot]) {
        self.source = source
        self.sourcePl = sourcePl
        self.fetched = fetched
        self.models = models
        self.depots = depots
    }
}
