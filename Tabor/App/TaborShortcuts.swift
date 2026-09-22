import AppIntents

/// Surfaces "Catch a vehicle" in Siri, Spotlight and the Shortcuts app.
struct TaborShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCatchIntent(),
                    phrases: ["Catch a vehicle with \(.applicationName)", "Open \(.applicationName) camera"],
                    shortTitle: "Catch",
                    systemImageName: "bus.fill")
    }
}
