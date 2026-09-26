import SwiftUI

/// What goes out when you share a catch: a styled 4:5 card plus a one-line brag.
struct CatchShare {
    let image: UIImage
    let title: String
    let message: String

    /// Renders the card for a vehicle's latest sighting. Main actor: ImageRenderer needs it.
    @MainActor
    static func make(number: Int, model: VehicleModel?, sighting: Sighting, sticker: String?, photo: String?,
                     owned: Int) -> CatchShare? {
        let card = ShareCard(number: number, model: model, sighting: sighting, sticker: sticker, photo: photo, owned: owned)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3 // 360×450 pt → 1080×1350 px, Instagram's portrait size.
        guard let image = renderer.uiImage else { return nil }

        let name = model?.name ?? String(localized: "vehicle")
        let n = String(number)
        let emoji = model?.kind == .tram ? "🚋" : "🚌"
        let place = sighting.district ?? sighting.street
        let today = Calendar.current.isDateInToday(sighting.date)
        let day = ShareCard.day.string(from: sighting.date)
        // Whole sentences, not glued pieces, so each language can order them its own way.
        let caught = switch (place, today) {
        case (let place?, true): String(localized: "I caught \(name) #\(n) in \(place) today!")
        case (let place?, false): String(localized: "I caught \(name) #\(n) in \(place) on \(day)!")
        case (nil, true): String(localized: "I caught \(name) #\(n) today!")
        case (nil, false): String(localized: "I caught \(name) #\(n) on \(day)!")
        }
        return CatchShare(image: image, title: "\(name) #\(n)", message: "\(caught) \(emoji) — TABOR")
    }
}

struct ShareCard: View {
    let number: Int
    let model: VehicleModel?
    let sighting: Sighting
    let sticker: String?
    let photo: String?
    let owned: Int

    var body: some View {
        let tier = model?.tier ?? .common
        let accent = tier == .common ? Palette.yellow : tier.color

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TABOR")
                    .font(TaborFont.grotesk(15, 700))
                    .em(0.02, size: 15)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Mono("CAUGHT · \(Self.day.string(from: sighting.date).uppercased())", size: 9.5, spacing: 0.14,
                     color: accent)
            }

            Spacer(minLength: 0)

            artwork
                .rotationEffect(.degrees(stickerTilt(number, range: 4)))
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if let model {
                        Mono(model.kind.name, size: 9.5, weight: 700, spacing: 0.12, color: Palette.sub)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(Palette.track, in: RoundedRectangle(cornerRadius: 4))
                        TierPill(tier: model.tier, fleet: model.fleet)
                    }
                }
                Text(model?.name ?? String(localized: "Unknown model"))
                    .font(TaborFont.grotesk(28, 700))
                    .em(-0.03, size: 28)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let where_ = whereLine {
                    Mono(where_, size: 10.5, spacing: 0.1, color: Palette.sub)
                        .lineLimit(1)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
                .padding(.top, 16)
                .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline) {
                if let model {
                    (Text("\(owned)").foregroundStyle(Palette.ink)
                        + Text(" / \(model.fleet) IN MY BOOK").foregroundStyle(Palette.faint))
                        .font(TaborFont.mono(10, 600))
                        .em(0.08, size: 10)
                }
                Spacer()
                Mono("WARSAW ROLLING STOCK", size: 9, spacing: 0.12, color: Palette.faint)
            }
        }
        .padding(24)
        .frame(width: 360, height: 450)
        .background {
            let glow = Self.glow(tier)
            ZStack {
                Palette.bg
                // Bright right behind the sticker, falling off fast, so it reads as light rather
                // than a tinted wash. Fades to the same colour, not to black.
                RadialGradient(stops: [
                    .init(color: glow.color.opacity(glow.peak), location: 0),
                    .init(color: glow.color.opacity(glow.peak * 0.3), location: 0.45),
                    .init(color: glow.color.opacity(0), location: 1),
                ], center: .init(x: 0.5, y: 0.42), startRadius: 8, endRadius: 260)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The light behind the sticker. A faint yellow on near-black turns olive, so COMMON gets a
    /// plain white spotlight and GOLD a warmer amber; the other tiers keep their own colour.
    private static func glow(_ tier: Tier) -> (color: Color, peak: Double) {
        switch tier {
        case .common: (.white, 0.13)
        case .gold: (Color(hex: 0xFFA800), 0.30)
        case .legendary: (tier.color, 0.34)
        case .rare: (tier.color, 0.30)
        case .vintage: (tier.color, 0.32)
        case .onTest: (tier.color, 0.30)
        }
    }

    /// The die-cut sticker when there is one; otherwise the photo on white card stock.
    @ViewBuilder private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            if let sticker, let img = PhotoStore.thumbnail(sticker, maxPixel: 1400) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 312, maxHeight: 200)
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 12)
                    .padding(.bottom, 16)
            } else if let photo, let img = PhotoStore.thumbnail(photo, maxPixel: 1400) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 292, height: 184)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(7)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 12)
                    .padding(.bottom, 16)
            }
            // Tucked up onto the art, like a label slapped over the sticker's edge.
            NumberTag(number: number, size: 24) { EmptyView() }
                .offset(x: -6, y: -12)
        }
    }

    /// "MOKOTÓW · RAKOWIECKA · LINE 117", whatever we know.
    private var whereLine: String? {
        [sighting.district, sighting.street, sighting.line.map { String(localized: "LINE \($0)") }]
            .compactMap { $0?.uppercased() }
            .joined(separator: " · ")
            .nonEmpty
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()
}
