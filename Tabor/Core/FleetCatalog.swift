import Foundation

/// Result of looking up a fleet number.
public enum ModelMatch: Equatable, Sendable {
    /// The number belongs to exactly one model (or the user assigned it by hand).
    case certain(VehicleModel)
    /// The same number exists on several models, e.g. bus 1974 and tram 1974 in AUTO mode.
    case ambiguous([VehicleModel])
    case unknown

    public var suggested: VehicleModel? {
        switch self {
        case .certain(let m): m
        case .ambiguous(let ms): ms.first
        case .unknown: nil
        }
    }

    public var candidates: [VehicleModel] {
        switch self {
        case .certain(let m): [m]
        case .ambiguous(let ms): ms
        case .unknown: []
        }
    }
}

public struct FleetCatalog: Sendable {
    public let models: [VehicleModel]
    public let depots: [Depot]
    public let source: String
    /// ISO date of the ZTM snapshot, e.g. "2026-09-22".
    public let fetched: String?
    private let byId: [String: VehicleModel]
    private let byNumber: [Int: [VehicleModel]]

    public init(data: FleetData) {
        models = data.models
        depots = data.depots
        source = data.source
        fetched = data.fetched
        byId = Dictionary(uniqueKeysWithValues: data.models.map { ($0.id, $0) })
        var index: [Int: [VehicleModel]] = [:]
        for m in data.models {
            for n in m.numbers { index[n, default: []].append(m) }
        }
        byNumber = index
    }

    public init(json: Data) throws {
        self.init(data: try JSONDecoder().decode(FleetData.self, from: json))
    }

    /// No fleet data at all: the app still opens, with an empty book.
    public static let empty = FleetCatalog(data: FleetData(source: "", fetched: nil, models: [], depots: []))

    /// Decodes a fleet.json and rejects ones that parse but can't be a real snapshot.
    public static func validated(json: Data) -> FleetCatalog? {
        guard let c = try? FleetCatalog(json: json), !c.models.isEmpty, c.fetched != nil,
              c.models.allSatisfy({ $0.fleet == $0.numbers.count })
        else { return nil }
        return c
    }

    /// Whether this snapshot is strictly newer than `other` (ISO dates compare as strings).
    public func isNewer(than other: FleetCatalog?) -> Bool {
        guard let mine = fetched else { return false }
        guard let theirs = other?.fetched else { return true }
        return mine > theirs
    }

    /// A downloaded snapshot wins only while it's newer than the one shipped in the app,
    /// so an app update with fresher bundled data isn't shadowed by an old download.
    public static func preferred(bundled: FleetCatalog?, downloaded: FleetCatalog?) -> FleetCatalog? {
        if let downloaded, downloaded.isNewer(than: bundled) { return downloaded }
        return bundled ?? downloaded
    }

    public func model(id: String) -> VehicleModel? { byId[id] }

    /// Vehicles on regular routes; vintage stock doesn't count toward the fleet.
    public var totalFleet: Int { models.filter { !$0.vintage }.reduce(0) { $0 + $1.fleet } }

    /// Manual assignments win, then the ZTM database.
    public func match(number: Int, kind: VehicleKind? = nil,
                      manual: [Int: String] = [:]) -> ModelMatch {
        if let id = manual[number], let m = byId[id] { return .certain(m) }
        let hits = (byNumber[number] ?? []).filter { kind == nil || $0.kind == kind }
        switch hits.count {
        case 0: return .unknown
        case 1: return .certain(hits[0])
        // Regular stock before preserved vehicles, then the bigger fleet first.
        default: return .ambiguous(hits.sorted { ($0.vintage ? 1 : 0, -$0.fleet) < ($1.vintage ? 1 : 0, -$1.fleet) })
        }
    }

    /// The camera's BUS/TRAM mode is a preference, not a filter: a bus number read in
    /// TRAM mode still matches the bus (spotters forget to switch back).
    public func match(number: Int, preferring kind: VehicleKind?,
                      manual: [Int: String] = [:]) -> ModelMatch {
        let strict = match(number: number, kind: kind, manual: manual)
        return strict == .unknown && kind != nil ? match(number: number, manual: manual) : strict
    }

    public func isKnown(number: Int, kind: VehicleKind? = nil) -> Bool {
        match(number: number, kind: kind) != .unknown
    }

    /// Models for a picker: candidates first, then the rest of the same kind, then others.
    public func pickerOrder(candidates: [VehicleModel], kind: VehicleKind?) -> [VehicleModel] {
        let ids = Set(candidates.map(\.id))
        let rest = models.filter { !ids.contains($0.id) }
        let sameKind = rest.filter { kind == nil || $0.kind == kind }.sorted { $0.name < $1.name }
        let other = rest.filter { kind != nil && $0.kind != kind }.sorted { $0.name < $1.name }
        return candidates + sameKind + other
    }
}
