import SwiftUI
import UIKit
import WidgetKit

/// Home and Lock Screen widget: streak, vehicles caught out of the fleet, latest sticker.
struct ProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: ProgressProvider()) { entry in
            ProgressWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.bg }
        }
        .configurationDisplayName("Your book")
        .description("Your streak, how much of the fleet you've caught and your latest sticker.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct ProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let image: UIImage?

    var streak: Int { snapshot.streak(at: date) }
    var atRisk: Bool { snapshot.streakAtRisk(at: date) }
}

struct ProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProgressEntry {
        ProgressEntry(date: .now, snapshot: .placeholder, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProgressEntry) -> Void) {
        completion(context.isPreview && WidgetSnapshot.load() == nil ? placeholder(in: context) : current(at: .now))
    }

    /// The app reloads the timeline after every catch; between catches only midnight
    /// changes anything (the streak goes at-risk, then lapses).
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProgressEntry>) -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let midnights = (1...2).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let entries = [current(at: .now)] + midnights.map { current(at: $0) }
        completion(Timeline(entries: entries, policy: .after(midnights.last!)))
    }

    private func current(at date: Date) -> ProgressEntry {
        let snapshot = WidgetSnapshot.load() ?? .empty
        let image = snapshot.hasImage ? WidgetSnapshot.imageURL.flatMap { UIImage(contentsOfFile: $0.path) } : nil
        return ProgressEntry(date: date, snapshot: snapshot, image: image)
    }
}

enum WidgetPalette {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let ink = Color(red: 0.969, green: 0.961, blue: 0.941)
    static let sub = Color(red: 0.541, green: 0.561, blue: 0.596)
    static let yellow = Color(red: 1, green: 0.808, blue: 0)
    static let red = Color(red: 0.894, green: 0, blue: 0.169)
    static let green = Color(red: 0.137, green: 0.898, blue: 0.627)
    static let brass = Color(red: 0.824, green: 0.627, blue: 0.392)

    /// The number tag's colour for a tier; white for COMMON, like the stickers in the app.
    static func tag(_ name: String?) -> Color {
        switch name {
        case "LEGENDARY": red
        case "GOLD": yellow
        case "RARE": green
        case "VINTAGE": brass
        default: .white
        }
    }
}

struct ProgressWidgetView: View {
    let entry: ProgressEntry
    @Environment(\.widgetFamily) private var family

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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(WidgetPalette.sub.opacity(0.5))
                .overlay {
                    Image(systemName: "bus.fill").foregroundStyle(WidgetPalette.sub)
                }
        }
    }

    @ViewBuilder private var numberTag: some View {
        if let number = s.latestNumber {
            Text(String(number))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(WidgetPalette.tag(s.latestTier), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
