import SwiftData
import SwiftUI

@main
struct TaborApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Sighting.self, ManualAssignment.self])
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

    /// After sticking a catch in: jump to its model page in the book.
    func openModel(_ id: String) {
        tab = .book
        bookPath = [.model(id)]
    }

    func openVehicle(modelId: String, number: Int) {
        tab = .book
        bookPath = [.model(modelId), .vehicle(modelId: modelId, number: number)]
    }
}

struct RootView: View {
    @State private var router = Router()

    var body: some View {
        ZStack {
            switch router.tab {
            case .catchTab: CatchView()
            case .book: BookTab()
            case .me: MeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // An inset rather than a stacked row: lists scroll on under the frosted bar.
        .safeAreaInset(edge: .bottom, spacing: 0) { TabBar(selection: $router.tab) }
        .background(Palette.bg.ignoresSafeArea())
        .environment(router)
        // The Lock Screen / Control Center control lands here.
        .onReceive(NotificationCenter.default.publisher(for: .taborOpenCatch)) { _ in
            router.tab = .catchTab
        }
    }
}

struct BookTab: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.bookPath) {
            BookIndexView()
                .navigationDestination(for: BookRoute.self) { route in
                    switch route {
                    case .model(let id): ModelPageView(modelId: id)
                    case .vehicle(let modelId, let number): VehicleView(modelId: modelId, number: number)
                    }
                }
        }
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
