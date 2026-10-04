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
    static let card = Color(red: 0.078, green: 0.086, blue: 0.102)
    static let thumb = Color(red: 0.106, green: 0.118, blue: 0.137)
    static let routeInk = Color(red: 0.788, green: 0.804, blue: 0.827)

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
    /// The number tag's size; 0 leaves it off.
    var tag: CGFloat = 10

    var body: some View {
        if let url = WidgetSnapshot.imageURL(card.image), let image = UIImage(contentsOfFile: url.path) {
            let pic = Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated)
            if card.cutout {
                pic.scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) { if tag > 0 { WidgetNumberTag(number: card.number, tier: card.tier, size: tag) } }
            } else {
                pic.scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) { if tag > 0 { WidgetNumberTag(number: card.number, tier: card.tier, size: tag).padding(4) } }
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
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let text = Text(String(number)).font(mono(size, .bold))
            .padding(.horizontal, size * 0.45)
            .padding(.vertical, size * 0.18)
        // Clear and tinted Home Screens paint everything one colour, so dark text on a filled
        // tag would vanish into it: an outlined tag there instead.
        if mode == .accented {
            text.overlay(RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1))
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        } else {
            text.foregroundStyle(tier == "LEGENDARY" ? WidgetPalette.ink : .black)
                .background(WidgetPalette.tag(tier), in: RoundedRectangle(cornerRadius: 4))
        }
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
    private var share: Double { s.fleet > 0 ? Double(s.caught) / Double(s.fleet) : 0 }

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
                Label(String(localized: "\(entry.streak) DAYS"), systemImage: "flame.fill")
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                    .widgetAccentable()
                Text("\(progress) caught").font(.system(.caption, design: .monospaced))
                if let number = s.latestNumber {
                    Text("Last: \(String(number)) \(s.latestModel ?? "")").font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            medium
        default:
            if entry.atRisk { atRisk } else { small }
        }
    }

    /// The share of the fleet up top, the counts underneath.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetKey(text: String(localized: "YOUR BOOK"))
            Text(sharePercent(share)).font(.system(size: 42, weight: .medium)).tracking(-1.5)
                .foregroundStyle(WidgetPalette.yellow).minimumScaleFactor(0.6).lineLimit(1)
                .padding(.top, 4)
            WidgetMeter(share: share).padding(.top, 6)
            Spacer(minLength: 6)
            row(String(localized: "CAUGHT"), caughtText)
            row(String(localized: "MODELS"), modelsText)
            row(String(localized: "STREAK"), streakText, last: true)
        }
    }

    /// Yesterday kept the streak alive; today hasn't yet. The clock runs to midnight.
    private var atRisk: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: entry.date)
        let midnight = cal.date(byAdding: .day, value: 1, to: today) ?? entry.date
        return VStack(alignment: .leading, spacing: 0) {
            WidgetKey(text: String(localized: "STREAK AT RISK"), color: WidgetPalette.red)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "flame.fill").font(.system(size: 18)).foregroundStyle(WidgetPalette.yellow)
                Text("\(entry.streak)").font(.system(size: 40, weight: .medium)).tracking(-1.5).foregroundStyle(WidgetPalette.ink)
                WidgetKey(text: String(localized: "DAYS"), color: WidgetPalette.ink)
            }
            .padding(.top, 4)
            Spacer(minLength: 4)
            WeekStrip(today: today, streak: entry.streak)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline) {
                Text(timerInterval: entry.date...midnight, countsDown: true)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(WidgetPalette.ink)
                Spacer(minLength: 2)
                WidgetKey(text: String(localized: "LEFT"))
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetKey(text: String(localized: "LAST STICKER"))
                sticker.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let last = s.lastCatch {
                    WidgetKey(text: [last.formatted(.dateTime.day().month(.abbreviated)).uppercased(), latestLine]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            .frame(width: 136)
            VStack(spacing: 0) {
                row(String(localized: "CAUGHT"), caughtText, size: 15)
                row(String(localized: "FLEET"), Text(sharePercent(share)).foregroundStyle(WidgetPalette.yellow), size: 15)
                row(String(localized: "MODELS"), modelsText, size: 15)
                row(String(localized: "STREAK"), streakText, size: 15, last: true)
            }
        }
    }

    private var caughtText: Text {
        Text(s.caught.formatted()).foregroundStyle(WidgetPalette.ink) + Text("/\(s.fleet.formatted())").foregroundStyle(WidgetPalette.sub)
    }

    private var modelsText: Text {
        Text("\(s.models ?? 0)").foregroundStyle(WidgetPalette.ink) + Text("/\(s.modelsTotal ?? 0)").foregroundStyle(WidgetPalette.sub)
    }

    private var streakText: Text {
        if entry.atRisk {
            return Text("\(entry.streak) · ").foregroundStyle(WidgetPalette.ink) + Text("TODAY!").foregroundStyle(WidgetPalette.red)
        }
        let best = s.bestStreak ?? 0
        return Text("\(entry.streak)").foregroundStyle(entry.streak > 0 ? WidgetPalette.yellow : WidgetPalette.sub)
            + Text(best > entry.streak ? " · BEST \(best)" : "").foregroundStyle(WidgetPalette.sub)
    }

    /// The latest catch's line, when the newest card is that catch.
    private var latestLine: String? {
        guard let card = s.recent?.first, card.number == s.latestNumber, let line = card.line else { return nil }
        return String(localized: "LINE \(line)")
    }

    private func row(_ label: String, _ value: Text, size: CGFloat = 11.5, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                WidgetKey(text: label)
                Spacer(minLength: 4)
                value.font(.system(size: size, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, size > 12 ? 7 : 4)
            if !last { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        }
    }

    /// The die-cut sticker, the photo in a rounded frame, or an empty dashed slot.
    @ViewBuilder private var sticker: some View {
        if let image = entry.image {
            let pic = Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated)
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
            WidgetNumberTag(number: number, tier: s.latestTier, size: 10)
        }
    }
}

/// A thin progress track, with a sliver for anything caught at all.
struct WidgetMeter: View {
    let share: Double
    var color: Color = WidgetPalette.yellow

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track)
                Capsule().fill(color).frame(width: share > 0 ? max(4, geo.size.width * min(share, 1)) : 0)
            }
        }
        .frame(height: 4)
    }
}

/// The last seven days: the streak's in yellow, today a dashed red box waiting for a catch.
private struct WeekStrip: View {
    let today: Date
    let streak: Int

    var body: some View {
        var cal = Calendar.current
        cal.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let back = 6 - i
                let day = cal.date(byAdding: .day, value: -back, to: today) ?? today
                VStack(spacing: 3) {
                    Group {
                        if back == 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(WidgetPalette.red, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(back <= streak ? WidgetPalette.yellow : WidgetPalette.track)
                        }
                    }
                    .frame(height: 14)
                    Text(symbols[cal.component(.weekday, from: day) - 1].uppercased())
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(WidgetPalette.sub)
                }
            }
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
        VStack(alignment: .leading, spacing: large ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                WidgetKey(text: String(localized: "LATEST CATCHES"))
                Spacer()
                Text("\(snapshot.caught.formatted()) / \(snapshot.fleet.formatted())")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(WidgetPalette.ink)
            }
            if cards.isEmpty {
                WidgetEmptySlot(text: String(localized: "Your catches land here"))
            } else if large {
                // Rows share the height, so a short log doesn't leave a hole at the bottom.
                VStack(spacing: 0) {
                    ForEach(Array(cards.prefix(5).enumerated()), id: \.offset) { i, card in
                        Link(destination: card.url) { logRow(card).frame(maxHeight: .infinity) }
                        if i < min(cards.count, 5) - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                    }
                }
                .frame(maxHeight: cards.count >= 4 ? .infinity : nil)
                if cards.count < 4 { Spacer(minLength: 0) }
            } else {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        if i < cards.count {
                            Link(destination: cards[i].url) { column(cards[i]) }
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func column(_ card: WidgetSnapshot.Card) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CardPicture(card: card, tag: 9)
            Text(card.model).font(.system(size: 11, weight: .medium)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
            WidgetKey(text: when(card), size: 8.5)
        }
    }

    private func logRow(_ card: WidgetSnapshot.Card) -> some View {
        HStack(spacing: 12) {
            CardPicture(card: card, tag: 0).frame(width: 72, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    WidgetNumberTag(number: card.number, tier: card.tier, size: 10)
                    Text(card.model).font(.system(size: 13, weight: .medium)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                }
                WidgetKey(text: [card.place?.uppercased(), card.line.map { String(localized: "LINE \($0)") }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            Spacer(minLength: 4)
            if let seen = card.lastSeen {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(seen.formatted(.dateTime.hour().minute())).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(WidgetPalette.ink)
                    WidgetKey(text: seen.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func when(_ card: WidgetSnapshot.Card) -> String {
        guard let seen = card.lastSeen else { return "" }
        return "\(seen.formatted(.dateTime.day().month(.abbreviated)).uppercased()) · \(seen.formatted(.dateTime.hour().minute()))"
    }
}

// MARK: - Rarity sets

struct RarityWidgetView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    private var tiers: [WidgetSnapshot.TierCount] { snapshot.tiers ?? [] }

    var body: some View {
        if family == .systemMedium {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetKey(text: String(localized: "RARITY SETS"))
                    Spacer()
                    Text(fleetPercent(snapshot.caught, of: snapshot.fleet))
                        .font(mono(10, .bold)).foregroundStyle(WidgetPalette.yellow)
                }
                HStack(spacing: 10) {
                    ForEach(tiers, id: \.tier) { column($0) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetKey(text: String(localized: "SETS"))
                    Spacer()
                    Text(fleetPercent(snapshot.caught, of: snapshot.fleet))
                        .font(mono(10, .bold)).foregroundStyle(WidgetPalette.yellow)
                }
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 8) {
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
                            WidgetMeter(share: t.fleet > 0 ? Double(t.caught) / Double(t.fleet) : 0, color: WidgetPalette.tier(t.tier))
                        }
                    }
                }
            }
        }
    }

    /// One tier as a scoreboard: caught, out of what, and a gauge filling from the bottom.
    private func column(_ t: WidgetSnapshot.TierCount) -> some View {
        let share = t.fleet > 0 ? Double(t.caught) / Double(t.fleet) : 0
        return VStack(alignment: .leading, spacing: 3) {
            Text(WidgetPalette.tierName(t.tier)).font(mono(9, .bold)).foregroundStyle(WidgetPalette.tier(t.tier))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(t.caught.formatted()).font(mono(21, .bold)).foregroundStyle(t.caught > 0 ? WidgetPalette.ink : WidgetPalette.dim)
                .lineLimit(1).minimumScaleFactor(0.6)
            WidgetKey(text: String(localized: "OF \(t.fleet.formatted())"), size: 8.5)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(WidgetPalette.thumb)
                    // A sliver for anything caught at all, so one bus out of 1,500 still shows.
                    Rectangle().fill(WidgetPalette.tier(t.tier))
                        .frame(height: t.caught > 0 ? max(4, geo.size.height * min(share, 1)) : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            WidgetKey(text: sharePercent(share), size: 8.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    CardPicture(card: card, tag: 11).frame(width: 146)
                    VStack(alignment: .leading, spacing: 0) {
                        tierLabel(card)
                        Text(card.model).font(.system(size: 16, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                            .lineLimit(2).minimumScaleFactor(0.85).padding(.top, 3)
                        Spacer(minLength: 4)
                        row(String(localized: "FIRST"), card.firstSeen.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                        row(String(localized: "SEEN"), "\(card.times)×")
                        if let line = card.line { row(String(localized: "LINE"), line) }
                        if let owned = card.owned, let fleet = card.fleet { row(String(localized: "MODEL"), "\(owned) / \(fleet)", last: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    tierLabel(card)
                    CardPicture(card: card, tag: 10)
                    Text(card.model).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    WidgetKey(text: [card.times == 1 ? String(localized: "SEEN ONCE") : String(localized: "SEEN \(card.times)×"),
                                     card.line.map { String(localized: "LINE \($0)") }].compactMap { $0 }.joined(separator: " · "))
                }
            }
        } else {
            WidgetEmptySlot(text: String(localized: "Your stickers get shuffled here"))
        }
    }

    /// "GOLD · 1/34": its rarity and how many of its model you have.
    private func tierLabel(_ card: WidgetSnapshot.Card) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(WidgetPalette.tierName(card.tier)).font(mono(9.5, .bold)).foregroundStyle(WidgetPalette.tier(card.tier))
            Spacer(minLength: 4)
            if let owned = card.owned, let fleet = card.fleet { WidgetKey(text: "\(owned)/\(fleet)") }
        }
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                WidgetKey(text: label)
                Spacer(minLength: 4)
                Text(value).font(mono(11, .bold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
            }
            .padding(.vertical, 4)
            if !last { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        }
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
