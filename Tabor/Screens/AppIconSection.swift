import SwiftUI
import UIKit

/// The sticker on another background (#62), or another vehicle as a thank-you for a tip. The
/// sets come from `scripts/make_icon.swift`; each needs its name in the target's
/// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case black, white, blue, urbino, rotem

    var id: Self { self }

    /// nil is the main icon.
    var iconName: String? {
        switch self {
        case .black: nil
        case .white: "AppIcon-White"
        case .blue: "AppIcon-Blue"
        case .urbino: "AppIcon-Urbino"
        case .rotem: "AppIcon-Rotem"
        }
    }

    var preview: String { "\(iconName ?? "AppIcon")-Preview" }

    var label: LocalizedStringKey {
        switch self {
        case .black: "Black"
        case .white: "White"
        case .blue: "Blue"
        // Model names: the same in every language.
        case .urbino: "Urbino"
        case .rotem: "Rotem"
        }
    }

    /// Unlocked by any tip. Only extra icons, never anything you need.
    var forSupporters: Bool { self == .urbino || self == .rotem }

    @MainActor
    static var current: AppIconChoice {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == name } ?? .black
    }
}

/// Settings › App icon: a row of the icons, tap one to switch; the supporters' row below.
struct AppIconSection: View {
    @State private var current = AppIconChoice.current
    private let jar = TipJar.shared

    var body: some View {
        Section {
            row(AppIconChoice.allCases.filter { !$0.forSupporters })
            VStack(alignment: .leading, spacing: 8) {
                Text("FOR SUPPORTERS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.sub)
                row(AppIconChoice.allCases.filter(\.forSupporters))
            }
        } header: {
            Text("App icon")
        } footer: {
            if !jar.isSupporter { Text("Any tip in Support TABOR unlocks these.") }
        }
        // A refunded tip takes its icons back with it.
        .task(id: jar.isSupporter) {
            guard current.forSupporters, !jar.isSupporter else { return }
            select(.black)
        }
    }

    private func row(_ choices: [AppIconChoice]) -> some View {
        HStack(spacing: 18) {
            ForEach(choices) { button($0) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func select(_ choice: AppIconChoice) {
        current = choice
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            // Refused (it happens while the app is mid-transition): show what's really set.
            if error != nil { Task { @MainActor in current = .current } }
        }
    }

    private func button(_ choice: AppIconChoice) -> some View {
        let on = current == choice
        let locked = choice.forSupporters && !jar.isSupporter
        return Button {
            guard !on else { return }
            guard !locked else { return Haptics.shared.nope() }
            Haptics.shared.tick()
            select(choice)
        } label: {
            VStack(spacing: 6) {
                Image(choice.preview)
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    }
                    .opacity(locked ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if locked {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.red)
                                .padding(5)
                                .background(Palette.bg, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(on ? Palette.yellow : .clear, lineWidth: 2)
                    }
                Text(choice.label)
                    .font(.footnote)
                    .foregroundStyle(on ? Palette.ink : Palette.sub)
            }
        }
        // Plain, or a List row fires every button in it on any tap.
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(locked ? Text("Any tip in Support TABOR unlocks these.") : Text(verbatim: ""))
    }
}
