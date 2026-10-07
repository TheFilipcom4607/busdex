import Foundation

/// A line typed into the correction sheet, looked up in the live feed (#50): what runs it right
/// now, nearest first, so you can tap the one you shot, and which models those are.
public enum LineLookup {
    public struct Running: Hashable, Sendable {
        public let vehicle: LiveVehicle
        /// Metres from you, when we know where you are.
        public let distance: Double?
    }

    public struct Result: Sendable {
        public let running: [Running]
        /// The models of the vehicles running it, the most common first.
        public let models: [VehicleModel]
        /// Bus or tram, when the feed (or else the timetable) has the line as only one of them.
        public let kind: VehicleKind?

        public static let none = Result(running: [], models: [], kind: nil)
    }

    public static func lookup(_ line: String, snapshot: LiveSnapshot?, routes: RouteBook?,
                              near here: (lat: Double, lon: Double)?, catalog: FleetCatalog,
                              manual: [Int: String] = [:]) -> Result {
        let key = HuntSearch.lineKey(line)
        guard !key.isEmpty else { return .none }
        var seen = Set<String>()
        let vehicles = (snapshot?.vehicles ?? []).filter {
            HuntSearch.lineKey($0.line) == key && seen.insert("\($0.kind.rawValue)#\($0.number)").inserted
        }
        let running = vehicles
            .map { v in Running(vehicle: v, distance: here.map { Geo.km(($0.lat, $0.lon), (v.latitude, v.longitude)) * 1000 }) }
            .sorted { a, b in
                if let da = a.distance, let db = b.distance, da != db { return da < db }
                return a.vehicle.number < b.vehicle.number
            }

        var counts: [String: (model: VehicleModel, count: Int)] = [:]
        for v in vehicles {
            guard let m = catalog.match(number: v.number, kind: v.kind, manual: manual).suggested else { continue }
            counts[m.id, default: (m, 0)].count += 1
        }
        let models = counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.model.name < $1.model.name }
            .map(\.model)

        // A line nothing is running on just now still has a timetable: 166 is a bus either way.
        var kinds = Set(vehicles.map(\.kind))
        if kinds.isEmpty, let routes {
            let spelled = line.trimmingCharacters(in: .whitespaces).uppercased()
            kinds = Set(VehicleKind.allCases.filter { !routes.shapes(line: spelled, kind: $0).isEmpty })
        }
        return Result(running: running, models: models, kind: kinds.count == 1 ? kinds.first : nil)
    }
}
