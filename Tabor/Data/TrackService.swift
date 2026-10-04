import ActivityKit
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "com.filipmanikowski.tabor", category: "track")

/// HUNT's TRACK (#42): one vehicle followed on the Lock Screen at a time. The Live Activity
/// starts here; the Worker (proxy/src/track.js) moves it on with pushes, since the app can't
/// poll once the phone is locked.
@MainActor
@Observable
final class TrackService {
    static let shared = TrackService()

    /// "BUS#1998" while that vehicle is tracked.
    private(set) var trackedId: String?

    private var watchers: [String: Task<Void, Never>] = [:]

    private init() {
        // Activities outlive the app: pick up one already running after a relaunch.
        for activity in Activity<TrackAttributes>.activities where activity.activityState == .active {
            trackedId = Self.id(activity.attributes)
            watch(activity, plan: nil)
        }
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func id(_ a: TrackAttributes) -> String { "\(a.tram ? "TRAM" : "BUS")#\(a.number)" }

    func isTracking(_ pin: WantedPin) -> Bool { trackedId == pin.id }

    /// Starts following a vehicle that's coming your way. Ends whatever was tracked before.
    func start(_ pin: WantedPin, plan: TrackPlan, sightings: [Sighting]) {
        guard enabled else { return }
        // Only the ones running now: the new one joins the list as soon as it's requested.
        let earlier = Activity<TrackAttributes>.activities
        Task { for activity in earlier { await end(activity, phase: .ended) } }

        let number = pin.vehicle.number, modelId = pin.model.id
        let caught = sightings.contains { $0.number == number && $0.modelId == modelId }
        let picture = caught ? Self.writePicture(sightings, number: number, modelId: modelId) : nil
        let attributes = TrackAttributes(
            number: number, modelId: modelId, model: pin.model.name, tier: pin.model.tier.rawValue,
            line: pin.vehicle.line, tram: pin.vehicle.kind == .tram, stop: plan.stop,
            image: picture?.name, cutout: picture?.cutout ?? false, newModel: pin.kind == .newModel,
            caught: caught, started: .now)
        let state = TrackAttributes.ContentState(phase: .coming, distance: Int(plan.distance.rounded()),
                                                 stops: plan.stops, at: plan.at, progress: 0)
        do {
            let activity = try Activity.request(attributes: attributes,
                                                content: .init(state: state, staleDate: .now.addingTimeInterval(120)),
                                                pushType: .token)
            trackedId = pin.id
            watch(activity, plan: Request(pin: pin, plan: plan))
        } catch {
            log.error("couldn't start: \(error)")
        }
    }

    /// Stops following: tapped again on HUNT.
    func stop() {
        Task { await stopAll(phase: .ended) }
    }

    /// Ends a track whose vehicle has just gone into the book.
    func endCaught(_ sightings: [Sighting]) {
        for activity in Activity<TrackAttributes>.activities where activity.activityState == .active {
            let a = activity.attributes
            guard sightings.contains(where: { $0.number == a.number && $0.modelId == a.modelId && $0.date >= a.started })
            else { continue }
            Task { await end(activity, phase: .caught) }
        }
    }

    private func stopAll(phase: TrackAttributes.ContentState.Phase) async {
        for activity in Activity<TrackAttributes>.activities { await end(activity, phase: phase) }
    }

    private func end(_ activity: Activity<TrackAttributes>, phase: TrackAttributes.ContentState.Phase) async {
        var state = activity.content.state
        state.phase = phase
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(phase == .caught ? 300 : 5)))
        await Self.send(method: "DELETE", body: ["id": activity.id])
    }

    // MARK: - The Worker

    /// What the Worker needs to follow the vehicle: sent with every new push token.
    struct Request {
        let pin: WantedPin
        let plan: TrackPlan
    }

    private func watch(_ activity: Activity<TrackAttributes>, plan: Request?) {
        watchers[activity.id]?.cancel()
        watchers[activity.id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                if let plan {
                    group.addTask {
                        for await token in activity.pushTokenUpdates {
                            await Self.register(activity.id, token: token, request: plan)
                        }
                    }
                }
                group.addTask {
                    for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                        await Self.send(method: "DELETE", body: ["id": activity.id])
                        await MainActor.run {
                            if self?.trackedId == Self.id(activity.attributes) { self?.trackedId = nil }
                        }
                        break
                    }
                }
            }
        }
    }

    private static func register(_ id: String, token: Data, request r: Request) async {
        let p = r.plan
        let body: [String: Any] = [
            "id": id,
            "token": token.map { String(format: "%02x", $0) }.joined(),
            // Xcode installs talk to Apple's sandbox push servers; TestFlight to the real ones.
            "sandbox": isSandbox,
            "lang": Bundle.main.preferredLocalizations.first == "pl" ? "pl" : "en",
            "type": r.pin.vehicle.kind == .tram ? "2" : "1",
            "number": String(r.pin.vehicle.number),
            "path": Polyline.encode(p.path),
            "stops": p.pathStops.map { ["n": $0.name, "lat": $0.latitude, "lon": $0.longitude] },
            "target": ["n": p.stop ?? "", "lat": p.target.latitude, "lon": p.target.longitude],
            "distance": p.distance,
        ]
        await send(method: "POST", body: body)
    }

    private static var isSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static var endpoint: URL? {
        LiveFleetService.proxy?.deletingLastPathComponent().appendingPathComponent("track")
    }

    @discardableResult
    private static func send(method: String, body: [String: Any]) async -> Bool {
        guard let url = endpoint, let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        do {
            let (reply, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok { log.error("\(method) answered \(String(decoding: reply, as: UTF8.self))") }
            return ok
        } catch {
            log.error("\(method) failed: \(error)")
            return false
        }
    }

    // MARK: - Picture

    /// A small copy of the vehicle's sticker (or photo) in the App Group, where the Live
    /// Activity can read it.
    private static func writePicture(_ sightings: [Sighting], number: Int, modelId: String) -> (name: String, cutout: Bool)? {
        let sticker = sightings.sticker(number: number, modelId: modelId)
        guard let source = sticker ?? sightings.photo(number: number, modelId: modelId),
              let data = try? Data(contentsOf: PhotoStore.url(source)),
              let cg = PhotoStore.downsample(data, maxPixel: 240),
              let png = UIImage(cgImage: cg).pngData() else { return nil }
        let name = "track-\(number).png"
        guard let url = WidgetSnapshot.imageURL(name), (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return (name, sticker != nil)
    }
}
