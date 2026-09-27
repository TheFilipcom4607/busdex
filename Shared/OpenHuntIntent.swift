import AppIntents
import Foundation

/// Opens TABOR on HUNT, for the second control. Works like `OpenCatchIntent`.
struct OpenHuntIntent: AppIntent {
    static let title: LocalizedStringResource = "Hunt nearby"
    static let description = IntentDescription("Opens TABOR on the live map of vehicles you haven't caught.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .taborOpenHunt, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let taborOpenHunt = Notification.Name("tabor.openHunt")
}
