import SwiftUI
import UIKit

/// Colour tokens lifted from the design prototype (Tabor.dc.html).
enum Palette {
    static let bg = Color(hex: 0x0B0C0E)
    static let card = Color(hex: 0x14161A)
    static let chip = Color(hex: 0x16181C)
    static let slot = Color(hex: 0x111317)
    static let track = Color(hex: 0x23262B)
    static let thumb = Color(hex: 0x1B1E23)
    static let mapBg = Color(hex: 0x101317)

    static let ink = Color(hex: 0xF7F5F0)
    static let sub = Color(hex: 0x8A8F98)
    static let dim = Color(hex: 0x71767E)
    static let faint = Color(hex: 0x585D65)
    static let ghost = Color(hex: 0x3E444B)
    static let routeInk = Color(hex: 0xC9CDD3)

    static let yellow = Color(hex: 0xFFCE00)
    static let yellowHover = Color(hex: 0xFFD933)
    static let red = Color(hex: 0xE4002B)
    static let green = Color(hex: 0x23E5A0)
    static let greenInk = Color(hex: 0xB9F5DE)

    // Sticker (white die-cut) internals
    static let paper = Color.white
    static let photoWell = Color(hex: 0xE8E4DA)
    static let stickerInk = Color(hex: 0x0B0C0E)
    static let stickerSub = Color(hex: 0x6B7075)
    static let stickerCount = Color(hex: 0x9A9384)
    static let goldInk = Color(hex: 0x8A6A00)
    static let goldWash = Color(hex: 0xFFE896)

    static let hairline = Color.white.opacity(0.07)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .legendary: Palette.red
        case .gold: Palette.yellow
        case .rare: Palette.green
        case .common: Palette.dim
        }
    }

    var bar: Color {
        switch self {
        case .legendary: Palette.red
        case .gold: Palette.yellow
        case .rare: Palette.green
        case .common: Color(hex: 0x4A5158)
        }
    }
}

// MARK: - Type

enum TaborFont {
    /// Space Grotesk ships as a variable font (wght 300–700); pin the axis explicitly.
    static func grotesk(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        let base = UIFontDescriptor(fontAttributes: [.name: "SpaceGrotesk-Light"])
        let wghtTag = 0x7767_6874 // 'wght'
        let desc = base.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtTag: weight],
        ])
        return Font(UIFont(descriptor: desc, size: size) as CTFont)
    }

    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        let name = switch weight {
        case ..<450: "IBMPlexMono-Regular"
        case ..<550: "IBMPlexMono-Medium"
        case ..<650: "IBMPlexMono-SemiBold"
        default: "IBMPlexMono-Bold"
        }
        return Font.custom(name, fixedSize: size)
    }
}

extension View {
    /// CSS-style `letter-spacing: Nem`.
    func em(_ value: CGFloat, size: CGFloat) -> some View { tracking(value * size) }
}

/// Monospaced caps label — the design's most common text style.
struct Mono: View {
    let text: String
    var size: CGFloat = 12
    var weight: CGFloat = 400
    var spacing: CGFloat = 0.1
    var color: Color = Palette.dim

    init(_ text: String, size: CGFloat = 12, weight: CGFloat = 400, spacing: CGFloat = 0.1, color: Color = Palette.dim) {
        self.text = text
        self.size = size
        self.weight = weight
        self.spacing = spacing
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(TaborFont.mono(size, weight))
            .em(spacing, size: size)
            .foregroundStyle(color)
    }
}
