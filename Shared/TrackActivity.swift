import ActivityKit
import Foundation

/// A vehicle followed on the Lock Screen and in the Dynamic Island (#42), from HUNT's TRACK
/// until it reaches your stop. The Worker (proxy/src/track.js) pushes `ContentState`, so its
/// keys and phases are the ones that file writes.
struct TrackAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case coming, here, passed, turnedOff, lost, ended, caught
        }

        var phase: Phase
        /// Metres along its route to your stop.
        var distance: Int
        /// Stops it calls at before yours, yours included.
        var stops: Int
        /// The stop it's at or last passed.
        var at: String?
        /// 0 where tracking started, 1 at your stop.
        var progress: Double
    }

    var number: Int
    var modelId: String
    var model: String
    /// LEGENDARY, GOLD…, for the number tag's colour.
    var tier: String
    var line: String
    var tram: Bool
    /// Your stop; nil when the route passes you between stops.
    var stop: String?
    /// Its sticker in the App Group, when it's in your book already; otherwise an outline.
    var image: String?
    var cutout: Bool
    /// Not in the book at all, as a model.
    var newModel: Bool
    /// In the book already, this very vehicle.
    var caught: Bool
    var started: Date

    /// HUNT on the vehicle, not its page: it's usually not in the book yet (#61).
    var url: URL { WidgetLink.hunt(vehicle: "\(tram ? "TRAM" : "BUS")#\(number)") }
}

extension TrackAttributes.ContentState {
    /// "830 m", "1.4 km".
    var distanceText: String {
        distance < 1000
            ? "\(distance) m"
            : Measurement(value: Double(distance) / 1000, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    var isOver: Bool { phase != .coming && phase != .here }
}
