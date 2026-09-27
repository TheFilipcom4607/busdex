import SwiftUI
import WidgetKit

/// For widgets that only change when the book does: the app reloads them after a catch.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .empty)], policy: .never))
    }
}

/// Your newest stickers; each one opens that vehicle in the book.
struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tabor.recent", provider: SnapshotProvider()) { entry in
            FamilyReader { RecentWidgetView(snapshot: entry.snapshot, family: $0) }
                .containerBackground(for: .widget) { WidgetPalette.bg }
        }
        .configurationDisplayName("Latest catches")
        .description("Your newest stickers. Tap one to open it in your book.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// How far along each rarity is.
struct RarityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tabor.rarity", provider: SnapshotProvider()) { entry in
            FamilyReader { RarityWidgetView(snapshot: entry.snapshot, family: $0) }
                .containerBackground(for: .widget) { WidgetPalette.bg }
                .widgetURL(WidgetLink.book)
        }
        .configurationDisplayName("Rarity sets")
        .description("How many legendary, gold, rare and common vehicles you've caught.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// One of your stickers, a different one every hour, rarest ones first in the pile.
struct ShuffleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tabor.shuffle", provider: ShuffleProvider()) { entry in
            FamilyReader { ShuffleWidgetView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { WidgetPalette.bg }
                .widgetURL(entry.card?.url ?? WidgetLink.book)
        }
        .configurationDisplayName("Sticker shuffle")
        .description("A different sticker from your book every hour.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ShuffleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShuffleEntry {
        ShuffleEntry(date: .now, snapshot: .placeholder, card: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShuffleEntry) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        completion(ShuffleEntry(date: .now, snapshot: snapshot, card: snapshot.shuffleCard(at: .now)))
    }

    /// A day of hourly entries, each on the hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShuffleEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .empty
        let hour = Calendar.current.dateInterval(of: .hour, for: .now)?.start ?? .now
        let dates = [Date.now] + (1...24).map { hour.addingTimeInterval(Double($0) * 3600) }
        let entries = dates.map { ShuffleEntry(date: $0, snapshot: snapshot, card: snapshot.shuffleCard(at: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
