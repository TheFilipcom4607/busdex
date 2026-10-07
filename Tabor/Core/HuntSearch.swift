import Foundation

/// HUNT's search (#31): type a fleet number to find that vehicle, or a line to see what's on it.
/// Numbers and lines overlap ("160" is a bus line and a tram's number), so it offers both.
public enum HuntSearch {
    /// A line running now, and how many of its vehicles the feed has.
    public struct Line: Hashable, Sendable {
        public let line: String
        public let kind: VehicleKind
        public let count: Int
    }

    /// A vehicle with the number typed, running now or not.
    public struct Vehicle: Hashable, Sendable {
        public let number: Int
        public let model: VehicleModel
        /// Its row in the feed, if it's out now.
        public let live: LiveVehicle?
    }

    public struct Results: Sendable {
        public let lines: [Line]
        public let vehicles: [Vehicle]
        public var isEmpty: Bool { lines.isEmpty && vehicles.isEmpty }
    }

    /// Lines whose name starts with what you typed (exact first, then shortest, at most `limit`),
    /// and every vehicle of any model with exactly that fleet number.
    public static func results(for query: String, snapshot: LiveSnapshot?, catalog: FleetCatalog, limit: Int = 4) -> Results {
        let key = lineKey(query)
        guard !key.isEmpty else { return Results(lines: [], vehicles: []) }
        var counts: [Line.ID: Int] = [:]
        var names: [Line.ID: String] = [:]
        for v in snapshot?.vehicles ?? [] where !v.line.isEmpty && lineKey(v.line).hasPrefix(key) {
            let id = Line.ID(key: lineKey(v.line), kind: v.kind)
            counts[id, default: 0] += 1
            names[id] = v.line
        }
        let lines = counts.map { Line(line: names[$0.key]!, kind: $0.key.kind, count: $0.value) }
            .sorted { a, b in
                let ea = lineKey(a.line) == key, eb = lineKey(b.line) == key
                if ea != eb { return ea }
                if a.line.count != b.line.count { return a.line.count < b.line.count }
                return a.line.localizedStandardCompare(b.line) == .orderedAscending
            }
        let vehicles = Int(key).map { n in
            catalog.match(number: n).candidates.map { m in
                Vehicle(number: n, model: m, live: snapshot?.vehicle(number: n, kind: m.kind))
            }
            // Running first: that's the one you can go and find.
            .sorted { ($0.live != nil) && ($1.live == nil) }
        } ?? []
        return Results(lines: Array(lines.prefix(limit)), vehicles: vehicles)
    }

    /// How lines compare: "l-4", "L4" and "L 4" are the same line.
    public static func lineKey(_ line: String) -> String {
        line.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension HuntSearch.Line {
    struct ID: Hashable { let key: String; let kind: VehicleKind }
}
