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

/// One operator's vehicles of one model from the same production year — the design's
/// "2024 BATCH · R-1 WORONICZA · 1970—1987" section.
public struct Batch: Codable, Hashable, Sendable {
    public let year: Int?
    public let depotCode: String
    public let depotName: String
    /// Short name, e.g. "MZA", "KMKM". Fleet files before 2026-10-03 have none.
    public let `operator`: String?
    public let numbers: [Int]

    public init(year: Int?, depotCode: String, depotName: String, operator: String? = nil, numbers: [Int]) {
        self.year = year
        self.depotCode = depotCode
        self.depotName = depotName
        self.operator = `operator`
        self.numbers = numbers
    }

    public var rangeDisplay: String { NumberSpan.display(numbers) }

    /// "R-1 WORONICZA", or just the depot name when it has no R-code.
    public var depotDisplay: String {
        (depotCode.isEmpty ? depotName : "\(depotCode) \(depotName)").uppercased()
    }

    /// The depot, or the owner when there's none (KMKM's preserved buses): "KMKM".
    public var placeDisplay: String {
        depotName.isEmpty ? (self.operator ?? "").uppercased() : depotDisplay
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
    /// Vehicles the city lists under another type with other specs (the 2019–20 Lion's City Gs
    /// are CNG, the 2010 ones diesel); everything else has `specs`.
    public let variants: [SpecVariant]
    /// Vehicles not in ZTM's usual paint, by fleet number (JSON keys are strings), from a
    /// hand-checked list in fetch_fleet.py; see `Livery`.
    public let liveries: [String: String]?
    /// Its trams run as two coupled cars, each with its own fleet number.
    public let coupled: Bool
    /// Cars that always run together, e.g. [[1000, 1001]]. In a model that isn't `coupled`,
    /// only these cars are.
    public let sets: [[Int]]
    /// Its cars with no motor of their own, e.g. the vintage ND #1620: they run hitched behind a
    /// car of a model that `tows`, any one of them, so they're paired across models.
    public let trailers: [Int]
    /// Its cars (other than its own `trailers`) can pull a trailer.
    public let tows: Bool
    /// Ids its numbers had before a model was split, e.g. the 120N Tramicus was part of
    /// `tram-pesa-120n`: catches filed under one of them move here (`FleetCatalog.moved`).
    public let formerly: [String]

    public init(id: String, name: String, make: String, code: String? = nil, kind: VehicleKind,
                operators: [String], fleet: Int, firstYear: Int?, lastYear: Int?, batches: [Batch],
                vintage: Bool = false, onTest: Bool = false, runs: String? = nil, trial: String? = nil,
                runsPl: String? = nil, trialPl: String? = nil, specs: ModelSpecs? = nil, variants: [SpecVariant] = [],
                liveries: [String: String]? = nil, coupled: Bool = false, sets: [[Int]] = [],
                trailers: [Int] = [], tows: Bool = false, formerly: [String] = []) {
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
        self.variants = variants
        self.liveries = liveries
        self.coupled = coupled
        self.sets = sets
        self.trailers = trailers
        self.tows = tows
        self.formerly = formerly
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, make, code, kind, operators, fleet, firstYear, lastYear, batches, vintage, onTest, runs, trial,
             runsPl, trialPl, specs, variants, liveries, coupled, sets, trailers, tows, formerly
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
        variants = (try? c.decodeIfPresent([SpecVariant].self, forKey: .variants)) ?? []
        liveries = try? c.decodeIfPresent([String: String].self, forKey: .liveries)
        coupled = try c.decodeIfPresent(Bool.self, forKey: .coupled) ?? false
        sets = (try? c.decodeIfPresent([[Int]].self, forKey: .sets)) ?? []
        trailers = (try? c.decodeIfPresent([Int].self, forKey: .trailers)) ?? []
        tows = (try? c.decodeIfPresent(Bool.self, forKey: .tows)) ?? false
        formerly = (try? c.decodeIfPresent([String].self, forKey: .formerly)) ?? []
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

    public func has(_ number: Int) -> Bool { batch(containing: number) != nil }

    /// This car runs coupled to another, so a catch can add its partner.
    public func isCoupled(_ number: Int) -> Bool {
        has(number) && (coupled || sets.contains { $0.contains(number) })
    }

    /// A car with no motor, pulled by a car of a model that `tows`.
    public func isTrailer(_ number: Int) -> Bool { has(number) && trailers.contains(number) }

    /// A car that can pull a trailer.
    public func pullsTrailers(_ number: Int) -> Bool { tows && has(number) && !trailers.contains(number) }

    /// A catch of this car can add a second car: a coupled tram's other car, a trailer's
    /// motor car, or a motor car's trailer.
    public func takesSecondCar(_ number: Int) -> Bool {
        isCoupled(number) || isTrailer(number) || pullsTrailers(number)
    }

    /// The car it always runs with, if it's in a fixed set.
    public func fixedPartner(of number: Int) -> Int? {
        sets.first { $0.contains(number) }?.first { $0 != number }
    }

    /// This vehicle's own specs.
    public func specs(of number: Int) -> ModelSpecs? {
        variants.first { $0.numbers.contains(number) }?.specs ?? specs
    }

    /// The specs across the whole model, for its page.
    public var spread: SpecsSpread? {
        guard let specs else { return nil }
        let odd = variants.reduce(0) { $0 + $1.numbers.count }
        return SpecsSpread([(specs, max(fleet - odd, 0))] + variants.map { ($0.specs, $0.numbers.count) })
    }

    /// The one drive all of a batch shares, when the model has more than one (else nil).
    public func drive(of batch: Batch) -> ModelSpecs.Drive? {
        guard !variants.isEmpty, (spread?.drives.count ?? 0) > 1 else { return nil }
        let drives = Set(batch.numbers.map { specs(of: $0)?.drive })
        return drives.count == 1 ? drives.first ?? nil : nil
    }
}

public struct SpecVariant: Codable, Hashable, Sendable {
    public let specs: ModelSpecs
    public let numbers: [Int]

    public init(specs: ModelSpecs, numbers: [Int]) {
        self.specs = specs
        self.numbers = numbers
    }
}

/// A model's specs over all its vehicles: one value where they agree, the range where they don't.
public struct SpecsSpread: Equatable, Sendable {
    public let metres: ClosedRange<Double>?
    /// Most vehicles first.
    public let drives: [ModelSpecs.Drive]
    public let seats: ClosedRange<Int>?
    public let places: ClosedRange<Int>?
    public let airCon: AirCon?
    /// The main type's: a low-floor model with one odd tram is still low floor.
    public let floor: ModelSpecs.Floor?

    public enum AirCon: Sendable { case all, none, some }

    /// The model's main specs first, then the variants, each with how many vehicles have it.
    init(_ groups: [(specs: ModelSpecs, count: Int)]) {
        func span<T: Comparable>(_ values: [T?]) -> ClosedRange<T>? {
            let known = values.compactMap { $0 }
            guard let lo = known.min(), let hi = known.max() else { return nil }
            return lo...hi
        }
        let all = groups.map(\.specs)
        metres = span(all.map(\.metres))
        seats = span(all.map(\.seats))
        places = span(all.map(\.places))
        var byDrive: [ModelSpecs.Drive: Int] = [:]
        for g in groups { if let d = g.specs.drive { byDrive[d, default: 0] += g.count } }
        drives = byDrive.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }.map(\.key)
        let cooled = Set(all.compactMap(\.airCon))
        airCon = cooled.count > 1 ? .some : cooled.first.map { $0 ? .all : .none }
        floor = groups.first?.specs.floor
    }
}

/// What the city's open data says about a model (from the type most of its vehicles are), or a
/// `SpecVariant` of it.
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

    public enum Drive: String, Codable, Sendable, CaseIterable {
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

    public enum Floor: String, Codable, Sendable, CaseIterable {
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
        [.legendary, .gold, .rare].first { fleet <= $0.maxFleet! } ?? .common
    }

    /// The most vehicles a model can have and still be this tier. Nil for COMMON, which has
    /// no ceiling, and for the tiers that don't go by size.
    public var maxFleet: Int? {
        switch self {
        case .legendary: 12
        case .gold: 48
        case .rare: 80
        case .common, .vintage, .onTest: nil
        }
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
