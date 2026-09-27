import SwiftUI
import UIKit
import WidgetKit

// The widgets' faces. Compiled into the app too, so the widget tip can show them with your
// own book in them; each takes its family instead of reading it from the widget environment.

enum WidgetPalette {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let ink = Color(red: 0.969, green: 0.961, blue: 0.941)
    static let sub = Color(red: 0.541, green: 0.561, blue: 0.596)
    static let dim = Color(red: 0.443, green: 0.463, blue: 0.494)
    static let track = Color(red: 0.137, green: 0.149, blue: 0.169)
    static let yellow = Color(red: 1, green: 0.808, blue: 0)
    static let red = Color(red: 0.894, green: 0, blue: 0.169)
    static let green = Color(red: 0.137, green: 0.898, blue: 0.627)
    static let brass = Color(red: 0.824, green: 0.627, blue: 0.392)
    static let violet = Color(red: 0.718, green: 0.608, blue: 1)

    /// The number tag's colour for a tier; white for COMMON, like the stickers in the app.
    static func tag(_ name: String?) -> Color {
        switch name {
        case "LEGENDARY": red
        case "GOLD": yellow
        case "RARE": green
        case "VINTAGE": brass
        case "ON TEST": violet
        default: .white
        }
    }

    /// Tier labels and bars; COMMON goes grey, as in the book.
    static func tier(_ name: String) -> Color { name == "COMMON" ? sub : tag(name) }

    static func tierName(_ raw: String) -> String {
        switch raw {
        case "LEGENDARY": String(localized: "LEGENDARY", comment: "Rarity tier")
        case "GOLD": String(localized: "GOLD", comment: "Rarity tier")
        case "RARE": String(localized: "RARE", comment: "Rarity tier")
        case "COMMON": String(localized: "COMMON", comment: "Rarity tier")
        case "VINTAGE": String(localized: "VINTAGE", comment: "Rarity tier: tourist/museum vehicles")
        case "ON TEST": String(localized: "ON TEST", comment: "Rarity tier: vehicles on a trial run")
        default: raw
        }
    }
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

/// "12%", or one decimal while it's small enough that whole percents would read as zero.
func fleetPercent(_ caught: Int, of fleet: Int) -> String {
    guard fleet > 0, caught > 0 else { return 0.0.formatted(.percent.precision(.fractionLength(0))) }
    let v = Double(caught) / Double(fleet)
    return v.formatted(.percent.precision(.fractionLength(v < 0.1 ? 1 : 0)))
}

// MARK: - Pictures

/// A card's sticker, or its photo in a rounded frame, with the number tag in the corner.
struct CardPicture: View {
    let card: WidgetSnapshot.Card
    var tag: CGFloat = 10

    var body: some View {
        if let url = WidgetSnapshot.imageURL(card.image), let image = UIImage(contentsOfFile: url.path) {
            let pic = Image(uiImage: image).resizable()
            if card.cutout {
                pic.scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) { WidgetNumberTag(number: card.number, tier: card.tier, size: tag) }
            } else {
                pic.scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) { WidgetNumberTag(number: card.number, tier: card.tier, size: tag).padding(4) }
            }
        } else {
            WidgetEmptySlot()
        }
    }
}

struct WidgetNumberTag: View {
    let number: Int
    let tier: String?
    var size: CGFloat = 11

    var body: some View {
        Text(String(number))
            .font(mono(size, .bold))
            .foregroundStyle(tier == "LEGENDARY" ? WidgetPalette.ink : .black)
            .padding(.horizontal, size * 0.45)
            .padding(.vertical, size * 0.18)
            .background(WidgetPalette.tag(tier), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A dashed slot, like an empty page in the book.
struct WidgetEmptySlot: View {
    var text: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(WidgetPalette.sub.opacity(0.5))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "bus.fill")
                    if let text {
                        Text(text).font(mono(9.5)).multilineTextAlignment(.center).padding(.horizontal, 8)
                    }
                }
                .foregroundStyle(WidgetPalette.sub)
            }
    }
}

// MARK: - Your book (streak and progress)

struct ProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let image: UIImage?

    var streak: Int { snapshot.streak(at: date) }
    var atRisk: Bool { snapshot.streakAtRisk(at: date) }
}

struct ProgressWidgetView: View {
    let entry: ProgressEntry
    let family: WidgetFamily

    private var s: WidgetSnapshot { entry.snapshot }
    private var progress: String { "\(s.caught.formatted()) / \(s.fleet.formatted())" }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(entry.streak)-day streak · \(progress)", systemImage: "flame.fill")
        case .accessoryCircular:
            Gauge(value: Double(s.caught), in: 0...Double(max(s.fleet, 1))) {
                Image(systemName: "flame.fill")
            } currentValueLabel: {
                Text("\(entry.streak)").font(.system(.title3, design: .monospaced, weight: .bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(streakText, systemImage: "flame.fill")
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                    .widgetAccentable()
                Text("\(progress) caught").font(.system(.caption, design: .monospaced))
                if let number = s.latestNumber {
                    Text("Last: \(String(number)) \(s.latestModel ?? "")").font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(spacing: 14) {
                sticker.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    streakBlock
                    Spacer(minLength: 0)
                    caughtBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    streakBadge
                    Spacer()
                }
                sticker.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(progress)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(WidgetPalette.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
    }

    private var streakText: String { String(localized: "\(entry.streak) DAYS") }

    private var streakBadge: some View {
        Label(String(entry.streak), systemImage: "flame.fill")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(entry.streak > 0 ? WidgetPalette.yellow : WidgetPalette.sub)
    }

    private var streakBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(streakText, systemImage: "flame.fill")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.streak > 0 ? WidgetPalette.yellow : WidgetPalette.sub)
            Text(entry.atRisk ? "CATCH ONE TODAY" : entry.streak > 0 ? "STREAK" : "NO STREAK")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.atRisk ? WidgetPalette.red : WidgetPalette.sub)
        }
    }

    private var caughtBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(progress)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(s.latestNumber.map { String(localized: "LAST: \(String($0)) · \((s.latestModel ?? "").uppercased())") }
                 ?? String(localized: "OF THE FLEET CAUGHT"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(WidgetPalette.sub)
                .lineLimit(1)
        }
    }

    /// The die-cut sticker, the photo in a rounded frame, or an empty dashed slot.
    @ViewBuilder private var sticker: some View {
        if let image = entry.image {
            let pic = Image(uiImage: image).resizable()
            if s.imageIsCutout {
                pic.scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .overlay(alignment: .bottomTrailing) { numberTag }
            } else {
                pic.scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) { numberTag.padding(4) }
            }
        } else {
            WidgetEmptySlot()
        }
    }

    @ViewBuilder private var numberTag: some View {
        if let number = s.latestNumber {
            WidgetNumberTag(number: number, tier: s.latestTier)
        }
    }
}

// MARK: - Latest catches

struct RecentWidgetView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    private var cards: [WidgetSnapshot.Card] { snapshot.recent ?? [] }
    private var large: Bool { family == .systemLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 12 : 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("LATEST CATCHES").font(mono(10)).foregroundStyle(WidgetPalette.sub)
                Spacer()
                Text("\(snapshot.caught.formatted()) / \(snapshot.fleet.formatted())")
                    .font(mono(10, .bold)).foregroundStyle(WidgetPalette.ink)
            }
            if cards.isEmpty {
                WidgetEmptySlot(text: String(localized: "Your catches land here"))
            } else if large {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if i < cards.count { captioned(cards[i]) } else { Color.clear }
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        if i < cards.count {
                            Link(destination: cards[i].url) { CardPicture(card: cards[i], tag: 9) }
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func captioned(_ card: WidgetSnapshot.Card) -> some View {
        Link(destination: card.url) {
            VStack(alignment: .leading, spacing: 5) {
                CardPicture(card: card, tag: 10)
                HStack(spacing: 5) {
                    Circle().fill(WidgetPalette.tier(card.tier)).frame(width: 5, height: 5)
                    Text(card.model).font(.system(size: 11, weight: .semibold)).foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Rarity sets

struct RarityWidgetView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    private var tiers: [WidgetSnapshot.TierCount] { snapshot.tiers ?? [] }

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SETS").font(mono(10)).foregroundStyle(WidgetPalette.sub)
                    Spacer(minLength: 0)
                    Text(fleetPercent(snapshot.caught, of: snapshot.fleet))
                        .font(mono(30, .bold)).foregroundStyle(WidgetPalette.yellow)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("OF THE FLEET").font(mono(9.5)).foregroundStyle(WidgetPalette.sub)
                    Text("\(snapshot.caught.formatted()) / \(snapshot.fleet.formatted())")
                        .font(mono(11, .bold)).foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.7).lineLimit(1)
                        .padding(.top, 4)
                }
                .frame(width: 104, alignment: .leading)
                rows
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("SETS").font(mono(10)).foregroundStyle(WidgetPalette.sub)
                    Spacer()
                    Text(fleetPercent(snapshot.caught, of: snapshot.fleet))
                        .font(mono(10, .bold)).foregroundStyle(WidgetPalette.yellow)
                }
                Spacer(minLength: 8)
                rows
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 11 : 8) {
            ForEach(tiers, id: \.tier) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(WidgetPalette.tierName(t.tier)).font(mono(9.5, .bold))
                            .foregroundStyle(WidgetPalette.tier(t.tier))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text("\(t.caught.formatted())/\(t.fleet.formatted())").font(mono(9.5, .semibold))
                            .foregroundStyle(t.caught > 0 ? WidgetPalette.ink : WidgetPalette.dim)
                            .lineLimit(1)
                    }
                    bar(t)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(_ t: WidgetSnapshot.TierCount) -> some View {
        GeometryReader { geo in
            let share = t.fleet > 0 ? Double(t.caught) / Double(t.fleet) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track)
                // A sliver for anything caught at all, so one bus out of 1,500 still shows.
                Capsule().fill(WidgetPalette.tier(t.tier))
                    .frame(width: t.caught > 0 ? max(4, geo.size.width * min(share, 1)) : 0)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Sticker shuffle

struct ShuffleEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let card: WidgetSnapshot.Card?
}

struct ShuffleWidgetView: View {
    let entry: ShuffleEntry
    let family: WidgetFamily

    var body: some View {
        if let card = entry.card {
            if family == .systemMedium {
                HStack(spacing: 14) {
                    CardPicture(card: card, tag: 11)
                    VStack(alignment: .leading, spacing: 3) {
                        tierLabel(card)
                        Text("#\(String(card.number))").font(mono(24, .bold)).foregroundStyle(WidgetPalette.ink)
                        Text(card.model).font(.system(size: 13, weight: .semibold)).foregroundStyle(WidgetPalette.ink)
                            .lineLimit(2).minimumScaleFactor(0.85)
                        Spacer(minLength: 4)
                        Text("FIRST CAUGHT \(card.firstSeen.formatted(.dateTime.day().month(.abbreviated)).uppercased())")
                            .font(mono(9)).foregroundStyle(WidgetPalette.sub).lineLimit(1).minimumScaleFactor(0.8)
                        Text(card.times == 1 ? String(localized: "SEEN ONCE") : String(localized: "SEEN \(card.times) TIMES"))
                            .font(mono(9)).foregroundStyle(WidgetPalette.sub)
                    }
                    .frame(width: 124, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    tierLabel(card)
                    CardPicture(card: card, tag: 10)
                    Text(card.model).font(.system(size: 12, weight: .semibold)).foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        } else {
            WidgetEmptySlot(text: String(localized: "Your stickers get shuffled here"))
        }
    }

    private func tierLabel(_ card: WidgetSnapshot.Card) -> some View {
        Text(WidgetPalette.tierName(card.tier)).font(mono(9.5, .bold)).foregroundStyle(WidgetPalette.tier(card.tier))
    }
}

extension WidgetSnapshot {
    /// The shuffle's card for an hour: it walks the pile one card an hour, so the same card
    /// comes back only once the whole pile has had its turn.
    func shuffleCard(at date: Date) -> Card? {
        guard let pile, !pile.isEmpty else { return nil }
        let hour = Int(date.timeIntervalSince1970 / 3600)
        return pile[hour % pile.count]
    }
}
