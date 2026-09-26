import SwiftUI

// MARK: - Photo

/// A stored catch photo, or the design's warm grey well when there is none.
struct CatchPhoto: View {
    let file: String?
    var maxPixel: Int = 600
    var placeholder: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.photoWell
                if let file, let img = PhotoStore.thumbnail(file, maxPixel: maxPixel) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let placeholder {
                    Mono(placeholder, size: 11, spacing: 0.04, color: Palette.stickerCount)
                }
            }
        }
    }
}

// MARK: - Sticker

/// White die-cut sticker: photo well + number row. Sizes follow the design's three uses.
struct Sticker<Trailing: View>: View {
    let number: Int
    let photo: String?
    var photoHeight: CGFloat = 70
    var radius: CGFloat = 11
    var innerRadius: CGFloat = 7
    var padding = EdgeInsets(top: 5, leading: 5, bottom: 7, trailing: 5)
    var numberSize: CGFloat = 13.5
    var shadow: (radius: CGFloat, y: CGFloat, opacity: Double) = (18, 8, 0.5)
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            CatchPhoto(file: photo, maxPixel: Int(photoHeight * 6))
                .frame(height: photoHeight)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
            HStack {
                Text(String(number))
                    .font(TaborFont.mono(numberSize, 700))
                    .foregroundStyle(Palette.stickerInk)
                Spacer(minLength: 2)
                trailing()
            }
            .padding(.top, 5)
            .padding(.horizontal, 2)
        }
        .padding(padding)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius / 2, y: shadow.y)
    }
}

/// A sticker-book placeholder: dashed outline where the sticker will go, number printed faintly.
struct EmptySlot: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            .background(Palette.slot.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(height: 64)
            .overlay(Mono(label, size: 13, spacing: 0.04, color: Palette.ghost))
            .frame(maxHeight: .infinity)
    }
}

/// Diagonal white sheen: CSS `gloss 4.2s` — translateX(-120% → 320%) over the first 55%.
struct GlossSweep: View {
    var body: some View {
        // 30 fps is smooth for a soft sheen and half the redraws on a 60 Hz screen.
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) / 4.2
            let p = min(t / 0.55, 1)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 70, height: 240)
                .rotationEffect(.degrees(18))
                .offset(x: -84 + 308 * eased, y: -40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bits

struct TierPill: View {
    let tier: Tier
    let fleet: Int
    /// The dex/model header uses a solid fill; the reveal sticker uses the pale gold wash.
    var solid = true

    var body: some View {
        let fill: Color = solid ? tier.color : (tier == .gold ? Palette.goldWash : tier.color.opacity(0.18))
        let ink: Color = solid ? (tier == .common ? Palette.ink : Palette.bg) : (tier == .gold ? Palette.goldInk : tier.color)
        Mono("\(tier.name) · \(fleet)", size: 10.5, weight: 700, spacing: 0.1, color: ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(fill, in: Capsule())
    }
}

struct ProgressBar: View {
    let fraction: Double
    var color: Color = Palette.yellow
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * min(fraction, 1)) : 0)
            }
        }
        .frame(height: height)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var valueColor: Color = Palette.ink
    var valueSize: CGFloat = 22
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mono(label, size: 10, spacing: 0.12)
            Text(value)
                .font(TaborFont.mono(valueSize, 700))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.vertical, valueSize * 0.15)
            if let caption {
                Text(caption)
                    .font(TaborFont.grotesk(11.5))
                    .foregroundStyle(Palette.sub)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 13)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline))
    }
}

struct KindTag: View {
    let kind: VehicleKind

    var body: some View {
        Mono(kind.name, size: 10, weight: 700, spacing: 0.1, color: Palette.sub)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Top row of every inner screen: grey mono label on the left, action on the right.
extension View {
    /// Rows slide out from under a pinned header instead of being cut off at a hard line.
    func softTopEdge(_ height: CGFloat = 16) -> some View {
        overlay(alignment: .top) {
            LinearGradient(colors: [Palette.bg, Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}

struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
            Spacer()
            trailing()
        }
        .padding(.top, 10)
        .padding(.horizontal, 22)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Mono(text, size: 10.5, spacing: 0.14)
    }
}

struct ScreenTitle: View {
    let text: String
    var size: CGFloat = 27

    var body: some View {
        Text(text)
            .font(TaborFont.grotesk(size, 700))
            .em(-0.03, size: size)
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
    }
}

extension Sticker where Trailing == EmptyView {
    init(number: Int, photo: String?, photoHeight: CGFloat = 70) {
        self.init(number: number, photo: photo, photoHeight: photoHeight) { EmptyView() }
    }
}

// MARK: - Die-cut stickers

/// A vehicle lifted off its photo with a white border (see StickerMaker), with a small
/// white number label stuck over its bottom-left corner. Falls back to the white photo
/// card when no cut-out exists (no subject found, or older catches).
struct DieCut<Badge: View>: View {
    let number: Int
    let sticker: String?
    let photo: String?
    var height: CGFloat = 78
    var tagSize: CGFloat = 12
    var maxPixel: Int = 500
    @ViewBuilder var badge: () -> Badge

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let sticker, let img = PhotoStore.thumbnail(sticker, maxPixel: maxPixel) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: height)
                    .shadow(color: .black.opacity(0.55), radius: height * 0.06, y: height * 0.06)
                    .padding(.bottom, tagSize * 0.7)
            } else {
                CatchPhoto(file: photo, maxPixel: maxPixel)
                    .frame(height: height * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(max(3, height * 0.05))
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 6)
                    .padding(.bottom, tagSize * 0.7)
            }
            NumberTag(number: number, size: tagSize) { badge() }
                .offset(x: -2)
        }
    }
}

extension DieCut where Badge == EmptyView {
    init(number: Int, sticker: String?, photo: String?, height: CGFloat = 78, tagSize: CGFloat = 12, maxPixel: Int = 500) {
        self.init(number: number, sticker: sticker, photo: photo, height: height, tagSize: tagSize, maxPixel: maxPixel) { EmptyView() }
    }
}

/// The little white label with the fleet number, like a second sticker on the first.
struct NumberTag<Badge: View>: View {
    let number: Int
    var size: CGFloat = 12
    @ViewBuilder var badge: () -> Badge

    var body: some View {
        HStack(spacing: size * 0.4) {
            Text(String(number))
                .font(TaborFont.mono(size, 700))
                .foregroundStyle(Palette.stickerInk)
            badge()
        }
        .padding(.vertical, size * 0.28)
        .padding(.horizontal, size * 0.5)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
        .rotationEffect(.degrees(-3))
    }
}

/// A stable little tilt per vehicle so a page of stickers looks hand-placed.
func stickerTilt(_ number: Int, range: Double = 4) -> Double {
    var x = UInt64(truncatingIfNeeded: number) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 29
    return (Double(x % 1000) / 1000 - 0.5) * 2 * range
}
