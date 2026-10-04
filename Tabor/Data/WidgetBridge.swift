import UIKit
import WidgetKit

/// Keeps the widgets' snapshot in the App Group container in step with the book.
@MainActor
enum WidgetBridge {
    /// The photo or sticker file last copied for the widget (once per launch at most).
    private static var imageSource: String??

    static let recentCount = 6
    static let pileCount = 24

    static func publish(_ sightings: [Sighting], catalog: FleetCatalog = Fleet.catalog) async {
        guard let imageURL = WidgetSnapshot.imageURL else { return } // no App Group entitlement
        let latest = sightings.max { $0.date < $1.date }
        let model = latest.flatMap { catalog.model(id: $0.modelId) }
        let sticker = latest.flatMap { sightings.sticker(number: $0.number, modelId: $0.modelId) }
        let source = sticker ?? latest.flatMap { sightings.photo(number: $0.number, modelId: $0.modelId) }

        let imageChanged = imageSource != .some(source)
        if imageChanged {
            // Widgets have a tight memory budget: hand them a small PNG, not the full photo.
            await Task.detached(priority: .utility) { writeImage(source, to: imageURL, maxPixel: 480) }.value
            imageSource = .some(source)
        }

        let deck = cards(sightings, catalog: catalog)
        let records = sightings.map(\.record)
        let periods = PeriodSummaryKind.allCases.map { summary($0, records: records, deck: deck, catalog: catalog) }
        let memories = memories(sightings, deck: deck, catalog: catalog)
        // Only the pictures some widget shows.
        let used = Set(deck.recent.map(\.image) + deck.pile.map(\.image) + periods.compactMap { $0.rarest?.image }
                       + memories.compactMap(\.image))
        let files = deck.files.filter { used.contains($0.key) }
        await Task.detached(priority: .utility) { syncCardImages(files) }.value

        let stats = sightings.stats
        let snapshot = WidgetSnapshot(
            caught: stats.fleetCaught(catalog: catalog), fleet: catalog.totalFleet,
            streak: Streak.days(sightings.map(\.date)), lastCatch: latest?.date,
            latestNumber: latest?.number, latestModel: latest.map { _ in model?.name ?? String(localized: "Unknown model") },
            latestTier: model?.tier.rawValue,
            hasImage: source != nil && FileManager.default.fileExists(atPath: imageURL.path),
            imageIsCutout: sticker != nil,
            recent: deck.recent, pile: deck.pile, tiers: tierCounts(stats, catalog: catalog),
            models: catalog.models.filter { m in m.regular && stats.ownedCount(modelId: m.id) > 0 }.count,
            modelsTotal: catalog.models.filter(\.regular).count,
            bestStreak: Streak.best(sightings.map(\.date))?.days ?? 0,
            periods: periods, memories: memories)
        guard imageChanged || snapshot != WidgetSnapshot.load() else { return }
        snapshot.save()
        WidgetSnapshot.bookKinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    }

    /// Every caught vehicle that has a picture, as a card: the newest few, a pile that leans
    /// rare for the shuffle, and all of them to look up by "modelId#number". `files` says which
    /// picture file each card's PNG comes from.
    struct Deck {
        var recent: [WidgetSnapshot.Card]
        var pile: [WidgetSnapshot.Card]
        var byKey: [String: WidgetSnapshot.Card]
        var files: [String: String]
    }

    private static func cards(_ sightings: [Sighting], catalog: FleetCatalog) -> Deck {
        struct Vehicle {
            var last: Date; var first: Date; var times: Int; var sticker: String?; var photo: String?
            var line: String?; var place: String?
            /// The picture picked for the book is in, and nothing older replaces it.
            var picked = false
        }
        var byKey: [String: (modelId: String, number: Int, v: Vehicle)] = [:]
        for s in sightings.sorted(by: { $0.date > $1.date }) {
            let key = "\(s.modelId)#\(s.number)"
            var e = byKey[key] ?? (s.modelId, s.number, Vehicle(last: s.date, first: s.date, times: 0))
            e.v.first = s.date
            e.v.times += 1
            // Newest first, so these are the latest known.
            e.v.line = e.v.line ?? s.line
            e.v.place = e.v.place ?? s.district
            // Like the book: the picked sighting's picture, else the newest.
            if s.cover == true, s.hasPicture, !e.v.picked {
                e.v.sticker = s.stickerFile
                e.v.photo = s.photoFile ?? e.v.photo
                e.v.picked = true
            } else if !e.v.picked {
                e.v.sticker = e.v.sticker ?? s.stickerFile
                e.v.photo = e.v.photo ?? s.photoFile
            }
            byKey[key] = e
        }

        let stats = sightings.stats
        var files: [String: String] = [:]
        var all: [(card: WidgetSnapshot.Card, last: Date, fleet: Int)] = []
        for e in byKey.values {
            guard let model = catalog.model(id: e.modelId),
                  let source = e.v.sticker ?? e.v.photo, PhotoStore.exists(source) else { continue }
            let name = WidgetSnapshot.cardPrefix + (source as NSString).deletingPathExtension + ".png"
            files[name] = source
            all.append((WidgetSnapshot.Card(number: e.number, modelId: e.modelId, model: model.name,
                                            tier: model.tier.rawValue, image: name, cutout: e.v.sticker != nil,
                                            firstSeen: e.v.first, times: e.v.times, fleet: model.fleet,
                                            owned: stats.ownedCount(modelId: model.id), lastSeen: e.v.last,
                                            line: e.v.line, place: e.v.place),
                        e.v.last, model.fleet))
        }

        let recent = all.sorted { $0.last > $1.last }.prefix(recentCount).map(\.card)
        // Rarest first, then dealt in an order that doesn't follow the book, so the hours
        // don't run one model after another.
        let pile = all.sorted { $0.fleet != $1.fleet ? $0.fleet < $1.fleet : $0.card.number < $1.card.number }
            .prefix(pileCount).map(\.card)
            .sorted { ($0.number &* 2_654_435_761) % 1_009 < ($1.number &* 2_654_435_761) % 1_009 }
        let byCard = Dictionary(all.map { ("\($0.card.modelId)#\($0.card.number)", $0.card) }, uniquingKeysWith: { a, _ in a })
        return Deck(recent: Array(recent), pile: pile, byKey: byCard, files: files)
    }

    typealias PeriodSummaryKind = WidgetSnapshot.PeriodSummary.Kind

    /// This month, this year or all time, boiled down for the Stats widget.
    private static func summary(_ kind: PeriodSummaryKind, records: [SightingRecord], deck: Deck,
                                catalog: FleetCatalog, now: Date = .now) -> WidgetSnapshot.PeriodSummary {
        var cal = Calendar.current
        cal.locale = .app
        let year = cal.component(.year, from: now), month = cal.component(.month, from: now)
        let period: StatsPeriod = switch kind {
        case .month: .month(year: year, month: month)
        case .year: .year(year)
        case .all: .all
        }
        let s = PeriodStats(records, period: period, catalog: catalog, now: now)
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        let bars: [Int]
        switch kind {
        case .month:
            let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
            bars = (0..<days).map { d in cal.date(byAdding: .day, value: d, to: monthStart).flatMap { s.perDay[$0] } ?? 0 }
        case .year, .all:
            // Months: this year's twelve, or the last twelve.
            let starts: [Date] = kind == .year
                ? (1...12).compactMap { cal.date(from: DateComponents(year: year, month: $0)) }
                : (0..<12).reversed().compactMap { cal.date(byAdding: .month, value: -$0, to: monthStart) }
            bars = starts.map { start in
                s.perDay.filter { cal.isDate($0.key, equalTo: start, toGranularity: .month) }.values.reduce(0, +)
            }
        }
        let label = switch kind {
        case .all: String(localized: "ALL TIME")
        case .year: String(year)
        case .month: cal.standaloneMonthSymbols[month - 1].uppercased(with: .app)
        }
        return WidgetSnapshot.PeriodSummary(
            kind: kind, label: label, catches: s.catches, vehicles: s.vehicles, newVehicles: s.newVehicles,
            models: s.models, newModels: s.newModels, lines: s.lines, daysOut: s.daysOut,
            bestStreak: s.records.bestStreak?.days ?? 0, bestDay: s.records.busiestCount,
            fleetShare: s.fleetShare, topLine: s.topLines.first?.name, bars: bars,
            topModels: s.topModels.prefix(3).map { m in
                let model = catalog.model(id: m.modelId)
                return WidgetSnapshot.TopModel(name: model?.name ?? m.modelId, count: m.catches, tier: model?.tier.rawValue ?? "COMMON")
            },
            rarest: s.records.rarest.flatMap { deck.byKey["\($0.modelId)#\($0.number)"] })
    }

    /// A memory for today and each day of the next week, so the widget turns the page at
    /// midnight without the app.
    private static func memories(_ sightings: [Sighting], deck: Deck, catalog: FleetCatalog) -> [WidgetSnapshot.MemoryCard] {
        let cal = Calendar.current
        let catches = sightings.filter { $0.pairedWith == nil }
        guard let first = catches.min(by: { $0.date < $1.date }) else { return [] }
        let byDay = Dictionary(grouping: catches) { cal.startOfDay(for: $0.date) }
        let busiest = byDay.values.map(\.count).max() ?? 0
        let stats = sightings.stats
        func pictured(_ s: Sighting) -> WidgetSnapshot.Card? { deck.byKey["\(s.modelId)#\(s.number)"] }

        func card(_ s: Sighting, showOn: Date, kind: WidgetSnapshot.MemoryCard.Kind) -> WidgetSnapshot.MemoryCard {
            let model = catalog.model(id: s.modelId)
            let picture = pictured(s)
            let day = byDay[cal.startOfDay(for: s.date)]?.count ?? 1
            return WidgetSnapshot.MemoryCard(
                showOn: showOn, kind: kind, number: s.number, modelId: s.modelId,
                model: model?.name ?? String(localized: "Unknown model"), tier: model?.tier.rawValue ?? "COMMON",
                image: picture?.image, cutout: picture?.cutout ?? false, date: s.date, line: s.line,
                street: s.street, place: s.district, temperature: s.temperature, weatherCode: s.weatherCode,
                times: stats.vehicle(number: s.number, modelId: s.modelId)?.timesSeen ?? 1,
                dayCount: day, bestDay: day == busiest && busiest > 1)
        }

        /// The day's catch worth remembering: one with a picture, rarest model first.
        func best(_ list: [Sighting]) -> Sighting? {
            list.min { a, b in
                let pa = pictured(a) != nil, pb = pictured(b) != nil
                if pa != pb { return pa }
                let fa = catalog.model(id: a.modelId)?.fleet ?? .max, fb = catalog.model(id: b.modelId)?.fleet ?? .max
                return fa != fb ? fa < fb : a.date < b.date
            }
        }

        // Random ones only come from vehicles with a picture, each vehicle once.
        var seen = Set<String>()
        let random = Array(catches.filter { pictured($0) != nil && seen.insert("\($0.modelId)#\($0.number)").inserted }
            .sorted { ($0.number &* 2_654_435_761) % 1_009 < ($1.number &* 2_654_435_761) % 1_009 }
            .prefix(7))
        let today = cal.startOfDay(for: .now)
        return (0..<8).compactMap { k -> WidgetSnapshot.MemoryCard? in
            guard let day = cal.date(byAdding: .day, value: k, to: today),
                  let pick = Memory.pick(for: day, hasCatches: { byDay[$0] != nil }, randomCount: random.count) else { return nil }
            switch pick.kind {
            case .first: return card(first, showOn: day, kind: .first)
            case .random: return card(random[pick.index], showOn: day, kind: .random)
            case .yearAgo, .monthAgo, .weekAgo:
                guard let d = pick.day, let s = byDay[d].flatMap(best),
                      let kind = WidgetSnapshot.MemoryCard.Kind(rawValue: pick.kind.rawValue) else { return nil }
                return card(s, showOn: day, kind: kind)
            }
        }
    }

    private static func tierCounts(_ stats: CollectionStats, catalog: FleetCatalog) -> [WidgetSnapshot.TierCount] {
        [Tier.legendary, .gold, .rare, .common].map { tier in
            let models = catalog.models.filter { $0.regular && $0.tier == tier }
            return WidgetSnapshot.TierCount(tier: tier.rawValue,
                                            caught: models.reduce(0) { $0 + stats.ownedCount(modelId: $1.id) },
                                            fleet: models.reduce(0) { $0 + $1.fleet })
        }
    }

    /// Writes the PNGs the cards need (each once: the name follows the source file) and
    /// sweeps the ones no card uses any more.
    nonisolated private static func syncCardImages(_ files: [String: String]) {
        for (name, source) in files {
            guard let url = WidgetSnapshot.imageURL(name), !FileManager.default.fileExists(atPath: url.path) else { continue }
            writeImage(source, to: url, maxPixel: 360)
        }
        guard let dir = WidgetSnapshot.imageURL("") else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(WidgetSnapshot.cardPrefix) && files[url.lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func writeImage(_ source: String?, to url: URL, maxPixel: Int) {
        if let source, let data = try? Data(contentsOf: PhotoStore.url(source)),
           let cg = PhotoStore.downsample(data, maxPixel: maxPixel),
           let png = UIImage(cgImage: cg).pngData() {
            try? png.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
