import AppIntents
import SwiftUI
import WidgetKit

@main
struct TaborControlsBundle: WidgetBundle {
    var body: some Widget {
        CatchControl()
        HuntControl()
        ProgressWidget()
        RecentWidget()
        RarityWidget()
        ShuffleWidget()
    }
}

/// A Lock Screen / Control Center / Action button control that jumps straight to the camera.
struct CatchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "tabor.catch") {
            ControlWidgetButton(action: OpenCatchIntent()) {
                Label("Catch", systemImage: "bus.fill")
            }
            .tint(Color(red: 1, green: 0.808, blue: 0))
        }
        .displayName("Catch a vehicle")
        .description("Open TABOR straight to the camera.")
    }
}

/// The same for HUNT: what's running near you that you haven't caught.
struct HuntControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "tabor.hunt") {
            ControlWidgetButton(action: OpenHuntIntent()) {
                Label("Hunt", systemImage: "dot.radiowaves.left.and.right")
            }
            .tint(Color(red: 0.361, green: 0.784, blue: 1))
        }
        .displayName("Hunt nearby")
        .description("Open TABOR on the live map of vehicles you haven't caught.")
    }
}
