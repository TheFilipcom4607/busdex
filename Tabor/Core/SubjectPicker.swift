import CoreGraphics

/// One object the subject lifter found in a catch photo, measured for picking.
public struct Subject: Sendable, Equatable {
    /// The lifter's instance label.
    public let label: Int
    public let pixels: Int
    /// Normalised to the photo, top-left origin.
    public let box: CGRect
    public let centroid: CGPoint
    /// How much of the fleet number's box this object's pixels cover, 0–1.
    public let numberCover: Double
    /// How much of this object lies inside a detected person, 0–1.
    public let personShare: Double

    public init(label: Int, pixels: Int, box: CGRect, centroid: CGPoint,
                numberCover: Double = 0, personShare: Double = 0) {
        self.label = label
        self.pixels = pixels
        self.box = box
        self.centroid = centroid
        self.numberCover = numberCover
        self.personShare = personShare
    }
}

/// Which rule chose the sticker's object; recorded by debug mode.
public enum PickReason: String, Codable, Sendable {
    /// The object the fleet number is painted on.
    case number
    /// No number to go by, and a person was passed over.
    case notPerson
    /// No number, no people: the biggest object, weighted towards the middle.
    case central
    /// Only people, and no number read: the biggest of them.
    case largest
}

/// Chooses which lifted object becomes the sticker. Taking the biggest one (as it used to)
/// goes wrong when someone stands closer to the camera than the bus, or a car fills the
/// edge of the frame: the bus is the object its fleet number sits on.
public enum SubjectPicker {
    /// Share of the number's box an object must cover to count as carrying it.
    static let minCover = 0.2
    /// Above this share inside person boxes, an object is a person. Passengers seen
    /// through the windows cover far less of a bus than that.
    static let personLimit = 0.6
    /// Objects smaller than this share of the frame are crumbs: never chosen over a person,
    /// and not offered as other cut-outs.
    static let minAlternative = 0.01

    /// Every object worth offering, best first, and why the first one won. Nil without any,
    /// and nil when a number was read but only people were lifted: the vehicle itself wasn't,
    /// and a catch of it shouldn't come out as somebody's portrait.
    /// `numberBox` is the fleet number's box (normalised, top-left), when it was read.
    public static func rank(_ subjects: [Subject], numberBox: CGRect?,
                            framePixels: Int? = nil) -> (order: [Int], reason: PickReason)? {
        guard !subjects.isEmpty else { return nil }
        let score = { (s: Subject) in Double(s.pixels) * centrality(s.centroid) }
        let floor = framePixels.map { Double($0) * minAlternative } ?? 0
        let people = subjects.filter { $0.personShare >= personLimit }
        let others = subjects.filter { $0.personShare < personLimit && Double($0.pixels) >= floor }
        let byScore = { (a: Subject, b: Subject) in score(a) > score(b) }

        var first: Subject?
        var reason = PickReason.central
        if let numberBox {
            if let s = subjects.filter({ $0.numberCover >= minCover }).max(by: { $0.numberCover < $1.numberCover }) {
                first = s
            } else {
                // The mask can miss thin painted digits: fall back to whose outline holds them.
                let centre = CGPoint(x: numberBox.midX, y: numberBox.midY)
                first = subjects.filter { $0.box.insetBy(dx: -$0.box.width * 0.05, dy: -$0.box.height * 0.05).contains(centre) }
                    .max(by: { score($0) < score($1) })
            }
            if first != nil { reason = .number }
        }
        if first == nil, let s = others.max(by: { score($0) < score($1) }) {
            first = s
            reason = people.isEmpty ? .central : .notPerson
        }
        if first == nil, numberBox == nil, let s = subjects.max(by: { $0.pixels < $1.pixels }) {
            first = s
            reason = .largest
        }
        guard let first else { return nil }

        let rest = (others.sorted(by: byScore) + people.sorted(by: byScore))
            .filter { $0.label != first.label && Double($0.pixels) >= floor }
        return ([first.label] + rest.map(\.label), reason)
    }

    /// 1 at the frame's centre, falling to 0.5 at the corners.
    static func centrality(_ p: CGPoint) -> Double {
        let d = ((p.x - 0.5) * (p.x - 0.5) + (p.y - 0.5) * (p.y - 0.5)).squareRoot()
        return 1 - 0.5 * min(1, d / 0.5.squareRoot())
    }
}
