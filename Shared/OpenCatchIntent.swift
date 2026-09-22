import AppIntents
import Foundation

/// Opens TABOR on the Catch tab. Compiled into both the app and the controls extension:
/// the control only references it, and `openAppWhenRun` makes the system run it in the app.
struct OpenCatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Catch a vehicle"
    static let description = IntentDescription("Opens TABOR straight to the camera.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .taborOpenCatch, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let taborOpenCatch = Notification.Name("tabor.openCatch")
}
