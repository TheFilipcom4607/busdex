import Foundation

/// Fetches newer fleet data between app releases. A GitHub Action refreshes fleet.json in
/// the repo weekly; this downloads it when its `fetched` date beats what the app has, and
/// `Fleet.catalog` picks it up on the next launch.
enum FleetUpdater {
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/TheFilipcom4607/busdex/main/Tabor/Resources/fleet.json")!
    static let enabledKey = "fleetUpdates"
    private static let lastCheckKey = "fleetLastCheck"

    static let downloadedURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet.json")
    }()

    enum Outcome: Equatable {
        /// Saved; used from the next launch.
        case downloaded(fetched: String)
        case upToDate
        case failed(String)
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// At most once a day, and only when the user hasn't turned updates off.
    static func checkIfDue() async {
        guard isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        _ = await check()
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed("The server didn't answer.") }
            guard let remote = FleetCatalog.validated(json: data) else { return .failed("The downloaded data was broken.") }
            // Beat both what's running and anything already waiting for the next launch.
            let pending = (try? Data(contentsOf: downloadedURL)).flatMap(FleetCatalog.validated)
            guard remote.isNewer(than: Fleet.catalog), remote.isNewer(than: pending) else {
                return pending?.isNewer(than: Fleet.catalog) == true ? .downloaded(fetched: pending!.fetched!) : .upToDate
            }
            try data.write(to: downloadedURL, options: .atomic)
            return .downloaded(fetched: remote.fetched!)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
