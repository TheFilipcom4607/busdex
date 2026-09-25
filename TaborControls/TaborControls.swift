import AppIntents
import SwiftUI
import WidgetKit

@main
struct TaborControlsBundle: WidgetBundle {
    var body: some Widget {
        CatchControl()
        ProgressWidget()
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
