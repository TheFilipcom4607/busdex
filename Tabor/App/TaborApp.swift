import SwiftData
import SwiftUI

@main
struct TaborApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchGate()
                .preferredColorScheme(.dark)
                .windowControlsClearance()
        }
        .modelContainer(TaborStore.container)
    }
}

extension View {
    /// On an iPad, TABOR runs as an iPhone app in a phone-shaped window whose controls (the
    /// three dots) sit over its top-left corner, right where every screen's header is. The
    /// safe area there starts too high, so push it down; iPhones are untouched. Full-screen
    /// covers don't inherit it, so they call this too.
    func windowControlsClearance() -> some View {
        safeAreaPadding(.top, UIDevice.current.model.hasPrefix("iPad") ? 26 : 0)
    }
}

/// Onboarding first, the app after. Someone who already has catches (an existing user, or
/// a restored backup) goes straight in.
struct LaunchGate: View {
    static let onboardedKey = "onboarded"
    @AppStorage(Self.onboardedKey) private var onboarded = false
    @Query(Self.oneCatch) private var anyCatch: [Sighting]

    private static var oneCatch: FetchDescriptor<Sighting> {
        var d = FetchDescriptor<Sighting>()
        d.fetchLimit = 1
        return d
    }

    var body: some View {
        if onboarded || !anyCatch.isEmpty {
            RootView()
                .transition(.opacity)
        } else {
            OnboardingView { withAnimation(.easeInOut(duration: 0.35)) { onboarded = true } }
                .transition(.opacity)
        }
    }
}

enum BookRoute: Hashable {
    case model(String)
    case vehicle(modelId: String, number: Int)
}

@Observable
final class Router {
    var tab: AppTab = .catchTab
    var bookPath: [BookRoute] = []
    /// Goes up when a photo shared from another app is waiting in `ShareInbox`: CATCH takes it.
    var sharedPhotos = 0
    /// A model sent from its page in the book (#45): HUNT frames where it's running, then clears it.
    var huntModel: String?
    /// A running vehicle ("BUS#1998") HUNT centres on and opens, from a Live Activity tap (#61).
    var huntVehicle: String?

    /// A photo shared to TABOR: catch it on CATCH, like one picked from the library.
    func catchShared() {
        guard !ShareInbox.isEmpty else { return }
        tab = .catchTab
        bookPath.removeAll()
        sharedPhotos += 1
    }

    /// The number just stuck in: its model page scrolls to it, then clears it (#51).
    var landing: Int?
    /// Held while the reveal is still up, so the page scrolls once it's on screen rather than
    /// after a guessed delay.
    private var pendingLanding: Int?

    /// A model's page in the book; after sticking a catch in, scrolled to where it went once
    /// the reveal has gone (`revealGone`, from the reveal's onDisappear).
    func openModel(_ id: String, landing: Int? = nil) {
        tab = .book
        bookPath = [.model(id)]
        pendingLanding = landing
    }

    func revealGone() {
        landing = pendingLanding
        pendingLanding = nil
    }

    /// Its vehicles on HUNT's map. The filter is already set; the book keeps its place.
    func showOnHunt(_ modelId: String) {
        huntModel = modelId
        tab = .hunt
    }

    func showOnHunt(vehicle id: String) {
        huntVehicle = id
        tab = .hunt
    }

    func openVehicle(modelId: String, number: Int) {
        tab = .book
        bookPath = [.model(modelId), .vehicle(modelId: modelId, number: number)]
    }
}

struct RootView: View {
    @State private var router = Router()
    @State private var badges = BadgeTracker()
    @State private var undo = SightingUndo()
    /// Tabs opened so far. They stay alive behind the current one, so switching back is
    /// instant and keeps where you were: HUNT's map and pins, how far down the book you were.
    @State private var opened: Set<AppTab> = []
    @State private var tabBarHeight: CGFloat = 0
    @Query private var sightings: [Sighting]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // CATCH goes when you leave it: that's what turns the camera off.
            if router.tab == .catchTab { CatchView() }
            if keeps(.hunt) { HuntView().tabLayer(on: router.tab == .hunt) }
            if keeps(.book) { BookTab(tabBarHeight: tabBarHeight).tabLayer(on: router.tab == .book) }
            if keeps(.me) { MeView().tabLayer(on: router.tab == .me) }
        }
        .onChange(of: router.tab, initial: true) { _, tab in opened.insert(tab) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if undo.pending != nil {
                UndoToast {
                    let reopen = undo.closedPage
                    Haptics.shared.tick()
                    guard let back = withAnimation(.snappy, { undo.undo(in: context) }) else { return }
                    if reopen { router.openVehicle(modelId: back.modelId, number: back.number) }
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: undo.pending?.id)
        // An inset rather than a stacked row: lists scroll on under the frosted bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selection: $router.tab) { tab in
                // Like any tab bar: tapping BOOK again goes back to the index.
                if tab == .book, !router.bookPath.isEmpty { router.bookPath.removeAll() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabBarHeight = $0 }
        }
        .background(Palette.bg.ignoresSafeArea())
        .environment(router)
        .environment(undo)
        // Keep the live feed ticking on every tab, so HUNT opens with trails already drawn.
        .onAppear { LiveFleetService.shared.start(LiveFleetService.appClient) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                LiveFleetService.shared.start(LiveFleetService.appClient)
                // Shared while TABOR was closed, or the share sheet couldn't open it.
                router.catchShared()
            }
            if phase == .background {
                LiveFleetService.shared.stop(LiveFleetService.appClient)
                undo.finish()
            }
        }
        // The Lock Screen / Control Center control lands here.
        .onReceive(NotificationCenter.default.publisher(for: .taborOpenCatch)) { _ in
            router.tab = .catchTab
            // They've found the control on their own: no need to tip them off about it.
            UserDefaults.standard.set(true, forKey: CatchControlTip.seenKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .taborOpenHunt)) { _ in
            router.tab = .hunt
            UserDefaults.standard.set(true, forKey: CatchControlTip.seenKey)
        }
        // Widget taps.
        .onOpenURL { url in
            if url == ShareInbox.url { return router.catchShared() }
            switch WidgetLink.target(url) {
            case .book:
                router.tab = .book
                router.bookPath.removeAll()
            case .vehicle(let modelId, let number):
                router.openVehicle(modelId: modelId, number: number)
            case .hunt(let id):
                // A Live Activity, not a widget: nothing to say about the widget tip.
                return router.showOnHunt(vehicle: id)
            case nil:
                return
            }
            // Only a widget on the Home Screen sends these: no need for the widget tip.
            UserDefaults.standard.set(true, forKey: WidgetTip.seenKey)
        }
        .overlay(alignment: .top) {
            if let unlock = badges.current {
                BadgeToast(unlock: unlock) {
                    badges.dismiss()
                    router.tab = .me
                } onDismiss: {
                    badges.dismiss()
                }
                .id(unlock.id)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await FleetUpdater.checkIfDue() }
        .task { TipJar.shared.start() }
        // Badges: celebrate anything newly earned, and fill in weather for the weather ones.
        // A catch saves several times in its first seconds (photo, sticker, place, weather):
        // let it settle, then work the rules out off the main thread, which animates the book.
        .task(id: sightings.map(\.record)) {
            let records = sightings.map(\.record), catalog = Fleet.catalog
            guard await settled() else { return }
            let earned = await Task.detached(priority: .utility) { Achievements.evaluate(records, catalog: catalog) }.value
            guard !Task.isCancelled else { return }
            badges.update(earned)
            await WeatherService.backfill(sightings, context: context)
        }
        // Refresh the Home / Lock Screen widgets whenever what they show could have changed.
        .task(id: widgetKey) {
            guard await settled() else { return }
            await WidgetBridge.publish(sightings)
            // A tracked vehicle just went into the book: its Live Activity says so and ends.
            TrackService.shared.endCaught(sightings)
        }
    }

    private func keeps(_ tab: AppTab) -> Bool { router.tab == tab || opened.contains(tab) }

    /// Waits for the book to stop changing; false when it changed again meanwhile (the task
    /// was replaced by a newer one).
    private func settled() async -> Bool {
        (try? await Task.sleep(for: .seconds(2))) != nil
    }

    private var widgetKey: String {
        let latest = sightings.max { $0.date < $1.date }
        let vehicles = Set(sightings.map { "\($0.modelId)#\($0.number)" }).count
        return [String(sightings.count), String(vehicles), latest?.id.uuidString, latest?.modelId, latest.map { String($0.number) },
                latest?.stickerFile, latest?.photoFile,
                // A picture picked for the book changes the cards too.
                sightings.filter { $0.cover == true }.map(\.id.uuidString).sorted().joined()].map { $0 ?? "-" }.joined(separator: "|")
    }
}

struct BookTab: View {
    /// The tab bar's inset stops at the NavigationStack, so each page gets it again here,
    /// or the end of every book list runs under the bar (#43).
    let tabBarHeight: CGFloat
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.bookPath) {
            BookIndexView()
                .safeAreaPadding(.bottom, tabBarHeight)
                .navigationDestination(for: BookRoute.self) { route in
                    Group {
                        switch route {
                        case .model(let id): ModelPageView(modelId: id)
                        case .vehicle(let modelId, let number): VehicleView(modelId: modelId, number: number)
                        }
                    }
                    .safeAreaPadding(.bottom, tabBarHeight)
                }
        }
    }
}

private extension View {
    /// A kept-alive tab: on top when it's the current one, otherwise invisible and out of the way.
    func tabLayer(on: Bool) -> some View {
        opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .zIndex(on ? 1 : 0)
    }
}

extension View {
    /// Custom headers replace the system navigation bar everywhere.
    func taborScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Scrolled content runs up under the Dynamic Island; fade it out behind the clock.
            .overlay { StatusBarScrim() }
            .background(Palette.bg.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Solid behind the status bar, fading out just below it.
struct StatusBarScrim: View {
    var body: some View {
        GeometryReader { g in
            let top = g.safeAreaInsets.top, fade: CGFloat = 10
            LinearGradient(stops: [
                .init(color: Palette.bg.opacity(0.96), location: 0),
                .init(color: Palette.bg.opacity(0.85), location: top / (top + fade)),
                .init(color: Palette.bg.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: top + fade)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// Keep the edge-swipe back gesture even though every screen hides the system nav bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
