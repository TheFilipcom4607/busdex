import Foundation

/// One vehicle from Warsaw's live GPS feed (api.um.warszawa.pl `busestrams_get`).
public struct LiveVehicle: Hashable, Sendable {
    public let number: Int
    public let kind: VehicleKind
    /// As ZTM writes it: "523", "N83", "L-8", "28".
    public let line: String
    public let brigade: String
    public let latitude: Double
    public let longitude: Double
    /// When the vehicle last reported its position.
    public let time: Date

    public init(number: Int, kind: VehicleKind, line: String, brigade: String = "",
                latitude: Double, longitude: Double, time: Date) {
        self.number = number
        self.kind = kind
        self.line = line
        self.brigade = brigade
        self.latitude = latitude
        self.longitude = longitude
        self.time = time
    }
}

/// A live vehicle and how far it is from you, in metres.
public struct NearbyVehicle: Hashable, Sendable {
    public let vehicle: LiveVehicle
    public let distance: Double

    public init(vehicle: LiveVehicle, distance: Double) {
        self.vehicle = vehicle
        self.distance = distance
    }
}

public enum LiveFeed {
    /// Rows older than this are parked or switched-off vehicles; the feed keeps some for years.
    public static let maxAge: TimeInterval = 180

    public enum Failure: Error, Equatable {
        /// The old API answers 200 with `"result": "<message>"` for a bad key, overload, etc.;
        /// the new one sends `"message"`.
        case message(String)
        case malformed
    }

    /// Parses one reply: the old `busestrams_get` shape (`{"result": [...]}`, which the proxy
    /// also sends) or the new dane.um.warszawa.pl one (the bare list). Non-numeric fleet
    /// numbers ("d. 35154") and stale rows are dropped.
    public static func parse(_ data: Data, kind: VehicleKind, now: Date = Date()) throws -> [LiveVehicle] {
        let json = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let list = json as? [[String: Any]] {
            rows = list
        } else if let root = json as? [String: Any] {
            if let message = (root["result"] ?? root["message"]) as? String { throw Failure.message(message) }
            guard let list = root["result"] as? [[String: Any]] else { throw Failure.malformed }
            rows = list
        } else {
            throw Failure.malformed
        }
        return rows.compactMap { row in
            guard let raw = row["VehicleNumber"] as? String, let number = Int(raw), number > 0,
                  let lat = double(row["Lat"]), let lon = double(row["Lon"]),
                  let stamp = row["Time"] as? String, let time = warsawTime(stamp),
                  now.timeIntervalSince(time) <= maxAge
            else { return nil }
            let line = (row["Lines"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return LiveVehicle(number: number, kind: kind, line: line, brigade: row["Brigade"] as? String ?? "",
                               latitude: lat, longitude: lon, time: time)
        }
    }

    private static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// "2026-09-25 19:23:28", in Warsaw's wall-clock time.
    static func warsawTime(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                             hour: parts[3], minute: parts[4], second: parts[5]))
    }
}

/// Every bus and tram on the road at one moment.
public struct LiveSnapshot: Sendable {
    public let vehicles: [LiveVehicle]
    public let fetched: Date
    private let byKey: [String: LiveVehicle]

    public init(vehicles: [LiveVehicle], fetched: Date) {
        self.vehicles = vehicles
        self.fetched = fetched
        byKey = Dictionary(vehicles.map { ("\($0.kind.rawValue)#\($0.number)", $0) }) { a, b in a.time > b.time ? a : b }
    }

    /// Nearest first.
    public func nearby(lat: Double, lon: Double, within metres: Double) -> [NearbyVehicle] {
        vehicles.compactMap { v in
            let d = Geo.km((lat, lon), (v.latitude, v.longitude)) * 1000
            return d <= metres ? NearbyVehicle(vehicle: v, distance: d) : nil
        }.sorted { $0.distance < $1.distance }
    }

    public func vehicle(number: Int, kind: VehicleKind) -> LiveVehicle? {
        byKey["\(kind.rawValue)#\(number)"]
    }
}

/// What the live feed changes about reading a fleet number: what's physically around you
/// is far more likely to be what you just pointed the camera at.
public enum LiveHints {
    /// A read that's on the road within this distance gets a boost.
    public static let boostRadius = 300.0
    public static let boost = 1.5
    /// A one-digit-off read is only rescued by a vehicle this close.
    public static let rescueRadius = 150.0
    /// Catch time vs. the vehicle's last GPS report, for filling in the line.
    public static let lineWindow: TimeInterval = 180

    public struct Adjustment: Sendable, Equatable {
        public var boosted: [Int] = []
        public var rescued: [Rescue] = []
        /// Coupled cars kept as read because their set's lead car is right there.
        public var partners: [Partner] = []
    }

    public struct Partner: Sendable, Equatable, Codable {
        /// The car that was read.
        public let number: Int
        /// The set's car the feed reports.
        public let lead: Int
    }

    public struct Rescue: Sendable, Equatable, Codable {
        public let from: Int
        public let to: Int
    }

    /// Boosts candidates that are running nearby, and adds the nearby vehicle a read is
    /// one digit off from (OCR turning 4235 into 1235, a number no tram has). A coupled tram counts as running when
    /// its set's lead car is: the feed only reports one car of a set, and the other car's
    /// number is one digit off it, so it would otherwise be "rescued" into the wrong car.
    public static func adjust(_ candidates: [(number: Int, score: Double)], nearby: [NearbyVehicle],
                              catalog: FleetCatalog) -> (candidates: [(number: Int, score: Double)], adjustment: Adjustment) {
        guard !nearby.isEmpty else { return (candidates, Adjustment()) }
        let close = Set(nearby.filter { $0.distance <= boostRadius }.map(\.vehicle.number))
        let rescuers = nearby.filter { $0.distance <= rescueRadius }
        var out: [(number: Int, score: Double)] = []
        var adj = Adjustment()
        for c in candidates {
            if close.contains(c.number) {
                out.append((c.number, c.score + boost))
                if !adj.boosted.contains(c.number) { adj.boosted.append(c.number) }
                continue
            }
            if let set = CoupledSet.partner(of: c.number, catalog: catalog, nearby: nearby) {
                out.append((c.number, c.score + boost))
                if !adj.partners.contains(where: { $0.number == c.number }) {
                    adj.partners.append(Partner(number: c.number, lead: set.lead.number))
                }
                continue
            }
            out.append(c)
            let fixes = rescuers.filter { oneDigitOff(c.number, $0.vehicle.number) }
            // Two nearby vehicles both one digit away: no way to tell which, so don't guess.
            if Set(fixes.map(\.vehicle.number)).count == 1, let to = fixes.first?.vehicle {
                // A read that's a real number of the same kind is trusted: neighbouring numbers
                // run together (4219 and 4229 on the 14 and 16), and the one read is often just
                // missing from the feed, waiting at a terminus. Its neighbour is only offered.
                if catalog.isKnown(number: c.number, kind: to.kind) {
                    out.append((to.number, c.score - 0.5))
                } else {
                    out.append((to.number, c.score + 1))
                    adj.rescued.append(Rescue(from: c.number, to: to.number))
                }
            }
        }
        return (out, adj)
    }

    /// Same number of digits, exactly one different.
    public static func oneDigitOff(_ a: Int, _ b: Int) -> Bool {
        let x = Array(String(a)), y = Array(String(b))
        guard x.count == y.count else { return false }
        return zip(x, y).filter { $0 != $1 }.count == 1
    }

    /// When only one kind with this number is nearby, that settles bus-vs-tram — both for an
    /// ambiguous match and for a mode that preferred the other kind. A coupled tram's set
    /// running right there counts too: vintage 1000 is also an Urbino 10's number.
    public static func resolve(_ match: ModelMatch, number: Int, nearby: [NearbyVehicle],
                               catalog: FleetCatalog) -> ModelMatch {
        let kinds = Set(nearby.filter { $0.vehicle.number == number && $0.distance <= boostRadius }.map(\.vehicle.kind))
        if kinds.isEmpty, let set = CoupledSet.partner(of: number, catalog: catalog, nearby: nearby) {
            return .certain(set.model)
        }
        guard kinds.count == 1, let kind = kinds.first else { return match }
        let hits = match.candidates.filter { $0.kind == kind }
        if hits.count == 1 { return .certain(hits[0]) }
        if hits.isEmpty, case .certain(let m) = catalog.match(number: number, kind: kind) { return .certain(m) }
        return match
    }

    /// The line the vehicle was running on at `date`, if the feed saw it recently enough.
    /// A coupled car the feed doesn't report takes its set's line: the lead car right there,
    /// else its fixed partner, else the one neighbouring number that's running. A trailer
    /// takes its motor car's (which needs `catalog`, to know which cars pull trailers).
    public static func line(for number: Int, kind: VehicleKind, snapshot: LiveSnapshot?, at date: Date,
                            model: VehicleModel? = nil, nearby: [NearbyVehicle] = [],
                            catalog: FleetCatalog? = nil) -> String? {
        func reported(_ n: Int) -> String? {
            guard let v = snapshot?.vehicle(number: n, kind: kind), !v.line.isEmpty,
                  abs(date.timeIntervalSince(v.time)) <= lineWindow
            else { return nil }
            return v.line
        }
        if let line = reported(number) { return line }
        guard let model, model.kind == kind, model.isCoupled(number) || model.isTrailer(number) else { return nil }
        if let lead = CoupledSet.partner(of: number, model: model, nearby: nearby, catalog: catalog),
           let line = reported(lead.number) {
            return line
        }
        if let fixed = model.fixedPartner(of: number) { return reported(fixed) }
        let neighbours = [number - 1, number + 1].filter(model.isCoupled).compactMap(reported)
        return neighbours.count == 1 ? neighbours[0] : nil
    }
}

/// Trams that run as two coupled cars, each with its own number. The live feed has one row
/// per set, under one car's number (usually the even one); the other car never shows up.
/// A vintage trailer is the same: the feed has its motor car.
public enum CoupledSet {
    /// The feed's lead car for `number`'s set: a same-model coupled tram within the rescue
    /// radius, and the only one, unless it's the fixed partner. Pairing isn't strict parity
    /// (1381 and 1387 lead sets) and a ±1 neighbour can be another model, so it goes by model.
    /// For a trailer, the only car right there that pulls trailers (with `catalog`).
    public static func partner(of number: Int, model: VehicleModel, nearby: [NearbyVehicle],
                               catalog: FleetCatalog? = nil) -> LiveVehicle? {
        guard model.kind == .tram else { return nil }
        let close = nearby.filter {
            $0.distance <= LiveHints.rescueRadius && $0.vehicle.kind == .tram && $0.vehicle.number != number
        }.map(\.vehicle)
        if model.isTrailer(number), let catalog {
            let motors = close.filter { catalog.secondCarModel($0.number, of: number, model: model) != nil }
            return motors.count == 1 ? motors[0] : nil
        }
        guard model.isCoupled(number) else { return nil }
        let leads = close.filter { model.isCoupled($0.number) }
        if let fixed = model.fixedPartner(of: number), let lead = leads.first(where: { $0.number == fixed }) { return lead }
        return leads.count == 1 ? leads[0] : nil
    }

    /// The same across every tram model with this number.
    public static func partner(of number: Int, catalog: FleetCatalog,
                               nearby: [NearbyVehicle]) -> (model: VehicleModel, lead: LiveVehicle)? {
        guard !nearby.isEmpty else { return nil }
        let hits = catalog.match(number: number, kind: .tram).candidates.compactMap { m in
            partner(of: number, model: m, nearby: nearby, catalog: catalog).map { (model: m, lead: $0) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    public struct Suggestion: Sendable, Equatable {
        public enum Source: String, Sendable {
            case fixed, photo, feed, trailer
            case neighbour = "±1"
        }
        public let number: Int
        public let source: Source
    }

    /// Up to three numbers for the car coupled to `number`, likeliest first: its fixed partner,
    /// another car it can run with read in the photo, the feed's lead car, a motor car's
    /// trailers, then n−1 and n+1. Only cars it can really run with, never the caught number.
    public static func suggestions(for number: Int, model: VehicleModel, photoNumbers: [Int],
                                   nearby: [NearbyVehicle], catalog: FleetCatalog) -> [Suggestion] {
        guard model.takesSecondCar(number) else { return [] }
        var out: [Suggestion] = []
        func add(_ n: Int?, _ source: Suggestion.Source) {
            guard let n, catalog.secondCarModel(n, of: number, model: model) != nil,
                  !out.contains(where: { $0.number == n }) else { return }
            out.append(Suggestion(number: n, source: source))
        }
        add(model.fixedPartner(of: number), .fixed)
        photoNumbers.forEach { add($0, .photo) }
        add(partner(of: number, model: model, nearby: nearby, catalog: catalog)?.number, .feed)
        if model.pullsTrailers(number) { catalog.trailers.forEach { add($0, .trailer) } }
        add(number - 1, .neighbour)
        add(number + 1, .neighbour)
        return Array(out.prefix(3))
    }
}

/// A live vehicle for the HUNT map: one you haven't caught yet, or, in the ALL view, one
/// already in your book.
public struct WantedPin: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case newModel, newVehicle, caught }

    public let vehicle: LiveVehicle
    public let model: VehicleModel
    public let kind: Kind
    public let distance: Double

    public var id: String { "\(vehicle.kind.rawValue)#\(vehicle.number)" }
}

public enum Wanted {
    public static let radius = 3_000.0
    public static let limit = 5_000

    /// Uncaught vehicles within `metres` of a point (the map's centre): models missing from
    /// your book first, rarest first, then nearest to `user` (or to the point, without a fix).
    /// Numbers the ZTM database doesn't know are left out. `includeCaught` keeps vehicles
    /// already in your book, as `.caught`, ranked like any other model you have.
    public static func pins(snapshot: LiveSnapshot, catalog: FleetCatalog, caught: CollectionStats,
                            lat: Double, lon: Double, within metres: Double = radius,
                            from user: (lat: Double, lon: Double)? = nil,
                            includeCaught: Bool = false,
                            limit: Int = limit) -> [WantedPin] {
        let pins: [WantedPin] = snapshot.nearby(lat: lat, lon: lon, within: metres).compactMap { n in
            guard let model = catalog.match(number: n.vehicle.number, kind: n.vehicle.kind).suggested
            else { return nil }
            let kind: WantedPin.Kind
            if caught.vehicle(number: n.vehicle.number, modelId: model.id) != nil {
                guard includeCaught else { return nil }
                kind = .caught
            } else {
                kind = caught.ownedCount(modelId: model.id) == 0 ? .newModel : .newVehicle
            }
            let distance = user.map { Geo.km(($0.lat, $0.lon), (n.vehicle.latitude, n.vehicle.longitude)) * 1000 } ?? n.distance
            return WantedPin(vehicle: n.vehicle, model: model, kind: kind, distance: distance)
        }
        return Array(pins.sorted { a, b in
            (a.kind == .newModel ? 0 : 1, huntRank(a.model.tier), a.distance)
                < (b.kind == .newModel ? 0 : 1, huntRank(b.model.tier), b.distance)
        }.prefix(limit))
    }

    /// Everything out on the feed, however far from you: what a filtered HUNT looks through.
    /// The feed is only Warsaw's, so there's no radius to keep to; with one (60 km around you),
    /// a tester in Bydgoszcz saw 0 next to every filter and an empty map (#38).
    public static func anywhere(snapshot: LiveSnapshot, catalog: FleetCatalog, caught: CollectionStats,
                                lat: Double, lon: Double, from user: (lat: Double, lon: Double)? = nil,
                                includeCaught: Bool = false) -> [WantedPin] {
        pins(snapshot: snapshot, catalog: catalog, caught: caught, lat: lat, lon: lon, within: .infinity,
             from: user, includeCaught: includeCaught)
    }

    /// Everything on one line, picked from HUNT's search: whether or not you have it, nearest
    /// first, so the map shows the line the search counted (#37). Through the header filter, a
    /// line you'd caught all of said "4 out now" and then showed nothing.
    public static func onLine(_ line: String, snapshot: LiveSnapshot, catalog: FleetCatalog, caught: CollectionStats,
                              lat: Double, lon: Double, from user: (lat: Double, lon: Double)? = nil) -> [WantedPin] {
        let key = HuntSearch.lineKey(line)
        let on = LiveSnapshot(vehicles: snapshot.vehicles.filter { HuntSearch.lineKey($0.line) == key },
                              fetched: snapshot.fetched)
        return anywhere(snapshot: on, catalog: catalog, caught: caught, lat: lat, lon: lon,
                        from: user, includeCaught: true).sorted { $0.distance < $1.distance }
    }

    /// Vintage and test stock sort last in the book, but one that's actually out running
    /// is as rare a sight as anything: rank it with the legendaries.
    static func huntRank(_ tier: Tier) -> Int {
        tier == .vintage || tier == .onTest ? Tier.legendary.rank : tier.rank
    }
}

/// What you're after on the HUNT map, like a wanted list: rarities and models, any one of
/// which counts, optionally narrowed to buses or trams. Empty means everything.
public struct HuntTargets: Equatable, Sendable, RawRepresentable {
    public var tiers: Set<Tier>
    /// Model ids.
    public var models: Set<String>
    /// Only buses or only trams; nil for both. Narrows the picks rather than adding to them.
    public var kind: VehicleKind?
    /// One line as the feed writes it ("523", "N83"), from HUNT's search. Narrows, like the kind.
    public var line: String?
    /// Specs from the city's data (#31). Within one, any counts (12 M or 18 M); each one picked
    /// narrows the rest, like the kind does.
    public var lengths: Set<LengthBand>
    public var drives: Set<ModelSpecs.Drive>
    public var floors: Set<ModelSpecs.Floor>

    public init(tiers: Set<Tier> = [], models: Set<String> = [], kind: VehicleKind? = nil, line: String? = nil,
                lengths: Set<LengthBand> = [], drives: Set<ModelSpecs.Drive> = [], floors: Set<ModelSpecs.Floor> = []) {
        self.tiers = tiers
        self.models = models
        self.kind = kind
        self.line = line
        self.lengths = lengths
        self.drives = drives
        self.floors = floors
    }

    public var isEmpty: Bool { !isCityWide && kind == nil }
    /// Rarities or models picked: these add to each other.
    public var hasPicks: Bool { !tiers.isEmpty || !models.isEmpty }
    public var hasSpecs: Bool { !lengths.isEmpty || !drives.isEmpty || !floors.isEmpty }
    /// You're after something specific, so HUNT looks across the whole city. Buses or trams
    /// alone keep the usual view around you.
    public var isCityWide: Bool { hasPicks || hasSpecs || line != nil }
    public var count: Int {
        tiers.count + models.count + (kind == nil ? 0 : 1) + (line == nil ? 0 : 1)
            + lengths.count + drives.count + floors.count
    }

    /// Whether a model can match at all, whatever vehicle and line: for counting picks.
    public func matches(_ model: VehicleModel) -> Bool {
        (kind == nil || model.kind == kind)
            && (!hasPicks || tiers.contains(model.tier) || models.contains(model.id))
    }

    /// A vehicle out now: its model, its own specs (a model's odd vehicles can differ, like the
    /// 2019 CNG Lion's City Gs) and its line.
    public func matches(_ model: VehicleModel, number: Int, line: String) -> Bool {
        guard matches(model) else { return false }
        if let want = self.line, HuntSearch.lineKey(line) != HuntSearch.lineKey(want) { return false }
        guard hasSpecs else { return true }
        let specs = model.specs(of: number)
        if !lengths.isEmpty, !(specs?.length.flatMap(LengthBand.of).map(lengths.contains) ?? false) { return false }
        // Trams have no drive in the city's data: a drive picked means buses.
        if !drives.isEmpty, !(specs?.drive.map(drives.contains) ?? false) { return false }
        if !floors.isEmpty, !(specs?.floor.map(floors.contains) ?? false) { return false }
        return true
    }

    public func matches(_ pin: WantedPin) -> Bool {
        matches(pin.model, number: pin.vehicle.number, line: pin.vehicle.line)
    }

    /// With a model added from its page in the book (#45). Picks add up, but whatever narrows
    /// them could hide it: the line goes, and so does a type or spec none of its vehicles have.
    public func adding(_ model: VehicleModel) -> HuntTargets {
        var t = self
        t.models.insert(model.id)
        t.line = nil
        if let kind, kind != model.kind { t.kind = nil }
        let specs = model.numbers.map { model.specs(of: $0) }
        if !lengths.isEmpty, !specs.contains(where: { $0?.length.flatMap(LengthBand.of).map(lengths.contains) ?? false }) { t.lengths = [] }
        if !drives.isEmpty, !specs.contains(where: { $0?.drive.map(drives.contains) ?? false }) { t.drives = [] }
        if !floors.isEmpty, !specs.contains(where: { $0?.floor.map(floors.contains) ?? false }) { t.floors = [] }
        return t
    }

    /// Lengths in bands that sort buses and trams alike: minibuses and the oldest trams, the
    /// standard 12 m bus, articulated buses and short trams, long trams, the longest trams.
    public enum LengthBand: String, CaseIterable, Sendable, Comparable {
        case under10 = "0-10", to13 = "10-13", to20 = "13-20", to30 = "20-30", over30 = "30-"

        /// Millimetres.
        public static func of(_ length: Int) -> LengthBand {
            switch length {
            case ..<10_000: .under10
            case ..<13_000: .to13
            case ..<20_000: .to20
            case ..<30_000: .to30
            default: .over30
            }
        }

        public var name: String {
            switch self {
            case .under10: String(localized: "UNDER 10 M")
            case .to13: String(localized: "10–13 M")
            case .to20: String(localized: "13–20 M")
            case .to30: String(localized: "20–30 M")
            case .over30: String(localized: "30 M+")
            }
        }

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// "kind:TRAM,tier:GOLD,model:bus-mercus-syn2z,line:523,drive:cng", so it can live in
    /// UserDefaults. Older versions skip the tokens they don't know.
    public var rawValue: String {
        ((kind.map { ["kind:\($0.rawValue)"] } ?? []) + tiers.map { "tier:\($0.rawValue)" }.sorted()
            + models.map { "model:\($0)" }.sorted() + (line.map { ["line:\($0)"] } ?? [])
            + lengths.sorted().map { "length:\($0.rawValue)" } + drives.map { "drive:\($0.rawValue)" }.sorted()
            + floors.map { "floor:\($0.rawValue)" }.sorted())
            .joined(separator: ",")
    }

    /// Unknown tokens (a tier renamed in a later version) are skipped, never fatal.
    public init(rawValue: String) {
        var t = HuntTargets()
        for token in rawValue.split(separator: ",") {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let key = token[..<colon], value = String(token[token.index(after: colon)...])
            switch key {
            case "tier": if let tier = Tier(rawValue: value) { t.tiers.insert(tier) }
            case "model": if !value.isEmpty { t.models.insert(value) }
            case "kind": t.kind = VehicleKind(rawValue: value)
            case "line": if !value.isEmpty { t.line = value }
            case "length": if let l = LengthBand(rawValue: value) { t.lengths.insert(l) }
            case "drive": if let d = ModelSpecs.Drive(rawValue: value) { t.drives.insert(d) }
            case "floor": if let f = ModelSpecs.Floor(rawValue: value) { t.floors.insert(f) }
            default: break
            }
        }
        self = t
    }
}

/// Vehicles that would sit on top of each other on the map, shown as one count bubble.
public struct PinGroup: Identifiable, Sendable {
    /// The rarest vehicle in the group; it colours the bubble.
    public let lead: WantedPin
    public let pins: [WantedPin]
    /// The map square the group lives in: the same square keeps the same id across
    /// refreshes, so a bubble doesn't lose its identity as its buses creep along.
    public let cell: String

    public init(lead: WantedPin, pins: [WantedPin], cell: String = "") {
        self.lead = lead
        self.pins = pins
        self.cell = cell
    }

    /// A lone vehicle keeps its own id, so selecting it works the same grouped or not.
    public var id: String { pins.count == 1 ? lead.id : "group:\(cell)" }
    public var hasNewModel: Bool { pins.contains { $0.kind == .newModel } }
    /// Middle of the group, where its bubble sits.
    public var latitude: Double { pins.map(\.vehicle.latitude).reduce(0, +) / Double(pins.count) }
    public var longitude: Double { pins.map(\.vehicle.longitude).reduce(0, +) / Double(pins.count) }
}

extension Wanted {
    /// Buckets pins into fixed map squares `cellLon` degrees wide (and as tall on screen).
    /// Squares are anchored to the map, not to the vehicles, so groups hold still between
    /// refreshes instead of reshuffling. Pins keep their priority order: the rarest leads.
    public static func group(_ pins: [WantedPin], cellLon: Double, latitude: Double) -> [PinGroup] {
        guard cellLon > 0 else { return pins.map { PinGroup(lead: $0, pins: [$0]) } }
        // On a Mercator map a degree of latitude is taller than one of longitude.
        let cellLat = cellLon * cos(latitude * .pi / 180)
        var order: [String] = []
        var members: [String: [WantedPin]] = [:]
        for p in pins {
            let key = "\(Int(floor(p.vehicle.longitude / cellLon))):\(Int(floor(p.vehicle.latitude / cellLat)))"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(p)
        }
        return order.map { PinGroup(lead: members[$0]![0], pins: members[$0]!, cell: $0) }
    }
}

extension Geo {
    /// Compass bearing from one point to another, degrees clockwise from north.
    public static func bearing(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let rad = Double.pi / 180
        let dLon = (b.1 - a.1) * rad
        let y = sin(dLon) * cos(b.0 * rad)
        let x = cos(a.0 * rad) * sin(b.0 * rad) - sin(a.0 * rad) * cos(b.0 * rad) * cos(dLon)
        return (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Which way a vehicle is going, relative to you.
public enum Motion: Sendable, Equatable {
    case approaching, leaving, passing, stopped
    /// Heading your way, but its route turns off before it reaches you.
    case turnsOff
}

/// Where each vehicle has been over the last few minutes, built up from successive feed
/// snapshots: the feed only says where a vehicle is, so its direction comes from watching
/// it move.
public struct LiveTrails: Sendable {
    public struct Point: Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        /// When the vehicle reported this position.
        public let time: Date

        public init(latitude: Double, longitude: Double, time: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.time = time
        }
    }

    /// Moves smaller than this are GPS jitter at a stop, not travel.
    public static let minStep = 15.0
    /// A heading needs this much travel, so one jittery fix can't flip the arrow.
    public static let headingBase = 30.0
    /// How much path the map draws behind a selected vehicle.
    public static let maxAge: TimeInterval = 600
    public static let maxPoints = 40
    /// A vehicle that stops reporting this long has left the feed (depot, end of shift).
    public static let forgetAfter: TimeInterval = 300
    /// Reporting in, but no travel for this long: standing at a stop or a light.
    public static let stoppedAfter: TimeInterval = 45

    private var points: [String: [Point]] = [:]
    /// Latest report time per vehicle, moving or not.
    private var lastSeen: [String: Date] = [:]

    public init() {}

    public static func key(_ kind: VehicleKind, _ number: Int) -> String { "\(kind.rawValue)#\(number)" }

    public mutating func record(_ vehicles: [LiveVehicle], now: Date = Date()) {
        for v in vehicles {
            let key = Self.key(v.kind, v.number)
            if let seen = lastSeen[key], v.time <= seen { continue }
            lastSeen[key] = v.time
            var trail = points[key] ?? []
            if let last = trail.last,
               Geo.km((last.latitude, last.longitude), (v.latitude, v.longitude)) * 1000 < Self.minStep {
                continue
            }
            trail.append(Point(latitude: v.latitude, longitude: v.longitude, time: v.time))
            trail.removeAll { v.time.timeIntervalSince($0.time) > Self.maxAge }
            points[key] = Array(trail.suffix(Self.maxPoints))
        }
        // Vehicles that left the feed (depot, end of shift) are forgotten.
        for (key, seen) in lastSeen where now.timeIntervalSince(seen) > Self.forgetAfter {
            lastSeen[key] = nil
            points[key] = nil
        }
    }

    /// Oldest first.
    public func trail(_ key: String) -> [Point] { points[key] ?? [] }

    /// Degrees clockwise from north, from the latest position back to the last one at
    /// least `headingBase` away. Nil until the vehicle has travelled that far.
    public func heading(_ key: String) -> Double? {
        guard let (from, to) = base(key) else { return nil }
        return Geo.bearing((from.latitude, from.longitude), (to.latitude, to.longitude))
    }

    /// Reporting in, but hasn't moved for a while.
    public func isStopped(_ key: String) -> Bool {
        guard let last = points[key]?.last, let seen = lastSeen[key] else { return false }
        return seen.timeIntervalSince(last.time) >= Self.stoppedAfter
    }

    /// Relative to someone standing at `lat`/`lon`. Nil while there's too little to go on.
    public func motion(_ key: String, lat: Double, lon: Double) -> Motion? {
        if isStopped(key) { return .stopped }
        guard let (from, to) = base(key) else { return nil }
        let before = Geo.km((lat, lon), (from.latitude, from.longitude)) * 1000
        let after = Geo.km((lat, lon), (to.latitude, to.longitude)) * 1000
        let travelled = Geo.km((from.latitude, from.longitude), (to.latitude, to.longitude)) * 1000
        // Mostly towards or away from you; otherwise it's going past.
        if before - after > travelled * 0.5 { return .approaching }
        if after - before > travelled * 0.5 { return .leaving }
        return .passing
    }

    private func base(_ key: String) -> (Point, Point)? {
        guard let trail = points[key], let last = trail.last else { return nil }
        let from = trail.dropLast().last { p in
            Geo.km((p.latitude, p.longitude), (last.latitude, last.longitude)) * 1000 >= Self.headingBase
        }
        return from.map { ($0, last) }
    }
}
