import Foundation

/// A few works cars carry a code instead of a number (S-9, P1). Each code is kept as a number
/// of its own, from 1 000 000 000 up, which nothing the camera or the number pad gives can
/// reach: catches, batches and the number index all stay Ints, and the number says its own
/// code back without the catalog. fetch_fleet.py's `coded_number` encodes the same way.
/// The widget extension compiles this file too, so widgets show codes.
public enum FleetNumber {
    static let base = 1_000_000_000
    /// A digit of 0 would make "0S" and "S" the same number, so symbols count from 1.
    static let symbols = Array("-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let radix = symbols.count + 1
    static let maxLength = 5
    static let span = (0..<maxLength).reduce(1) { n, _ in n * radix }

    /// "S-9" -> its number; nil for anything that can't be a code.
    public static func coded(_ code: String) -> Int? {
        let chars = Array(code.uppercased())
        guard (1...maxLength).contains(chars.count) else { return nil }
        var n = 0
        for c in chars {
            guard let i = symbols.firstIndex(of: c) else { return nil }
            n = n * radix + i + 1
        }
        return base + n
    }

    public static func code(of number: Int) -> String? {
        guard isCoded(number) else { return nil }
        var n = number - base
        var chars: [Character] = []
        while n > 0 {
            let digit = n % radix
            guard digit > 0 else { return nil }
            chars.insert(symbols[digit - 1], at: 0)
            n /= radix
        }
        return String(chars)
    }

    public static func isCoded(_ number: Int) -> Bool {
        number > base && number - base < span
    }

    /// How a fleet number is shown: the code for a coded car, the digits otherwise.
    public static func label(_ number: Int) -> String { code(of: number) ?? String(number) }

    /// What a typed code is compared by: "s 9", "S9" and "S-9" are one code.
    public static func normalised(_ code: String) -> String {
        String(code.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}
