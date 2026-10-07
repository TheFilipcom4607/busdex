import SwiftUI
import UIKit

/// The sticker on another background (#62). The sets come from `scripts/make_icon.swift`;
/// each needs its name in the target's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case black, white, blue

    var id: Self { self }

    /// nil is the main icon.
    var iconName: String? {
        switch self {
        case .black: nil
        case .white: "AppIcon-White"
        case .blue: "AppIcon-Blue"
        }
    }

    var preview: String { "\(iconName ?? "AppIcon")-Preview" }

    var label: LocalizedStringKey {
        switch self {
        case .black: "Black"
        case .white: "White"
        case .blue: "Blue"
        }
    }

    @MainActor
    static var current: AppIconChoice {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == name } ?? .black
    }
}

/// Settings › App icon: a row of the icons, tap one to switch.
struct AppIconSection: View {
    @State private var current = AppIconChoice.current

    var body: some View {
        Section {
            HStack(spacing: 18) {
                ForEach(AppIconChoice.allCases) { choice in
                    button(choice)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        } header: {
            Text("App icon")
        }
    }

    private func button(_ choice: AppIconChoice) -> some View {
        let on = current == choice
        return Button {
            guard !on else { return }
            Haptics.shared.tick()
            current = choice
            UIApplication.shared.setAlternateIconName(choice.iconName) { error in
                // Refused (it happens while the app is mid-transition): show what's really set.
                if error != nil { Task { @MainActor in current = .current } }
            }
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
    }
}
