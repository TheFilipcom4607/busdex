import CoreLocation

struct Geotag {
    let coordinate: CLLocationCoordinate2D
    let street: String?
    let district: String?
}

/// One-shot location + reverse geocode for geotagging a catch.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var pending: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
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
        let conts = pending
        pending.removeAll()
        conts.forEach { $0.resume(returning: loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finish(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
