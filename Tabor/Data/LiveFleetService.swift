import CoreLocation
import Foundation

/// Live GPS for every ZTM bus and tram, from Warsaw's open-data API. Polls every 15 s, but
/// only while something on screen wants it (the HUNT map, the camera) — never in the
/// background. Without an API key everything live is quietly off.
@Observable @MainActor
final class LiveFleetService {
    static let shared = LiveFleetService()

    /// Settings can override the key baked in at build time.
    static let keyOverrideKey = "umApiKey"
    static let interval: Duration = .seconds(15)

    enum Status: Equatable {
        case noKey, idle, loading, live
        case error(String)
    }

    private(set) var snapshot: LiveSnapshot?
    private(set) var status: Status
    /// Vehicles around you at the last refresh or location change, nearest first.
    private(set) var nearby: [NearbyVehicle] = []

    @ObservationIgnored private var clients: Set<String> = []
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// The key the current snapshot was fetched with.
    @ObservationIgnored private var usedKey: String?

    private init() {
        status = Self.key == nil ? .noKey : .idle
    }

    static var key: String? { overrideKey ?? builtInKey }

    /// A key typed into Settings.
    static var overrideKey: String? {
        let override = UserDefaults.standard.string(forKey: keyOverrideKey)?.trimmingCharacters(in: .whitespaces)
        return override?.isEmpty == false ? override : nil
    }

    /// The key from Config/Secrets.xcconfig, baked in at build time.
    static var builtInKey: String? {
        let baked = (Bundle.main.object(forInfoDictionaryKey: "TaborUMKey") as? String)?.trimmingCharacters(in: .whitespaces)
        // An unset build setting comes through empty (or as the literal "$(…)" in odd setups).
        guard let baked, !baked.isEmpty, !baked.hasPrefix("$(") else { return nil }
        return baked
    }

    /// The snapshot, if it's recent enough to act on.
    func fresh(maxAge: TimeInterval = 60) -> LiveSnapshot? {
        guard let snapshot, Date().timeIntervalSince(snapshot.fetched) <= maxAge else { return nil }
        return snapshot
    }

    // MARK: - Who's watching

    func start(_ client: String) {
        clients.insert(client)
        LocationService.shared.startUpdating("live-\(client)")
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop(_ client: String) {
        clients.remove(client)
        LocationService.shared.stopUpdating("live-\(client)")
        guard clients.isEmpty else { return }
        poller?.cancel()
        poller = nil
    }

    /// The key may have changed in Settings; starts over only if it really did.
    func keyChanged() {
        guard Self.key != usedKey else { return }
        snapshot = nil
        nearby = []
        status = Self.key == nil ? .noKey : .idle
        if !clients.isEmpty { Task { await refresh() } }
    }

    // MARK: - Fetching

    func refresh() async {
        guard let key = Self.key else {
            status = .noKey
            return
        }
        if snapshot == nil { status = .loading }
        usedKey = key
        async let buses = Self.fetch(.bus, key: key)
        async let trams = Self.fetch(.tram, key: key)
        let results: [(VehicleKind, Result<[LiveVehicle], Error>)] = [(.bus, await buses), (.tram, await trams)]
        var vehicles: [LiveVehicle] = []
        var failure: Error?
        for (kind, result) in results {
            switch result {
            case .success(let list): vehicles += list
            case .failure(let error):
                // The API drops single calls under load; keep that kind from the last round.
                failure = error
                vehicles += snapshot?.vehicles.filter { $0.kind == kind } ?? []
            }
        }
        if let failure, results.allSatisfy({ if case .failure = $0.1 { true } else { false } }) {
            // Keep showing the last good snapshot; the map dims it once it goes stale.
            status = .error(Self.describe(failure))
            return
        }
        snapshot = LiveSnapshot(vehicles: vehicles, fetched: Date())
        status = .live
        locationMoved()
    }

    /// Recomputes `nearby`; called on each refresh and whenever the map sees you move.
    func locationMoved() {
        guard let snapshot = fresh(), let here = LocationService.shared.recent() else {
            nearby = []
            return
        }
        nearby = snapshot.nearby(lat: here.coordinate.latitude, lon: here.coordinate.longitude, within: LiveHints.boostRadius)
    }

    private static func fetch(_ kind: VehicleKind, key: String) async -> Result<[LiveVehicle], Error> {
        var c = URLComponents(string: "https://api.um.warszawa.pl/api/action/busestrams_get/")!
        c.queryItems = [
            URLQueryItem(name: "resource_id", value: "f2e5503e-927d-4ad3-9500-4ab9e55deb59"),
            URLQueryItem(name: "type", value: kind == .bus ? "1" : "2"),
            URLQueryItem(name: "apikey", value: key),
        ]
        let request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return .success(try LiveFeed.parse(data, kind: kind))
        } catch {
            return .failure(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case LiveFeed.Failure.message(let m): m
        case LiveFeed.Failure.malformed: "The city's feed sent something unreadable."
        case let e as URLError where e.code == .notConnectedToInternet: "You're offline."
        default: "The city's feed didn't answer."
        }
    }
}
