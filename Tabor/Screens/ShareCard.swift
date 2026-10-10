import SwiftUI

/// What goes out when you share a catch: a styled 4:5 card plus a one-line brag.
struct CatchShare {
    let image: UIImage
    let title: String
    let message: String

    /// Renders the card for the sighting a vehicle's page shows: the picked one, else the latest. Main actor: ImageRenderer needs it.
    /// `partner` is a coupled tram's other car, caught with it: "#1282+1281".
    @MainActor
    static func make(number: Int, model: VehicleModel?, sighting: Sighting, sticker: String?, photo: String?,
                     owned: Int, partner: Int? = nil, style: ShareCard.Style = .sticker) -> CatchShare? {
        let card = ShareCard(number: number, model: model, sighting: sighting, sticker: sticker, photo: photo, owned: owned,
                             style: style)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3 // 360×450 pt → 1080×1350 px, Instagram's portrait size.
        guard let image = renderer.uiImage else { return nil }

        let name = model?.name ?? String(localized: "vehicle")
        let n = partner.map { "\(number)+\($0)" } ?? FleetNumber.label(number)
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
    var style: Style = .sticker

    /// The die-cut sticker, or the whole photo you took (#63), for when the cut went wrong
    /// or the scene is the point.
    enum Style: String, CaseIterable {
        case sticker, photo
    }

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
                .rotationEffect(.degrees(stickerTilt(number, range: style == .photo ? 2.5 : 4)))
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
        case .works: (tier.color, 0.30)
        }
    }

    /// The die-cut sticker when there is one; otherwise the photo on white card stock.
    @ViewBuilder private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            if style == .sticker, let sticker, let img = PhotoStore.thumbnail(sticker, maxPixel: 1400) {
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
                    // A photo of its own fills the width; standing in for a missing sticker, it stays smaller.
                    .frame(width: style == .photo ? 298 : 292, height: style == .photo ? 224 : 184)
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

// MARK: - Badges

/// What goes out when you share a badge (#65): the medal with the stickers that earned it.
struct BadgeShare {
    let image: UIImage
    let title: String
    let message: String

    /// A vehicle on the card.
    struct Pick {
        let number: Int
        let sticker: String?
        let photo: String?
        let note: String?
    }

    /// Two rows of three; the rest become "+N MORE".
    static let fits = 6

    @MainActor
    static func make(badge: Achievement, sightings: [Sighting]) -> BadgeShare? {
        let picks = picks(for: badge, sightings: sightings)
        let card = BadgeShareCard(badge: badge, picks: picks,
                                  more: badge.proof.isEmpty ? 0 : badge.proof.count - picks.count,
                                  fromBook: badge.proof.isEmpty)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }

        // Whole sentences, and none that say "I earned" (Polish would need a gender for that).
        let text = badge.tiered
            ? String(localized: "I got \(badge.medal.name) in the \(badge.title) badge!")
            : String(localized: "I got the \(badge.title) badge!")
        return BadgeShare(image: image, title: badge.title, message: "\(text) 🏅 — TABOR")
    }

    /// The badge's own vehicles, rarest first, then newest. Badges that don't list any (counts
    /// like Collector) show the rarest of the whole book instead.
    @MainActor
    static func picks(for badge: Achievement, sightings: [Sighting]) -> [Pick] {
        struct Key: Hashable { let modelId: String; let number: Int }
        var newest: [Key: Date] = [:]
        for s in sightings {
            let k = Key(modelId: s.modelId, number: s.number)
            newest[k] = max(newest[k] ?? .distantPast, s.date)
        }
        let vehicles: [(key: Key, note: String?)] = badge.proof.isEmpty
            ? newest.keys.map { ($0, nil) }
            : badge.proof.map { (Key(modelId: $0.modelId, number: $0.number), $0.note) }
        let catalog = Fleet.catalog
        let rank = { (k: Key) in catalog.model(id: k.modelId).map { Wanted.huntRank($0.tier) } ?? Int.max }
        let ranked = vehicles.sorted { a, b in
            (rank(a.key), newest[b.key] ?? .distantPast) < (rank(b.key), newest[a.key] ?? .distantPast)
        }
        // One of each model before any repeats: six of the same bus make a dull card.
        var models = Set<String>()
        let firsts = ranked.filter { models.insert($0.key.modelId).inserted }
        let first = Set(firsts.map(\.key))
        let sorted = firsts + ranked.filter { !first.contains($0.key) }
        var picks: [Pick] = []
        for v in sorted where picks.count < fits {
            let sticker = sightings.sticker(number: v.key.number, modelId: v.key.modelId)
            let photo = sightings.photo(number: v.key.number, modelId: v.key.modelId)
            guard sticker != nil || photo != nil else { continue }
            picks.append(Pick(number: v.key.number, sticker: sticker, photo: photo, note: v.note))
        }
        return picks
    }
}

struct BadgeShareCard: View {
    let badge: Achievement
    let picks: [BadgeShare.Pick]
    let more: Int
    let fromBook: Bool

    var body: some View {
        let medal = badge.medal

        VStack(spacing: 0) {
            HStack {
                Text("TABOR")
                    .font(TaborFont.grotesk(15, 700))
                    .em(0.02, size: 15)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Mono(badge.kicker, size: 9.5, spacing: 0.14, color: medal.ink)
            }

            Medallion(badge: badge, size: 96)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                .padding(.top, 12)
            Text(badge.title)
                .font(TaborFont.grotesk(24, 700))
                .em(-0.02, size: 24)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 12)
            Text(badge.reached)
                .font(TaborFont.grotesk(13))
                .foregroundStyle(Palette.sub)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 3)
                .padding(.horizontal, 12)

            Spacer(minLength: 6)
            stickers
            Spacer(minLength: 6)

            Rectangle().fill(Palette.hairline).frame(height: 1)
                .padding(.bottom, 12)
            HStack(alignment: .firstTextBaseline) {
                if more > 0 {
                    Mono("+\(more) MORE", size: 10, weight: 600, spacing: 0.08, color: medal.ink)
                } else if fromBook && !picks.isEmpty {
                    Mono("FROM MY BOOK", size: 9, spacing: 0.12, color: Palette.faint)
                }
                Spacer()
                Mono("WARSAW ROLLING STOCK", size: 9, spacing: 0.12, color: Palette.faint)
            }
        }
        .padding(24)
        .frame(width: 360, height: 450)
        .background {
            ZStack {
                Palette.bg
                // The medal's own light, behind it.
                RadialGradient(stops: [
                    .init(color: medal.glow.opacity(0.32), location: 0),
                    .init(color: medal.glow.opacity(0.1), location: 0.45),
                    .init(color: medal.glow.opacity(0), location: 1),
                ], center: .init(x: 0.5, y: 0.22), startRadius: 8, endRadius: 280)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Up to two rows of three, a little crooked like they were stuck on by hand. A single row
    /// gets bigger stickers.
    private var stickers: some View {
        let height: CGFloat = picks.count > 3 ? 50 : 76
        let rows = stride(from: 0, to: picks.count, by: 3).map { Array(picks[$0..<min($0 + 3, picks.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .bottom, spacing: 12) {
                    // By position: a bus and a tram can share a number (the twins badge).
                    ForEach(rows[r].indices, id: \.self) { i in
                        let p = rows[r][i]
                        VStack(spacing: 3) {
                            DieCut(number: p.number, sticker: p.sticker, photo: p.photo, height: height,
                                   tagSize: 9.5, maxPixel: 600)
                                .rotationEffect(.degrees(stickerTilt(p.number, range: 5)))
                            if let note = p.note {
                                Mono(note, size: 8, weight: 600, spacing: 0.08, color: badge.medal.ink)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 96)
                    }
                }
            }
        }
    }
}
