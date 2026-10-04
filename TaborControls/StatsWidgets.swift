import AppIntents
import SwiftUI
import WidgetKit

/// Which stretch the Stats widget counts, picked when you add it.
enum StatsWidgetPeriod: String, AppEnum {
    case month, year, all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [StatsWidgetPeriod: DisplayRepresentation] = [
        .month: "This month",
        .year: "This year",
        .all: "All time",
    ]

    var kind: WidgetSnapshot.PeriodSummary.Kind {
        switch self {
        case .month: .month
        case .year: .year
        case .all: .all
        }
    }
}

struct StatsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Stats"
    static let description = IntentDescription("Your catches over a month, a year or all time.")

    @Parameter(title: "Period", default: .month)
    var period: StatsWidgetPeriod
}

struct StatsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let period: StatsWidgetPeriod
}

struct StatsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: .now, snapshot: .placeholder, period: .month)
    }

    func snapshot(for configuration: StatsWidgetIntent, in context: Context) async -> StatsEntry {
        StatsEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .placeholder, period: configuration.period)
    }

    /// The app reloads it after every catch; a new month or year needs the app to recount.
    func timeline(for configuration: StatsWidgetIntent, in context: Context) async -> Timeline<StatsEntry> {
        Timeline(entries: [StatsEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .empty, period: configuration.period)],
                 policy: .never)
    }
}

/// This month, this year or all time, in big numbers.
struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "tabor.stats", intent: StatsWidgetIntent.self, provider: StatsProvider()) { entry in
            FamilyReader {
                StatsWidgetView(summary: entry.snapshot.period(entry.period.kind), snapshot: entry.snapshot, family: $0)
            }
            .containerBackground(for: .widget) { WidgetPalette.bg }
            .widgetURL(WidgetLink.book)
        }
        .configurationDisplayName("Stats")
        .description("Your catches, new vehicles and models, and how much of the fleet you've got.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Memories

struct MemoryEntry: TimelineEntry {
    let date: Date
    let memory: WidgetSnapshot.MemoryCard?
}

struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry { MemoryEntry(date: .now, memory: nil) }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        completion(MemoryEntry(date: .now, memory: WidgetSnapshot.load()?.memory(on: .now)))
    }

    /// A page a day: the app leaves a week of memories, each shown from its midnight.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .empty
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let days = (1...7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let entries = [MemoryEntry(date: .now, memory: snapshot.memory(on: .now))]
            + days.map { MemoryEntry(date: $0, memory: snapshot.memory(on: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// A catch from a year, a month or a week ago today.
struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tabor.memories", provider: MemoryProvider()) { entry in
            FamilyReader { MemoryWidgetView(memory: entry.memory, family: $0) }
                .containerBackground(for: .widget) { WidgetPalette.bg }
                .widgetURL(entry.memory?.url ?? WidgetLink.book)
        }
        .configurationDisplayName("Memories")
        .description("What you caught a year, a month or a week ago today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
