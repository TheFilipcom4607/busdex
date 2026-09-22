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
    private let byId: [String: VehicleModel]
    private let byNumber: [Int: [VehicleModel]]

    public init(data: FleetData) {
        models = data.models
        depots = data.depots
        source = data.source
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

    public func model(id: String) -> VehicleModel? { byId[id] }

    public var totalFleet: Int { models.reduce(0) { $0 + $1.fleet } }

    /// Manual assignments win, then the ZTM database.
    public func match(number: Int, kind: VehicleKind? = nil,
                      manual: [Int: String] = [:]) -> ModelMatch {
        if let id = manual[number], let m = byId[id] { return .certain(m) }
        let hits = (byNumber[number] ?? []).filter { kind == nil || $0.kind == kind }
        switch hits.count {
        case 0: return .unknown
        case 1: return .certain(hits[0])
        // Buses outnumber trams; list the bigger fleet first.
        default: return .ambiguous(hits.sorted { $0.fleet > $1.fleet })
        }
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
