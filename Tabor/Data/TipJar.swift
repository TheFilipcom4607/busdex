import Foundation
import Observation
import StoreKit

/// Tips through the App Store, which pay for the live-data server. Any of them makes you a
/// supporter (a heart on ME). The 4.99 one is a one-off unlock that stays on the Apple account;
/// the bigger two can be given again and again, and still show up in the purchase history
/// (SKIncludeConsumableInAppPurchaseHistory), so supporter comes back after a reinstall too.
@MainActor @Observable
final class TipJar {
    static let shared = TipJar()

    static let supporterID = "com.filipmanikowski.tabor.supporter"
    static let ids = [supporterID, "com.filipmanikowski.tabor.tip", "com.filipmanikowski.tabor.tip.big"]
    /// Remembered so the heart shows at once, before StoreKit answers.
    private static let supporterKey = "supporter"

    enum Outcome { case thanks, pending, cancelled, failed }

    /// Cheapest first.
    private(set) var products: [Product] = []
    private(set) var loadFailed = false
    /// The product being bought right now.
    private(set) var buying: String?
    private(set) var isSupporter = UserDefaults.standard.bool(forKey: supporterKey) {
        didSet { UserDefaults.standard.set(isSupporter, forKey: Self.supporterKey) }
    }
    /// The one-off unlock, which can't be bought twice.
    private(set) var ownsSupporter = false
    private var listening = false

    private init() {}

    /// At launch: picks up tips finished elsewhere (Ask to Buy, another device, a refund).
    func start() {
        guard !listening else { return }
        listening = true
        Task.detached {
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await TipJar.shared.refresh()
            }
        }
        Task { await refresh() }
    }

    func load() async {
        guard products.isEmpty else { return }
        do {
            products = try await Product.products(for: Self.ids).sorted { $0.price < $1.price }
            loadFailed = products.isEmpty
        } catch {
            loadFailed = true
        }
    }

    func buy(_ product: Product) async -> Outcome {
        buying = product.id
        defer { buying = nil }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                await refresh()
                return .thanks
            case .success(.unverified): return .failed
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /// For a new phone: asks the App Store for the account's purchases again.
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Supporter if any tip on this account wasn't refunded. An empty history (offline, not
    /// synced yet) keeps what we knew; only a refund takes the heart away.
    func refresh() async {
        var any = false, unlock = false, refunded = false
        for await result in Transaction.all {
            guard case .verified(let t) = result, Self.ids.contains(t.productID) else { continue }
            if t.revocationDate != nil { refunded = true; continue }
            any = true
            if t.productID == Self.supporterID { unlock = true }
        }
        if any || refunded { isSupporter = any }
        ownsSupporter = unlock
    }
}
