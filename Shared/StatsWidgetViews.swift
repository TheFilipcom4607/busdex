import SwiftUI
import UIKit
import WidgetKit

// The Stats and Memories widgets' faces: big numbers first, small mono labels, like a
// flight log. Compiled into the app too, like WidgetViews.swift.

private func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

/// The headline number: big, tight, not monospaced.
private func big(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }

/// A small caps label in the widgets' grey.
struct WidgetKey: View {
    let text: String
    var color: Color = WidgetPalette.sub
    var size: CGFloat = 9

    var body: some View {
        // Shrinks a touch rather than cut a long translation ("NAJLEPSZA SERIA").
        Text(text).font(mono(size, .medium)).tracking(size * 0.08).foregroundStyle(color).lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

/// "3.0%", or "+0.1%" for what a month or year added.
func sharePercent(_ v: Double, signed: Bool = false) -> String {
    let text = v.formatted(.percent.precision(.fractionLength(v < 0.1 ? 1 : 0)))
    return signed && v > 0 ? "+" + text : text
}

/// Bars along the bottom: days of a month or months of a year, the busiest in yellow.
struct WidgetBars: View {
    let values: [Int]
    var spacing: CGFloat = 2

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(values[i] == top && values[i] > 0 ? WidgetPalette.yellow
                              : values[i] > 0 ? WidgetPalette.sub : WidgetPalette.track)
                        .frame(height: max(2, geo.size.height * Double(values[i]) / Double(top)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// A sticker (or photo) from the App Group, with its number tag; nil image draws nothing.
struct WidgetPicture: View {
    let image: String?
    let cutout: Bool
    let number: Int
    let tier: String
    /// The number tag's size; 0 leaves it off.
    var tag: CGFloat = 10

    var body: some View {
        if let name = image, let url = WidgetSnapshot.imageURL(name), let ui = UIImage(contentsOfFile: url.path) {
            let pic = Image(uiImage: ui).resizable().widgetAccentedRenderingMode(.desaturated)
            if cutout {
                pic.scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) { if tag > 0 { WidgetNumberTag(number: number, tier: tier, size: tag) } }
            } else {
                pic.scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) { if tag > 0 { WidgetNumberTag(number: number, tier: tier, size: tag).padding(4) } }
            }
        }
    }
}

// MARK: - Stats

struct StatsWidgetView: View {
    let summary: WidgetSnapshot.PeriodSummary?
    /// For all time's ring: caught out of the fleet.
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    private var s: WidgetSnapshot.PeriodSummary {
        summary ?? WidgetSnapshot.PeriodSummary(kind: .month, label: "", catches: 0, vehicles: 0, newVehicles: 0, models: 0,
                                                newModels: 0, lines: 0, daysOut: 0, bestStreak: 0, bestDay: 0,
                                                fleetShare: 0, topLine: nil, bars: [], topModels: [], rarest: nil)
    }
    private var isAll: Bool { s.kind == .all }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(s.catches) caught · \(s.label.capitalized)")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(s.catches.formatted()).font(.system(.title3, design: .monospaced, weight: .bold))
                    .minimumScaleFactor(0.6)
                Text(shortLabel).font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(isAll ? String(localized: "\(s.catches) CAUGHT") : String(localized: "\(s.catches) IN \(s.label)"))
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                    .widgetAccentable()
                Text(String(localized: "\(s.newVehicles) new · \(s.newModels) models")).font(.system(.caption, design: .monospaced))
                Text(String(localized: "best day \(s.bestDay)")).font(.system(.caption, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium: medium
        case .systemLarge: large
        default: isAll ? AnyView(ring) : AnyView(small)
        }
    }

    private var shortLabel: String {
        switch s.kind {
        case .all: String(localized: "ALL")
        case .year: s.label
        case .month: String(s.label.prefix(3))
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetKey(text: s.label)
            Text(s.catches.formatted()).font(big(50)).tracking(-2).foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.5).lineLimit(1)
                .padding(.top, 6)
            WidgetKey(text: String(localized: "CATCHES"), color: WidgetPalette.ink)
            Spacer(minLength: 8)
            WidgetBars(values: s.bars).frame(height: 32)
        }
    }

    /// All time on a small widget: how much of the fleet is in the book, as a ring.
    private var ring: some View {
        VStack(spacing: 0) {
            WidgetKey(text: s.label).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            ZStack {
                Circle().stroke(WidgetPalette.track, lineWidth: 8)
                Circle().trim(from: 0, to: max(0.02, min(s.fleetShare, 1)))
                    .stroke(WidgetPalette.yellow, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(sharePercent(s.fleetShare)).font(mono(18, .bold)).foregroundStyle(WidgetPalette.yellow)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    WidgetKey(text: String(localized: "OF FLEET"), size: 8)
                }
                .padding(.horizontal, 10)
            }
            .frame(width: 88, height: 88)
            Spacer(minLength: 4)
            (Text(snapshot.caught.formatted()).foregroundStyle(WidgetPalette.ink)
                + Text(" / \(snapshot.fleet.formatted())").foregroundStyle(WidgetPalette.sub))
                .font(mono(11, .bold))
        }
    }

    private var tiles: [(String, String, Color)] {
        [
            (s.newVehicles.formatted(), isAll ? String(localized: "VEHICLES") : String(localized: "NEW VEHICLES"), WidgetPalette.ink),
            ((isAll ? s.models : s.newModels).formatted(), isAll ? String(localized: "MODELS") : String(localized: "NEW MODELS"), WidgetPalette.ink),
            (sharePercent(s.fleetShare, signed: !isAll), String(localized: "FLEET"), WidgetPalette.yellow),
            (String(localized: "\(s.bestStreak)d"), String(localized: "BEST STREAK"), WidgetPalette.ink),
        ]
    }

    private var medium: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    WidgetKey(text: s.label)
                    Text(s.catches.formatted()).font(big(52)).tracking(-2).foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .padding(.top, 6)
                    WidgetKey(text: String(localized: "CATCHES"), color: WidgetPalette.ink)
                }
                .frame(width: 116, alignment: .leading)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { tile(tiles[0]); tile(tiles[1]) }
                    GridRow { tile(tiles[2]); tile(tiles[3]) }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            WidgetBars(values: s.bars, spacing: 3).frame(height: 24)
        }
    }

    private func tile(_ t: (String, String, Color)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t.0).font(mono(16, .bold)).foregroundStyle(t.2).lineLimit(1).minimumScaleFactor(0.7)
            WidgetKey(text: t.1, size: 8.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("TABOR").font(mono(11, .bold)).tracking(2).foregroundStyle(WidgetPalette.ink)
                Spacer()
                WidgetKey(text: s.label)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.catches.formatted()).font(big(56)).tracking(-2).foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    WidgetKey(text: String(localized: "CATCHES"), color: WidgetPalette.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(sharePercent(s.fleetShare, signed: !isAll)).font(mono(22, .bold)).foregroundStyle(WidgetPalette.yellow)
                    WidgetKey(text: String(localized: "OF THE FLEET"))
                }
            }
            HStack(spacing: 1) {
                box(isAll ? s.vehicles : s.newVehicles, isAll ? String(localized: "VEHICLES") : String(localized: "NEW VEHICLES"))
                box(isAll ? s.models : s.newModels, isAll ? String(localized: "MODELS") : String(localized: "NEW MODELS"))
                box(s.lines, String(localized: "LINES"))
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !s.topModels.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    WidgetKey(text: String(localized: "TOP MODELS"))
                    ForEach(s.topModels, id: \.name) { m in
                        HStack(spacing: 8) {
                            Text(m.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                                .lineLimit(1).frame(width: 138, alignment: .leading)
                            bar(Double(m.count) / Double(max(s.topModels[0].count, 1)), color: WidgetPalette.tier(m.tier))
                            Text("\(m.count)").font(mono(11, .bold)).foregroundStyle(WidgetPalette.ink)
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }
            // Fills what's left, so the large widget has no hole whatever the counts.
            WidgetBars(values: s.bars, spacing: 3).frame(minHeight: 14, maxHeight: .infinity).layoutPriority(-1)
            if let r = s.rarest {
                Divider().overlay(Color.white.opacity(0.07))
                HStack(spacing: 10) {
                    WidgetPicture(image: r.image, cutout: r.cutout, number: r.number, tier: r.tier, tag: 0)
                        .frame(width: 62, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        WidgetKey(text: String(localized: "RAREST · \(WidgetPalette.tierName(r.tier))"), color: WidgetPalette.tier(r.tier))
                        Text("#\(FleetNumber.label(r.number)) \(r.model)").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetPalette.ink).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let owned = r.owned, let fleet = r.fleet {
                        Text("\(owned)/\(fleet)").font(mono(11, .bold)).foregroundStyle(WidgetPalette.tier(r.tier))
                    }
                }
            }
        }
    }

    private func box(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(mono(15, .bold)).foregroundStyle(WidgetPalette.ink)
            WidgetKey(text: label, size: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WidgetPalette.card)
    }

    private func bar(_ share: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track)
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(share, 1)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Memories

struct MemoryWidgetView: View {
    let memory: WidgetSnapshot.MemoryCard?
    let family: WidgetFamily

    var body: some View {
        if let m = memory {
            switch family {
            case .systemMedium: medium(m)
            case .systemLarge: large(m)
            default: small(m)
            }
        } else {
            WidgetEmptySlot(text: String(localized: "Your catches come back here"))
        }
    }

    static func headline(_ kind: WidgetSnapshot.MemoryCard.Kind, short: Bool) -> String {
        switch kind {
        case .yearAgo: short ? String(localized: "A YEAR AGO") : String(localized: "ONE YEAR AGO TODAY")
        case .monthAgo: short ? String(localized: "A MONTH AGO") : String(localized: "ONE MONTH AGO TODAY")
        case .weekAgo: short ? String(localized: "A WEEK AGO") : String(localized: "ONE WEEK AGO TODAY")
        case .first: String(localized: "WHERE IT STARTED")
        case .random: String(localized: "FROM YOUR BOOK")
        }
    }

    private func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
    }

    private func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }

    /// The number, big, where a vehicle with no picture would have its sticker.
    private func numberArt(_ m: WidgetSnapshot.MemoryCard, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(FleetNumber.label(m.number))").font(big(size)).tracking(-1).foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(m.model).font(.system(size: 13, weight: .medium)).foregroundStyle(WidgetPalette.ink).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func small(_ m: WidgetSnapshot.MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetKey(text: Self.headline(m.kind, short: true), color: WidgetPalette.yellow)
            if m.image != nil {
                WidgetPicture(image: m.image, cutout: m.cutout, number: m.number, tier: m.tier, tag: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.model).font(.system(size: 13, weight: .medium)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                    WidgetKey(text: [day(m.date), m.line.map { String(localized: "LINE \($0)") }].compactMap { $0 }.joined(separator: " · "))
                }
            } else {
                numberArt(m, size: 36)
                WidgetKey(text: day(m.date))
                WidgetKey(text: [time(m.date), m.place?.uppercased()].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private func medium(_ m: WidgetSnapshot.MemoryCard) -> some View {
        HStack(spacing: 12) {
            Group {
                if m.image != nil {
                    WidgetPicture(image: m.image, cutout: m.cutout, number: m.number, tier: m.tier, tag: 11)
                } else {
                    numberArt(m, size: 34)
                }
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 3) {
                WidgetKey(text: Self.headline(m.kind, short: false), color: WidgetPalette.yellow)
                Text(m.model).font(.system(size: 16, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                    .lineLimit(2).minimumScaleFactor(0.85).padding(.top, 3)
                Text("\(day(m.date)) · \(time(m.date))").font(mono(10.5, .medium)).foregroundStyle(WidgetPalette.routeInk)
                Spacer(minLength: 4)
                if let place = placeLine(m) { iconLine("mappin.and.ellipse", place) }
                if let weather = weatherLine(m) { iconLine(WidgetWeather.symbol(m.weatherCode), weather) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ m: WidgetSnapshot.MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                WidgetKey(text: Self.headline(m.kind, short: false), color: WidgetPalette.yellow, size: 10)
                Spacer()
                WidgetKey(text: day(m.date))
            }
            Group {
                if m.image != nil {
                    WidgetPicture(image: m.image, cutout: m.cutout, number: m.number, tier: m.tier, tag: 13)
                } else {
                    Text("#\(FleetNumber.label(m.number))").font(big(64)).tracking(-2).foregroundStyle(WidgetPalette.ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The picture takes whatever height is left, so nothing below floats.
            .frame(minHeight: 90, maxHeight: .infinity)
            .padding(.top, 8)
            .layoutPriority(-1)
            Text(m.model).font(.system(size: 20, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                .lineLimit(1).minimumScaleFactor(0.8).padding(.top, 8)
            HStack(spacing: 1) {
                box(time(m.date), String(localized: "TIME"))
                box(m.line ?? "–", String(localized: "LINE"))
                box(m.temperature.map { "\(Int($0.rounded()))°" } ?? "–", WidgetWeather.word(m.weatherCode) ?? String(localized: "WEATHER"))
                box("\(m.times)×", String(localized: "SEEN"))
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 10)
            if let place = placeLine(m) {
                WidgetKey(text: place, size: 10).padding(.top, 8)
            }
            Divider().overlay(Color.white.opacity(0.07)).padding(.top, 10)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(m.dayCount)").font(mono(15, .bold)).foregroundStyle(WidgetPalette.ink)
                WidgetKey(text: m.dayCount == 1 ? String(localized: "CATCH THAT DAY") : String(localized: "CATCHES THAT DAY"))
                Spacer()
                if m.bestDay { WidgetKey(text: String(localized: "YOUR BEST DAY"), color: WidgetPalette.yellow) }
            }
            .padding(.top, 8)
        }
    }

    private func box(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(mono(14, .bold)).foregroundStyle(WidgetPalette.ink).lineLimit(1).minimumScaleFactor(0.7)
            WidgetKey(text: label, size: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WidgetPalette.card)
    }

    private func placeLine(_ m: WidgetSnapshot.MemoryCard) -> String? {
        let parts = [m.street, m.place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ").uppercased()
    }

    private func weatherLine(_ m: WidgetSnapshot.MemoryCard) -> String? {
        let parts = [m.temperature.map { "\(Int($0.rounded()))°" }, WidgetWeather.word(m.weatherCode),
                     m.line.map { String(localized: "LINE \($0)") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func iconLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 12)
            Text(text).font(mono(10, .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(WidgetPalette.sub)
    }
}

/// WMO weather codes (Open-Meteo) as a word and a symbol.
enum WidgetWeather {
    static func word(_ code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 0, 1: return String(localized: "CLEAR", comment: "Weather")
        case 2, 3: return String(localized: "CLOUDY", comment: "Weather")
        case 45, 48: return String(localized: "FOG", comment: "Weather")
        case 51...67, 80...82: return String(localized: "RAIN", comment: "Weather")
        case 71...77, 85, 86: return String(localized: "SNOW", comment: "Weather")
        case 95...99: return String(localized: "STORM", comment: "Weather")
        default: return nil
        }
    }

    static func symbol(_ code: Int?) -> String {
        switch code ?? 0 {
        case 0, 1: "sun.max"
        case 2, 3: "cloud.sun"
        case 45, 48: "cloud.fog"
        case 51...67, 80...82: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 95...99: "cloud.bolt"
        default: "thermometer.medium"
        }
    }
}
