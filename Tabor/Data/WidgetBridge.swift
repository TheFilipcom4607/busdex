import UIKit
import WidgetKit

/// Keeps the widget's snapshot in the App Group container in step with the book.
@MainActor
enum WidgetBridge {
    /// The photo or sticker file last copied for the widget (once per launch at most).
    private static var imageSource: String??

    static func publish(_ sightings: [Sighting], catalog: FleetCatalog = Fleet.catalog) {
        guard let imageURL = WidgetSnapshot.imageURL else { return } // no App Group entitlement
        let latest = sightings.max { $0.date < $1.date }
        let model = latest.flatMap { catalog.model(id: $0.modelId) }
        let sticker = latest.flatMap { sightings.sticker(number: $0.number, modelId: $0.modelId) }
        let source = sticker ?? latest.flatMap { sightings.photo(number: $0.number, modelId: $0.modelId) }

        let imageChanged = imageSource != .some(source)
        if imageChanged {
            // Widgets have a tight memory budget: hand them a small PNG, not the full photo.
            if let source, let data = try? Data(contentsOf: PhotoStore.url(source)),
               let cg = PhotoStore.downsample(data, maxPixel: 480),
               let png = UIImage(cgImage: cg).pngData() {
                try? png.write(to: imageURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: imageURL)
            }
            imageSource = .some(source)
        }

        let snapshot = WidgetSnapshot(
            caught: sightings.stats.fleetCaught(catalog: catalog), fleet: catalog.totalFleet,
            streak: Streak.days(sightings.map(\.date)), lastCatch: latest?.date,
            latestNumber: latest?.number, latestModel: latest.map { _ in model?.name ?? String(localized: "Unknown model") },
            latestTier: model?.tier.rawValue,
            hasImage: source != nil && FileManager.default.fileExists(atPath: imageURL.path),
            imageIsCutout: sticker != nil)
        guard imageChanged || snapshot != WidgetSnapshot.load() else { return }
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
    }
}
