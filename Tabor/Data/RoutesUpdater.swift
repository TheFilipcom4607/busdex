import Foundation

/// Every line's street shapes and stops (routes.json), for drawing where a vehicle on HUNT
/// goes next. A GitHub Action rebuilds it daily from ZTM's GTFS and uploads it to TABOR's
/// proxy; this fetches it at most once a day, and only when it changed (ETag). Without it
/// HUNT works as before, just without the future.
@Observable @MainActor
final class RoutesUpdater {
    static let shared = RoutesUpdater()

    /// Loaded on first use, off the main actor: decoding ~1,500 shapes takes a moment.
    private(set) var book: RouteBook?

    @ObservationIgnored private var loading: Task<Void, Never>?
    private nonisolated static let lastCheckKey = "routesLastCheck"
    private nonisolated static let etagKey = "routesETag"

    nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("routes.json")
    }()

    /// Same host as the live feed.
    static var remoteURL: URL? { LiveFleetService.proxy.map { $0.deletingLastPathComponent().appendingPathComponent("routes") } }

    /// Loads what's on disk, then downloads a newer copy if a day has passed.
    func prepare() {
        guard loading == nil else { return }
        loading = Task {
            if book == nil { book = await Self.load() }
            if let url = Self.remoteURL, let fresh = await Self.downloadIfDue(from: url) { book = fresh }
            loading = nil
        }
    }

    private nonisolated static func load() async -> RouteBook? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? RouteBook(json: data)
        }.value
    }

    /// The new routes, when a new file was saved.
    private nonisolated static func downloadIfDue(from url: URL) async -> RouteBook? {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        let haveFile = FileManager.default.fileExists(atPath: fileURL.path)
        guard !haveFile || Date().timeIntervalSince(last) > 24 * 3600 else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if haveFile, let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 304 {
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                return nil
            }
            // It must decode before it replaces a working copy.
            guard http.statusCode == 200, let book = try? RouteBook(json: data), book.lineCount > 0 else { return nil }
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
            return book
        } catch {
            return nil
        }
    }
}
