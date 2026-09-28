import Foundation

/// Every bus and tram line's street shapes and stops, from ZTM's GTFS (routes.json, built by
/// scripts/build_routes.py). The live feed only says where a vehicle is; this says where it
/// goes next.
public struct RouteBook: Sendable {
    public let feed: String
    public let built: String
    private let lines: [String: [RouteShape]]

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        feed = file.feed
        built = file.built
        lines = file.lines.reduce(into: [:]) { out, entry in
            guard let kind = VehicleKind(rawValue: entry.value.kind) else { return }
            out[Self.key(kind, entry.key)] = entry.value.shapes.compactMap { s in
                RouteShape(id: s.id, trips: s.trips, points: Polyline.decode(s.path), stops: s.stops.map(\.stop))
            }
        }
    }

    public init(feed: String = "", built: String = "", shapes: [String: [RouteShape]]) {
        self.feed = feed
        self.built = built
        lines = shapes
    }

    public var lineCount: Int { lines.count }

    public static func key(_ kind: VehicleKind, _ line: String) -> String { "\(kind.rawValue)#\(line)" }

    public func shapes(line: String, kind: VehicleKind) -> [RouteShape] { lines[Self.key(kind, line)] ?? [] }

    /// A vehicle further than this from every shape of its line is off its route (a detour,
    /// a depot run) or the GPS is off: better no future than a wrong one.
    public static let maxOffset = 60.0
    /// Two fits this close are the same street: a shared stretch before a fork.
    static let tie = 4.0
    /// Enough travel to trust the trail's direction, as for the arrow on the map.
    static let minTravel = LiveTrails.headingBase

    /// Which of its line's shapes the vehicle is on, and where along it. The trail says which
    /// way it's going (its fixes must run forward along the shape); where shapes fit equally
    /// well, a shared stretch before a fork, the one most trips run wins: the usual way.
    public func match(line: String, kind: VehicleKind, trail: [LiveTrails.Point], position: LiveTrails.Point) -> RouteMatch? {
        let shapes = shapes(line: line, kind: kind)
        guard !shapes.isEmpty else { return nil }
        let here = (position.latitude, position.longitude)
        // Recent fixes only: an old one from before a turn says little about the way it's going.
        let recent = trail.filter { position.time.timeIntervalSince($0.time) <= 180 && $0.time < position.time }
            .suffix(8)
        let travelled = recent.first.map { Geo.km(($0.latitude, $0.longitude), here) * 1000 } ?? 0
        let moving = travelled >= Self.minTravel

        struct Fit { let shape: RouteShape; let along: Double; let score: Double; let speed: Double }
        var fits: [Fit] = []
        for shape in shapes {
            for along in shape.fits(here, within: Self.maxOffset) {
                let offset = shape.offset(of: here, at: along)
                guard moving else {
                    fits.append(Fit(shape: shape, along: along, score: offset, speed: 0))
                    continue
                }
                // Each earlier fix must sit on the shape behind this point, no further back than
                // it could have driven.
                var offsets = [offset]
                var earliest: (along: Double, time: Date)?
                var ok = true
                for p in recent {
                    let straight = Geo.km((p.latitude, p.longitude), here) * 1000
                    let window = (along - straight * 2.5 - 100)...(along + 10)
                    guard let fit = shape.project((p.latitude, p.longitude), in: window), fit.offset <= Self.maxOffset else {
                        ok = false
                        break
                    }
                    offsets.append(fit.offset)
                    if earliest == nil { earliest = (fit.along, p.time) }
                }
                guard ok, let earliest, along - earliest.along >= Self.minTravel / 2 else { continue }
                let seconds = position.time.timeIntervalSince(earliest.time)
                let speed = seconds > 0 ? (along - earliest.along) / seconds : 0
                fits.append(Fit(shape: shape, along: along, score: offsets.reduce(0, +) / Double(offsets.count),
                                speed: min(max(speed, 0), RouteMatch.maxSpeed)))
            }
        }
        guard let best = fits.map(\.score).min() else { return nil }
        let close = fits.filter { $0.score <= best + Self.tie }
        // Standing still, the trail can't say which way it's facing: only commit when every
        // fit agrees (a one-way street, or the only shape through here).
        if !moving {
            let bearings = close.map { $0.shape.bearing(at: $0.along) }
            guard let first = bearings.first, bearings.allSatisfy({ Self.angle($0, first) < 45 }) else { return nil }
        }
        let pick = close.max { a, b in (a.shape.trips, -a.score) < (b.shape.trips, -b.score) }!
        return RouteMatch(shape: pick.shape, along: pick.along, speed: pick.speed)
    }

    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    private struct File: Decodable {
        let feed: String
        let built: String
        let lines: [String: Line]
    }

    private struct Line: Decodable {
        let kind: String
        let shapes: [Shape]
    }

    private struct Shape: Decodable {
        let id: String
        let trips: Int
        let path: String
        let stops: [StopRow]
    }

    /// `[name, lat, lon, metres along]`: an array keeps the file small.
    private struct StopRow: Decodable {
        let stop: RouteStop

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            stop = RouteStop(name: try c.decode(String.self), latitude: try c.decode(Double.self),
                             longitude: try c.decode(Double.self), along: try c.decode(Double.self))
        }
    }
}

public struct RouteStop: Sendable, Hashable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    /// Metres from the start of its shape.
    public let along: Double

    public init(name: String, latitude: Double, longitude: Double, along: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.along = along
    }
}

/// One way a line runs: its street path and stops, in order.
public struct RouteShape: Sendable {
    public let id: String
    /// Trips a day that run this way; the most-run way wins at a fork.
    public let trips: Int
    public let points: [(latitude: Double, longitude: Double)]
    public let stops: [RouteStop]
    /// Metres from the start to each point.
    let cumulative: [Double]
    /// The points in metres on a flat map centred on the shape: projecting onto a segment is
    /// then plain arithmetic, and a few km of city don't need the Earth's curve.
    private let xy: [(x: Double, y: Double)]
    private let origin: (lat: Double, lon: Double)
    private let lonScale: Double
    private let bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)

    static let metresPerDegree = 6371.0 * 1000 * .pi / 180

    public init?(id: String, trips: Int, points: [(latitude: Double, longitude: Double)], stops: [RouteStop]) {
        guard points.count >= 2 else { return nil }
        self.id = id
        self.trips = trips
        self.points = points
        self.stops = stops
        origin = (points[0].latitude, points[0].longitude)
        lonScale = cos(points[0].latitude * .pi / 180)
        let o = origin, k = lonScale
        xy = points.map { ((($0.longitude - o.lon) * k) * Self.metresPerDegree, ($0.latitude - o.lat) * Self.metresPerDegree) }
        var c = [0.0]
        for i in 1..<points.count {
            c.append(c[i - 1] + Geo.km((points[i - 1].latitude, points[i - 1].longitude),
                                       (points[i].latitude, points[i].longitude)) * 1000)
        }
        cumulative = c
        bounds = (xy.map(\.x).min()!, xy.map(\.x).max()!, xy.map(\.y).min()!, xy.map(\.y).max()!)
    }

    public var length: Double { cumulative.last! }

    private func local(_ p: (Double, Double)) -> (x: Double, y: Double) {
        ((p.1 - origin.lon) * lonScale * Self.metresPerDegree, (p.0 - origin.lat) * Self.metresPerDegree)
    }

    /// The closest point on segment i: (metres along the shape, metres off it).
    private func onSegment(_ i: Int, _ p: (x: Double, y: Double)) -> (along: Double, offset: Double) {
        let a = xy[i], b = xy[i + 1]
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return (cumulative[i] + t * (cumulative[i + 1] - cumulative[i]), hypot(p.x - cx, p.y - cy))
    }

    /// The closest point on the shape between two distances along it.
    public func project(_ p: (Double, Double), in range: ClosedRange<Double> = -Double.infinity...Double.infinity)
        -> (along: Double, offset: Double)? {
        let q = local(p)
        var best: (along: Double, offset: Double)?
        for i in 0..<(points.count - 1) where cumulative[i + 1] >= range.lowerBound && cumulative[i] <= range.upperBound {
            var fit = onSegment(i, q)
            if !range.contains(fit.along) {
                // The segment pokes out of the range: use its end inside it.
                let along = min(max(fit.along, range.lowerBound), range.upperBound)
                let at = coordinate(at: along)
                fit = (along, Geo.km(p, (at.latitude, at.longitude)) * 1000)
            }
            if best == nil || fit.offset < best!.offset { best = fit }
        }
        return best
    }

    /// Every place the shape passes within `metres` of p, as distances along it: a loop or an
    /// out-and-back passes the same corner more than once.
    func fits(_ p: (Double, Double), within metres: Double) -> [Double] {
        let q = local(p)
        guard q.x >= bounds.minX - metres, q.x <= bounds.maxX + metres,
              q.y >= bounds.minY - metres, q.y <= bounds.maxY + metres else { return [] }
        var out: [Double] = []
        var run: (along: Double, offset: Double)?
        for i in 0..<(points.count - 1) {
            let fit = onSegment(i, q)
            if fit.offset <= metres {
                if run == nil || fit.offset < run!.offset { run = fit }
            } else if let r = run {
                out.append(r.along)
                run = nil
            }
        }
        if let r = run { out.append(r.along) }
        return out
    }

    func offset(of p: (Double, Double), at along: Double) -> Double {
        let at = coordinate(at: along)
        return Geo.km(p, (at.latitude, at.longitude)) * 1000
    }

    private func segment(at along: Double) -> Int {
        // Binary search: the last point at or before `along`.
        var lo = 0, hi = points.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= along { lo = mid } else { hi = mid }
        }
        return lo
    }

    public func coordinate(at along: Double) -> (latitude: Double, longitude: Double) {
        let d = min(max(along, 0), length)
        let i = segment(at: d)
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (d - cumulative[i]) / span : 0
        let a = points[i], b = points[i + 1]
        return (a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Compass bearing of travel at a distance along the shape.
    func bearing(at along: Double) -> Double {
        let i = segment(at: min(max(along, 0), length))
        return Geo.bearing((points[i].latitude, points[i].longitude), (points[i + 1].latitude, points[i + 1].longitude))
    }

    /// The path between two distances along the shape, ends included.
    public func path(from a: Double, to b: Double) -> [(latitude: Double, longitude: Double)] {
        let from = min(max(a, 0), length), to = min(max(b, 0), length)
        guard to > from else { return [] }
        var out = [coordinate(at: from)]
        for i in 0..<points.count where cumulative[i] > from && cumulative[i] < to { out.append(points[i]) }
        out.append(coordinate(at: to))
        return out
    }
}

/// A vehicle placed on its route.
public struct RouteMatch: Sendable {
    public let shape: RouteShape
    /// Metres along the shape.
    public let along: Double
    /// Metres a second along the shape over its recent fixes, dwell at stops included.
    public let speed: Double

    /// Faster than any bus or tram gets in the city: a GPS jump, not travel.
    public static let maxSpeed = 15.0
    /// A fix is never slid forward by more than this much time: past it, where the vehicle
    /// is has too little to do with where it was.
    public static let maxAdvance: TimeInterval = 45

    public init(shape: RouteShape, along: Double, speed: Double) {
        self.shape = shape
        self.along = along
        self.speed = speed
    }

    public var coordinate: (latitude: Double, longitude: Double) { shape.coordinate(at: along) }

    /// The next stops, and the path to the last of them. A stop the vehicle is standing at
    /// (within a few metres) counts as passed.
    public func upcoming(stops count: Int = 4) -> (stops: [RouteStop], path: [(latitude: Double, longitude: Double)]) {
        let next = Array(shape.stops.filter { $0.along > along + 15 }.prefix(count))
        return (next, shape.path(from: along, to: next.last?.along ?? shape.length))
    }

    /// Slid forward along the route by `seconds` at its recent speed: where it probably is
    /// now, since the fix is some seconds old. Never past the next stop, where it would wait.
    public func advanced(by seconds: TimeInterval, stopped: Bool = false) -> RouteMatch {
        guard !stopped, seconds > 0 else { return self }
        var target = along + speed * min(seconds, Self.maxAdvance)
        if let stop = shape.stops.first(where: { $0.along > along + 15 }) { target = min(target, stop.along) }
        return RouteMatch(shape: shape, along: min(target, shape.length), speed: speed)
    }

    /// Coming your way only if its route actually comes past you: within `near` metres of you
    /// somewhere ahead, before it has gone twice as far as the straight line to you. Heading
    /// for you in a straight line but turning off first is `.turnsOff`. Anything else is left
    /// to the straight-line guess.
    public func motion(fallback: Motion?, lat: Double, lon: Double, near: Double = 150) -> Motion? {
        guard fallback != .stopped else { return fallback }
        let here = coordinate
        let straight = Geo.km((lat, lon), (here.latitude, here.longitude)) * 1000
        let horizon = along + straight * 2 + 300
        // The closest point ahead being right where it is now means it's already past you.
        if let fit = shape.project((lat, lon), in: along...max(along, min(horizon, shape.length))),
           fit.offset <= near, fit.along > along + 20 {
            return .approaching
        }
        return fallback == .approaching ? .turnsOff : fallback
    }
}

/// Google's encoded polyline format, 5 decimal places.
public enum Polyline {
    public static func decode(_ s: String) -> [(latitude: Double, longitude: Double)] {
        var out: [(latitude: Double, longitude: Double)] = []
        var lat = 0, lon = 0
        let bytes = Array(s.utf8)
        var i = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append((Double(lat) / 1e5, Double(lon) / 1e5))
        }
        return out
    }

    public static func encode(_ points: [(latitude: Double, longitude: Double)]) -> String {
        var out = ""
        var pLat = 0, pLon = 0
        func put(_ d: Int) {
            var v = d < 0 ? ~(d << 1) : d << 1
            while v >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for p in points {
            let lat = Int((p.latitude * 1e5).rounded()), lon = Int((p.longitude * 1e5).rounded())
            put(lat - pLat)
            put(lon - pLon)
            pLat = lat
            pLon = lon
        }
        return out
    }
}
