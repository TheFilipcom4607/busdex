import Foundation

/// One piece of recognised text from the camera, with the height of its box
/// relative to the frame (larger text is more likely the fleet number).
public struct TextObservation: Sendable {
    public let text: String
    public let confidence: Float
    public let height: Double

    public init(text: String, confidence: Float, height: Double) {
        self.text = text
        self.confidence = confidence
        self.height = height
    }
}

public enum CatchMode: String, CaseIterable, Sendable {
    case auto = "AUTO"
    case bus = "BUS"
    case tram = "TRAM"

    public var kind: VehicleKind? {
        switch self {
        case .auto: nil
        case .bus: .bus
        case .tram: .tram
        }
    }
}

public enum NumberExtractor {
    /// Picks the most plausible fleet number out of one frame's text.
    /// Warsaw numbers run 1–5 digits; only 4-digit strangers are trusted without a
    /// database hit, since short/long digit runs are usually line numbers or plates.
    public static func best(in observations: [TextObservation], mode: CatchMode,
                            catalog: FleetCatalog) -> Int? {
        candidates(in: observations, mode: mode, catalog: catalog).max { $0.score < $1.score }?.number
    }

    /// Every plausible number in the frame with its score; `best` picks the top one.
    public static func candidates(in observations: [TextObservation], mode: CatchMode,
                                  catalog: FleetCatalog) -> [(number: Int, score: Double)] {
        var scored: [(number: Int, score: Double)] = []
        for obs in observations {
            for (value, digits) in digitTokens(obs.text) {
                // The mode is a preference: a number from the other kind still counts,
                // it just ranks below one that fits the mode.
                let knownHere = catalog.isKnown(number: value, kind: mode.kind)
                let knownAnywhere = knownHere || (mode != .auto && catalog.isKnown(number: value))
                guard knownAnywhere || digits == 4 else { continue }
                var score = Double(obs.confidence) + obs.height * 4
                if knownHere { score += 2 } else if knownAnywhere { score += 1.5 }
                if digits < 3 { score -= 1 }
                scored.append((value, score))
            }
        }
        return scored
    }

    /// Standalone 2–5 digit runs with their length: "8465", "Nr 1974", but not
    /// "123456", "20:15", "3.14" or plates like "WI 5814N" / "WX 2021" (OCR often drops the
    /// trailing letter). Leading zeros are kept in the length.
    public static func digitTokens(_ text: String) -> [(value: Int, digits: Int)] {
        var out: [(Int, Int)] = []
        let chars = Array(text)
        let glue: Set<Character> = [":", ".", ",", "/"]
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            let before: Character = i > 0 ? chars[i - 1] : " "
            let after: Character = j < chars.count ? chars[j] : " "
            let len = j - i
            // Digits glued to letters are plates ("WX 2043F") or codes, not fleet numbers.
            let lettered = before.isLetter || after.isLetter
            if (2...5).contains(len), !lettered, !platePrefix(chars, before: i),
               !glue.contains(before), !glue.contains(after),
               let n = Int(String(chars[i..<j])) {
                out.append((n, len))
            }
            i = j
        }
        return out
    }

    /// Polish plates start with a 2–3 capital-letter county code ("WX", "WPI", "IX" when
    /// OCR drops the W), then a space or dash. "Nr"/"NR" before a number is a label, not a plate.
    static func platePrefix(_ chars: [Character], before i: Int) -> Bool {
        var j = i - 1
        guard j >= 0, chars[j] == " " || chars[j] == "-" else { return false }
        j -= 1
        var letters = ""
        while j >= 0, chars[j].isLetter { letters.insert(chars[j], at: letters.startIndex); j -= 1 }
        guard (2...3).contains(letters.count), letters.allSatisfy({ $0.isUppercase }), letters != "NR" else { return false }
        // The code must be a word of its own, not the tail of "LINIA 119".
        return j < 0 || !chars[j].isLetter
    }
}

/// Stabilises live OCR: a number is only "read" once it wins several recent frames.
public struct NumberVoter: Sendable {
    public let window: Int
    public let needed: Int
    private var recent: [Int?] = []

    public init(window: Int = 5, needed: Int = 3) {
        self.window = window
        self.needed = needed
    }

    public mutating func push(_ n: Int?) -> Int? {
        recent.append(n)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        let counts = Dictionary(grouping: recent.compactMap { $0 }, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= needed else { return nil }
        return top.key
    }

    public mutating func reset() { recent.removeAll() }
}
