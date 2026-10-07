import Foundation

/// What the Home / Lock Screen widget shows, written by the app into the shared App Group
/// container. Compiled into both the app and the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.filipmanikowski.tabor"
    static let widgetKind = "tabor.progress"
    /// Every widget that shows the book, reloaded together when it changes.
    static let bookKinds = [widgetKind, "tabor.recent", "tabor.rarity", "tabor.shuffle", "tabor.stats", "tabor.memories"]

    /// Distinct vehicles caught that count toward the fleet (vintage and test stock don't).
    var caught: Int
    var fleet: Int
    /// The streak as of `lastCatch`'s day.
    var streak: Int
    var lastCatch: Date?
    var latestNumber: Int?
    var latestModel: String?
    /// Tier name, e.g. "LEGENDARY" — the widget colours the number tag with it.
    var latestTier: String?
    /// Whether `imageURL` holds the latest catch's picture.
    var hasImage: Bool
    /// A die-cut sticker (transparent PNG) rather than the plain photo.
    var imageIsCutout: Bool
    /// Newest first, for the Latest catches widget. Optional: older snapshots don't have them.
    var recent: [Card]? = nil
    /// What the Sticker shuffle widget deals from, one an hour.
    var pile: [Card]? = nil
    /// LEGENDARY, GOLD, RARE, COMMON: caught out of the fleet, for the Rarity sets widget.
    var tiers: [TierCount]? = nil
    /// Models touched out of the regular ones, and the longest streak ever.
    var models: Int? = nil
    var modelsTotal: Int? = nil
    var bestStreak: Int? = nil
    /// This month, this year and all time, for the Stats widget.
    var periods: [PeriodSummary]? = nil
    /// What the Memories widget shows, one per day from today on.
    var memories: [MemoryCard]? = nil

    /// A caught vehicle that has a picture.
    struct Card: Codable, Equatable, Hashable {
        var number: Int
        var modelId: String
        var model: String
        var tier: String
        /// File name in the App Group container.
        var image: String
        var cutout: Bool
        var firstSeen: Date
        var times: Int
        /// Optional: older snapshots don't have them.
        var fleet: Int? = nil
        /// Vehicles of its model in the book.
        var owned: Int? = nil
        var lastSeen: Date? = nil
        var line: String? = nil
        var place: String? = nil

        var url: URL { WidgetLink.vehicle(modelId: modelId, number: number) }
    }

    struct PeriodSummary: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable { case month, year, all }

        var kind: Kind
        /// "OCTOBER", "2026", "ALL TIME", in the app's language.
        var label: String
        var catches: Int
        var vehicles: Int
        var newVehicles: Int
        var models: Int
        var newModels: Int
        var lines: Int
        var daysOut: Int
        var bestStreak: Int
        var bestDay: Int
        /// All time: the share of the fleet caught; a month or year: what it added.
        var fleetShare: Double
        var topLine: String?
        /// Catches per day of the month, or per month of the year (the last 12 for all time).
        var bars: [Int]
        var topModels: [TopModel]
        var rarest: Card?
    }

    struct TopModel: Codable, Equatable {
        var name: String
        var count: Int
        var tier: String
    }

    /// A day's look back: a catch from a year, a month or a week ago, your first, or a random one.
    struct MemoryCard: Codable, Equatable {
        enum Kind: String, Codable { case yearAgo, monthAgo, weekAgo, first, random }

        /// The day the widget shows it (its start).
        var showOn: Date
        var kind: Kind
        var number: Int
        var modelId: String
        var model: String
        var tier: String
        /// File name in the App Group container, if the vehicle has a picture.
        var image: String?
        var cutout: Bool
        var date: Date
        var line: String?
        var street: String?
        var place: String?
        var temperature: Double?
        var weatherCode: Int?
        /// Times this vehicle has been seen, and catches on that day.
        var times: Int
        var dayCount: Int
        /// That day is your busiest ever.
        var bestDay: Bool

        var url: URL { WidgetLink.vehicle(modelId: modelId, number: number) }
    }

    func period(_ kind: PeriodSummary.Kind) -> PeriodSummary? { periods?.first { $0.kind == kind } }

    /// The memory for a day: its own, else the last one there is.
    func memory(on date: Date, calendar: Calendar = .current) -> MemoryCard? {
        let day = calendar.startOfDay(for: date)
        return memories?.first { calendar.isDate($0.showOn, inSameDayAs: day) } ?? memories?.last { $0.showOn <= day }
    }

    struct TierCount: Codable, Equatable {
        var tier: String
        var caught: Int
        var fleet: Int
    }

    static let placeholder = WidgetSnapshot(caught: 312, fleet: 2677, streak: 6, lastCatch: .now,
                                            latestNumber: 1974, latestModel: "Yutong U12",
                                            latestTier: "GOLD", hasImage: false, imageIsCutout: false)
    static let empty = WidgetSnapshot(caught: 0, fleet: 0, streak: 0, lastCatch: nil, latestNumber: nil,
                                      latestModel: nil, latestTier: nil, hasImage: false, imageIsCutout: false)

    /// The streak survives the day after the last catch, then drops to zero.
    func streak(at now: Date, calendar: Calendar = .current) -> Int {
        guard let lastCatch else { return 0 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastCatch),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 1 ? streak : 0
    }

    /// True on the day after a catch: one more today keeps the streak going.
    func streakAtRisk(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastCatch, streak > 0 else { return false }
        return !calendar.isDate(lastCatch, inSameDayAs: now) && streak(at: now, calendar: calendar) > 0
    }

    // MARK: Storage

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var imageURL: URL? { container?.appendingPathComponent("widget-latest.png") }
    static func imageURL(_ name: String) -> URL? { container?.appendingPathComponent(name) }
    /// Every sticker-widget picture starts with this, so stale ones can be swept.
    static let cardPrefix = "w-"
    private static var fileURL: URL? { container?.appendingPathComponent("widget.json") }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
