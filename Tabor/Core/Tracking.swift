import Foundation

/// What a Live Activity follows (#42): a vehicle coming your way, from where it is to the stop
/// where its route passes you. The server tracks it along `path` and pushes how far it has left.
public struct TrackPlan: Sendable {
    /// Your stop, or nil when the route passes you between stops.
    public let stop: String?
    /// Where it meets you: your stop, or the point on its route nearest you.
    public let target: (latitude: Double, longitude: Double)
    /// Metres along the route from the vehicle to you.
    public let distance: Double
    /// Stops it calls at before it reaches you, yours included.
    public let stops: Int
    /// The stop it's at or last passed.
    public let at: String?
    /// The route from a little behind the vehicle to a little past you, for the server to place
    /// it on each time the feed moves it.
    public let path: [(latitude: Double, longitude: Double)]
    /// The stops on that path.
    public let pathStops: [RouteStop]

    /// A stop this close to where the route passes you is the one you'd wait at.
    public static let stopReach = 200.0
    /// The path runs this far past each end, so a late fix or a GPS wobble still lands on it.
    public static let margin = 400.0

    /// The plan for a vehicle placed on its route, if that route comes within `near` metres of
    /// you somewhere ahead (as `RouteMatch.motion` decides COMING).
    public static func make(match: RouteMatch, lat: Double, lon: Double, near: Double = 150) -> TrackPlan? {
        let shape = match.shape
        let here = match.coordinate
        let straight = Geo.km((lat, lon), (here.latitude, here.longitude)) * 1000
        let horizon = min(match.along + straight * 2 + 300, shape.length)
        guard horizon > match.along,
              let fit = shape.project((lat, lon), in: match.along...horizon),
              fit.offset <= near, fit.along > match.along + 20 else { return nil }

        let ahead = shape.stops.filter { $0.along > match.along + 15 }
        let yours = ahead.min { abs($0.along - fit.along) < abs($1.along - fit.along) }
            .flatMap { abs($0.along - fit.along) <= stopReach ? $0 : nil }
        let targetAlong = yours?.along ?? fit.along
        let target = yours.map { ($0.latitude, $0.longitude) } ?? shape.coordinate(at: fit.along)

        let from = max(0, match.along - margin), to = min(shape.length, targetAlong + margin)
        return TrackPlan(
            stop: yours?.name, target: target, distance: targetAlong - match.along,
            stops: ahead.filter { $0.along <= targetAlong + 1 }.count,
            at: shape.stops.last { $0.along <= match.along + 15 }?.name,
            path: shape.path(from: from, to: to),
            pathStops: shape.stops.filter { $0.along >= from && $0.along <= to })
    }
}
