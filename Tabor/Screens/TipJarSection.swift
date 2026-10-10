import StoreKit
import SwiftUI

/// Settings › Support TABOR: three tips. Any tip unlocks three extra app icons (#62); badges and
/// everything else stay free.
struct TipJarSection: View {
    private var jar: TipJar { .shared }
    @State private var message: String?
    /// "Thank you" only heads the alert when a tip went through or a restore found one.
    @State private var thanks = false
    @State private var restoring = false

    var body: some View {
        Section {
            if jar.products.isEmpty {
                HStack {
                    Text(jar.loadFailed ? "Tips aren't available right now." : "Loading…")
                        .foregroundStyle(Palette.sub)
                    Spacer()
                    if !jar.loadFailed { ProgressView().controlSize(.small) }
                }
            }
            ForEach(jar.products) { product in
                row(product)
            }
            Button(restoring ? "Restoring…" : "Restore purchases") {
                restoring = true
                Task {
                    let outcome = await jar.restore()
                    restoring = false
                    switch outcome {
                    case .done:
                        thanks = jar.isSupporter
                        message = jar.isSupporter ? String(localized: "You're a supporter. Thank you! 💛")
                            : String(localized: "No tips found on this Apple account.")
                    case .failed:
                        thanks = false
                        message = String(localized: "Couldn't reach the App Store. Try again later.")
                    case .cancelled: break
                    }
                }
            }
            .disabled(restoring)
        } header: {
            Text("Support TABOR")
        } footer: {
            Text("TABOR is free, with no ads. Tips pay for the server behind HUNT's live map and the Apple developer fee. Any tip puts a heart next to ME and unlocks three extra app icons; badges and everything else stay free.")
        }
        .task { await jar.load() }
        .alert(thanks ? "Thank you" : "Support TABOR", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func row(_ product: Product) -> some View {
        let owned = product.id == TipJar.supporterID && jar.ownsSupporter
        return Button {
            Task {
                let wasSupporter = jar.isSupporter
                let outcome = await jar.buy(product)
                thanks = outcome == .thanks
                switch outcome {
                case .thanks:
                    Haptics.shared.completed()
                    message = wasSupporter ? String(localized: "Thanks for the tip! 💛")
                        : String(localized: "You're a supporter now. Thank you! 💛")
                case .pending:
                    message = String(localized: "Waiting for approval. The heart appears once it goes through.")
                case .failed:
                    message = String(localized: "That didn't go through. You weren't charged.")
                case .cancelled: break
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).foregroundStyle(Palette.ink)
                    Text(product.description).font(.footnote).foregroundStyle(Palette.sub)
                }
                Spacer(minLength: 8)
                if jar.buying == product.id {
                    ProgressView().controlSize(.small)
                } else if owned {
                    Image(systemName: "checkmark").foregroundStyle(Palette.green)
                } else {
                    Text(product.displayPrice)
                        .font(TaborFont.mono(13, 700))
                        .foregroundStyle(Palette.bg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // One width for all three, so the prices line up.
                        .frame(minWidth: 104)
                        .background(Palette.yellow, in: Capsule())
                }
            }
        }
        .disabled(owned || jar.buying != nil)
    }
}
