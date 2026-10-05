import CoreLocation

struct Geotag {
    let coordinate: CLLocationCoordinate2D
    let street: String?
    let district: String?
}

/// One-shot location + reverse geocode for geotagging a catch, plus continuous updates
/// while the HUNT map or the camera needs to know what's nearby.
@Observable @MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Latest fix from continuous updates (or a one-shot request).
    private(set) var latest: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Which way the phone points, while someone asks for it: nil without a compass.
    private(set) var heading: Heading?
    /// Whether there's a heading at all. Views that only need this read it instead of `heading`,
    /// which changes every couple of degrees and would redraw them each time.
    private(set) var hasHeading = false

    struct Heading: Equatable {
        /// Degrees clockwise from true north (magnetic north until there's a fix).
        let degrees: Double
        /// How far off it may be, in degrees.
        let accuracy: Double
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var pending: [CheckedContinuation<CLLocation?, Never>] = []
    @ObservationIgnored private var watchers: Set<String> = []
    @ObservationIgnored private var headingWatchers: Set<String> = []

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        // Enough to turn the map smoothly without redrawing it for every tremble.
        manager.headingFilter = 2
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Keeps a live fix while any `client` wants one. Foreground only: the app has no
    /// background location mode, so iOS pauses this when TABOR leaves the screen.
    func startUpdating(_ client: String) {
        requestPermission()
        let first = watchers.isEmpty
        watchers.insert(client)
        if first { manager.startUpdatingLocation() }
    }

    func stopUpdating(_ client: String) {
        guard watchers.remove(client) != nil, watchers.isEmpty else { return }
        manager.stopUpdatingLocation()
    }

    /// The compass, while any `client` wants it (HUNT's cone and its facing map).
    func startHeading(_ client: String) {
        guard CLLocationManager.headingAvailable() else { return }
        let first = headingWatchers.isEmpty
        headingWatchers.insert(client)
        if first { manager.startUpdatingHeading() }
    }

    func stopHeading(_ client: String) {
        guard headingWatchers.remove(client) != nil, headingWatchers.isEmpty else { return }
        manager.stopUpdatingHeading()
        heading = nil
        hasHeading = false
    }

    /// `latest`, if it's recent enough to say what's around you.
    func recent(maxAge: TimeInterval = 60) -> CLLocation? {
        guard let latest, latest.timestamp.timeIntervalSinceNow > -maxAge, latest.horizontalAccuracy < 250 else { return nil }
        return latest
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func geotag() async -> Geotag? {
        requestPermission()
        guard let loc = await currentLocation() else { return nil }
        return await geotag(loc)
    }

    /// Reverse-geocodes a known position (e.g. from an imported photo's EXIF).
    func geotag(_ loc: CLLocation) async -> Geotag? {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "pl_PL")).first
        return Geotag(coordinate: loc.coordinate, street: mark?.thoroughfare, district: mark?.subLocality)
    }

    private func currentLocation() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -60 { return recent }
        return await withCheckedContinuation { cont in
            pending.append(cont)
            if pending.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ loc: CLLocation?) {
        if let loc { latest = loc }
        let conts = pending
        pending.removeAll()
        conts.forEach { $0.resume(returning: loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finish(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading new: CLHeading) {
        // A negative accuracy means the reading is no good (the compass needs calibrating).
        let reading = new.headingAccuracy < 0 ? nil
            : Heading(degrees: new.trueHeading >= 0 ? new.trueHeading : new.magneticHeading, accuracy: new.headingAccuracy)
        Task { @MainActor in
            guard !self.headingWatchers.isEmpty else { return }
            self.heading = reading
            if self.hasHeading != (reading != nil) { self.hasHeading = reading != nil }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if !self.watchers.isEmpty, status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
