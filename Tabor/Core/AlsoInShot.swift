import CoreGraphics
import Foundation

/// Other vehicles in a catch photo, like two trams passing (#30): numbers read besides the
/// caught one that belong to a real vehicle, offered on the reveal and only added when you
/// say so.
public enum AlsoInShot {
    /// One number read in the photo, with where it's written.
    public struct Read: Sendable {
        public let number: Int
        public let score: Double
        /// Normalised to the photo, top-left origin. Empty for a number that isn't written
        /// there (a feed neighbour offered for a misread); those never count.
        public let boxes: [CGRect]

        public init(number: Int, score: Double, boxes: [CGRect]) {
            self.number = number
            self.score = score
            self.boxes = boxes
        }
    }

    public struct Vehicle: Hashable, Sendable, Identifiable {
        public let number: Int
        public let model: VehicleModel
        /// Where its number is written: what its sticker is cut around.
        public let box: CGRect

        public var id: String { "\(model.id)#\(number)" }
    }

    /// More than this many is a depot yard, not a shot of a vehicle.
    public static let limit = 2

    /// The other vehicles worth offering, likeliest first.
    ///
    /// Vision gives two readings of each piece of text, and a vehicle shows its number in
    /// several places, so a number counts only where it's written somewhere no likelier
    /// number already claimed. With the live feed (`nearby` not empty) it must be running
    /// right there; without it, a 3-digit number could be the line on a display (503 is a
    /// 13N tram's number too). One digit off the caught number stays (9353 and 9355 park side
    /// by side): the app drops it when it's painted on the caught vehicle (`couldBeMisread`).
    public static func vehicles(in reads: [Read], caught: Int, model caughtModel: VehicleModel, partner: Int?,
                                catalog: FleetCatalog, nearby: [NearbyVehicle],
                                manual: [Int: String] = [:]) -> [Vehicle] {
        var best: [Int: Read] = [:]
        for r in reads where !r.boxes.isEmpty {
            if let had = best[r.number] {
                best[r.number] = Read(number: r.number, score: max(had.score, r.score), boxes: had.boxes + r.boxes)
            } else {
                best[r.number] = r
            }
        }
        var claimed = best[caught]?.boxes ?? []
        var out: [Vehicle] = []
        let live = !nearby.isEmpty
        for r in best.values.sorted(by: { ($0.score, $1.number) > ($1.score, $0.number) }) where r.number != caught {
            let free = r.boxes.filter { box in !claimed.contains { overlaps(box, $0) } }
            claimed += r.boxes
            guard let box = free.max(by: { $0.height < $1.height }), r.number != partner,
                  !isPartner(r.number, of: caught, model: caughtModel)
            else { continue }
            // A number on a bus and a tram (2022) goes with the caught one's kind, as the
            // camera's mode does, unless the feed says otherwise.
            let match = LiveHints.resolve(catalog.match(number: r.number, preferring: caughtModel.kind, manual: manual),
                                          number: r.number, nearby: nearby, catalog: catalog)
            guard case .certain(let model) = match else { continue }
            if live {
                let running = nearby.contains {
                    $0.vehicle.number == r.number && $0.vehicle.kind == model.kind && $0.distance <= LiveHints.boostRadius
                } || CoupledSet.partner(of: r.number, model: model, nearby: nearby) != nil
                guard running else { continue }
            } else {
                guard r.number >= 1000 else { continue }
            }
            out.append(Vehicle(number: r.number, model: model, box: box))
            if out.count == limit { break }
        }
        return out
    }

    /// One digit off the caught number: if it's painted on the caught vehicle too, it's that
    /// number read wrong, not a second vehicle.
    public static func couldBeMisread(_ n: Int, of caught: Int) -> Bool { LiveHints.oneDigitOff(n, caught) }

    /// The caught tram's other car: that's the "+ SECOND CAR" chip's, not this.
    static func isPartner(_ n: Int, of caught: Int, model: VehicleModel) -> Bool {
        guard model.isCoupled(caught), model.isCoupled(n) else { return false }
        return model.fixedPartner(of: caught) == n || abs(n - caught) == 1
    }

    /// Mostly the same patch of the photo: one piece of text read two ways.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && i.width * i.height / smaller > 0.5
    }
}
