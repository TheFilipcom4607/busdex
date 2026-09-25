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
        /// The API answers 200 with `"result": "<message>"` for a bad key, overload, etc.
        case message(String)
        case malformed
    }

    /// Parses one `busestrams_get` reply. Non-numeric fleet numbers ("d. 35154") and stale
    /// rows are dropped.
    public static func parse(_ data: Data, kind: VehicleKind, now: Date = Date()) throws -> [LiveVehicle] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed }
        if let message = root["result"] as? String { throw Failure.message(message) }
        guard let rows = root["result"] as? [[String: Any]] else { throw Failure.malformed }
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
    }

    public struct Rescue: Sendable, Equatable, Codable {
        public let from: Int
        public let to: Int
    }

    /// Boosts candidates that are running nearby, and adds the nearby vehicle a read is
    /// one digit off from (OCR turning 4235 into 1235).
    public static func adjust(_ candidates: [(number: Int, score: Double)],
                              nearby: [NearbyVehicle]) -> (candidates: [(number: Int, score: Double)], adjustment: Adjustment) {
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
            out.append(c)
            let fixes = Set(rescuers.map(\.vehicle.number).filter { oneDigitOff(c.number, $0) })
            // Two nearby vehicles both one digit away: no way to tell which, so don't guess.
            if fixes.count == 1, let to = fixes.first {
                out.append((to, c.score + 1))
                adj.rescued.append(Rescue(from: c.number, to: to))
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
    /// ambiguous match and for a mode that preferred the other kind.
    public static func resolve(_ match: ModelMatch, number: Int, nearby: [NearbyVehicle],
                               catalog: FleetCatalog) -> ModelMatch {
        let kinds = Set(nearby.filter { $0.vehicle.number == number && $0.distance <= boostRadius }.map(\.vehicle.kind))
        guard kinds.count == 1, let kind = kinds.first else { return match }
        let hits = match.candidates.filter { $0.kind == kind }
        if hits.count == 1 { return .certain(hits[0]) }
        if hits.isEmpty, case .certain(let m) = catalog.match(number: number, kind: kind) { return .certain(m) }
        return match
    }

    /// The line the vehicle was running on at `date`, if the feed saw it recently enough.
    public static func line(for number: Int, kind: VehicleKind, snapshot: LiveSnapshot?, at date: Date) -> String? {
        guard let v = snapshot?.vehicle(number: number, kind: kind), !v.line.isEmpty,
              abs(date.timeIntervalSince(v.time)) <= lineWindow
        else { return nil }
        return v.line
    }
}

/// A live vehicle you haven't caught yet, for the HUNT map.
public struct WantedPin: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case newModel, newVehicle }

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
    /// Numbers the ZTM database doesn't know are left out.
    public static func pins(snapshot: LiveSnapshot, catalog: FleetCatalog, caught: CollectionStats,
                            lat: Double, lon: Double, within metres: Double = radius,
                            from user: (lat: Double, lon: Double)? = nil,
                            limit: Int = limit) -> [WantedPin] {
        let pins: [WantedPin] = snapshot.nearby(lat: lat, lon: lon, within: metres).compactMap { n in
            guard let model = catalog.match(number: n.vehicle.number, kind: n.vehicle.kind).suggested,
                  caught.vehicle(number: n.vehicle.number, modelId: model.id) == nil
            else { return nil }
            let kind: WantedPin.Kind = caught.ownedCount(modelId: model.id) == 0 ? .newModel : .newVehicle
            let distance = user.map { Geo.km(($0.lat, $0.lon), (n.vehicle.latitude, n.vehicle.longitude)) * 1000 } ?? n.distance
            return WantedPin(vehicle: n.vehicle, model: model, kind: kind, distance: distance)
        }
        return Array(pins.sorted { a, b in
            (a.kind == .newModel ? 0 : 1, huntRank(a.model.tier), a.distance)
                < (b.kind == .newModel ? 0 : 1, huntRank(b.model.tier), b.distance)
        }.prefix(limit))
    }

    /// Vintage stock sorts last in the book, but one that's actually out running is as
    /// rare a sight as anything: rank it with the legendaries.
    static func huntRank(_ tier: Tier) -> Int {
        tier == .vintage ? Tier.legendary.rank : tier.rank
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
