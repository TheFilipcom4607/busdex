import Foundation
import SwiftData

/// Fills in the weather for geotagged catches, for the weather badges. Runs in the
/// background after launch and after new catches; old catches get filled in too.
@MainActor
enum WeatherService {
    static let enabledKey = "weatherLookup"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func backfill(_ sightings: [Sighting], context: ModelContext) async {
        guard isEnabled else { return }
        // Newest first, a bounded batch per run. A fresh catch qualifies once its geotag lands.
        let due = sightings
            .filter { $0.weatherCode == nil && $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.date > $1.date }
            .prefix(40)
        var changed = false
        for s in due {
            // A newer run (the book changed) takes over; keep what this one found.
            if Task.isCancelled { break }
            guard let lat = s.latitude, let lon = s.longitude else { continue }
            let url = OpenMeteo.url(latitude: lat, longitude: lon, date: s.date)
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let reading = OpenMeteo.reading(from: data, at: s.date)
            else { continue } // no data yet (the archive lags a few days): try again next time
            guard !s.isDeleted, s.modelContext != nil else { continue } // deleted while we waited
            s.weatherCode = reading.code
            s.temperature = reading.temperature
            changed = true
        }
        if changed { try? context.save() }
    }
}
