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

        let (recent, pile, files) = cards(sightings, catalog: catalog)
        await Task.detached(priority: .utility) { syncCardImages(files) }.value

        let stats = sightings.stats
        let snapshot = WidgetSnapshot(
            caught: stats.fleetCaught(catalog: catalog), fleet: catalog.totalFleet,
            streak: Streak.days(sightings.map(\.date)), lastCatch: latest?.date,
            latestNumber: latest?.number, latestModel: latest.map { _ in model?.name ?? String(localized: "Unknown model") },
            latestTier: model?.tier.rawValue,
            hasImage: source != nil && FileManager.default.fileExists(atPath: imageURL.path),
            imageIsCutout: sticker != nil,
            recent: recent, pile: pile, tiers: tierCounts(stats, catalog: catalog))
        guard imageChanged || snapshot != WidgetSnapshot.load() else { return }
        snapshot.save()
        WidgetSnapshot.bookKinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    }

    /// One card per caught vehicle that has a picture: the newest few, and a pile that leans
    /// rare for the shuffle. Also returns which picture file each card's PNG comes from.
    private static func cards(_ sightings: [Sighting], catalog: FleetCatalog)
        -> (recent: [WidgetSnapshot.Card], pile: [WidgetSnapshot.Card], files: [String: String]) {
        struct Vehicle {
            var last: Date; var first: Date; var times: Int; var sticker: String?; var photo: String?
            /// The picture picked for the book is in, and nothing older replaces it.
            var picked = false
        }
        var byKey: [String: (modelId: String, number: Int, v: Vehicle)] = [:]
        for s in sightings.sorted(by: { $0.date > $1.date }) {
            let key = "\(s.modelId)#\(s.number)"
            var e = byKey[key] ?? (s.modelId, s.number, Vehicle(last: s.date, first: s.date, times: 0))
            e.v.first = s.date
            e.v.times += 1
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

        var files: [String: String] = [:]
        var all: [(card: WidgetSnapshot.Card, last: Date, fleet: Int)] = []
        for e in byKey.values {
            guard let model = catalog.model(id: e.modelId),
                  let source = e.v.sticker ?? e.v.photo, PhotoStore.exists(source) else { continue }
            let name = WidgetSnapshot.cardPrefix + (source as NSString).deletingPathExtension + ".png"
            files[name] = source
            all.append((WidgetSnapshot.Card(number: e.number, modelId: e.modelId, model: model.name,
                                            tier: model.tier.rawValue, image: name, cutout: e.v.sticker != nil,
                                            firstSeen: e.v.first, times: e.v.times),
                        e.v.last, model.fleet))
        }

        let recent = all.sorted { $0.last > $1.last }.prefix(recentCount).map(\.card)
        // Rarest first, then dealt in an order that doesn't follow the book, so the hours
        // don't run one model after another.
        let pile = all.sorted { $0.fleet != $1.fleet ? $0.fleet < $1.fleet : $0.card.number < $1.card.number }
            .prefix(pileCount).map(\.card)
            .sorted { ($0.number &* 2_654_435_761) % 1_009 < ($1.number &* 2_654_435_761) % 1_009 }
        let used = Set(recent.map(\.image) + pile.map(\.image))
        return (Array(recent), pile, files.filter { used.contains($0.key) })
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
