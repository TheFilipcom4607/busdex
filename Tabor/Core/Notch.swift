import CoreGraphics

/// How badly erasing someone from a sticker would bite into the vehicle. Erasing can't show
/// what they stood in front of, so where the vehicle carries on at both sides of them, the
/// gap reads as a bite out of it. Someone at its end, with the vehicle on one side only,
/// erases cleanly. A whole person beats a bite.
public enum Notch {
    /// Above this share of the vehicle's pixels, the person stays.
    public static let limit = 0.01

    /// For each box (normalised, top-left origin): the pixels erasing took out inside it,
    /// between the vehicle's leftmost and rightmost pixel on their row, over the vehicle's
    /// size. Masks are one byte a pixel, row by row, over 127 meaning in.
    public static func shares(before: [UInt8], after: [UInt8], width w: Int, height h: Int, boxes: [CGRect]) -> [Double] {
        var left = [Int](repeating: Int.max, count: h), right = [Int](repeating: -1, count: h)
        var vehicle = 0
        for y in 0..<h {
            for x in 0..<w where after[y * w + x] > 127 {
                vehicle += 1
                left[y] = min(left[y], x)
                right[y] = max(right[y], x)
            }
        }
        guard vehicle > 0 else { return boxes.map { _ in 0 } }
        return boxes.map { b in
            let x0 = max(0, Int(b.minX * CGFloat(w))), x1 = min(w, Int((b.maxX * CGFloat(w)).rounded(.up)))
            let y0 = max(0, Int(b.minY * CGFloat(h))), y1 = min(h, Int((b.maxY * CGFloat(h)).rounded(.up)))
            var bitten = 0
            for y in y0..<max(y0, y1) where right[y] >= 0 {
                for x in max(x0, left[y] + 1)..<max(max(x0, left[y] + 1), min(x1, right[y])) {
                    let i = y * w + x
                    if before[i] > 127, after[i] <= 127 { bitten += 1 }
                }
            }
            return Double(bitten) / Double(vehicle)
        }
    }
}
