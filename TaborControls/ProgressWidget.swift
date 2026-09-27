import SwiftUI
import UIKit
import WidgetKit

/// Home and Lock Screen widget: streak, vehicles caught out of the fleet, latest sticker.
struct ProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: ProgressProvider()) { entry in
            FamilyReader { ProgressWidgetView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { WidgetPalette.bg }
        }
        .configurationDisplayName("Your book")
        .description("Your streak, how much of the fleet you've caught and your latest sticker.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// The widget views take their family as a parameter (the app draws them too); this hands it over.
struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family) }
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
