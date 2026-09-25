import Foundation

/// What the Home / Lock Screen widget shows, written by the app into the shared App Group
/// container. Compiled into both the app and the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.filipmanikowski.tabor"
    static let widgetKind = "tabor.progress"

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
