import SwiftUI

enum AppTab: String, CaseIterable {
    case catchTab = "CATCH"
    case book = "BOOK"
    case me = "ME"

    var accent: Color {
        switch self {
        case .catchTab: Palette.yellow
        case .book: Palette.red
        case .me: Palette.green
        }
    }

    var symbol: String {
        switch self {
        case .catchTab: "viewfinder"
        case .book: "square.grid.3x3.fill"
        case .me: "trophy.fill"
        }
    }
}

/// Bottom bar: icon over a mono label, lit in the tab's accent, with a soft glow
/// under the active icon and a bounce + click on switch.
struct TabBar: View {
    @Binding var selection: AppTab
    @Namespace private var glow

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button {
                    guard tab != selection else { return }
                    Haptics.shared.tab()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if on {
                                Circle()
                                    .fill(tab.accent.opacity(0.22))
                                    .frame(width: 34, height: 34)
                                    .blur(radius: 10)
                                    .matchedGeometryEffect(id: "glow", in: glow)
                            }
                            Image(systemName: tab.symbol)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(on ? tab.accent : Color.white.opacity(0.3))
                                .symbolEffect(.bounce.down, value: on)
                        }
                        .frame(height: 24)
                        Mono(tab.rawValue, size: 10, weight: on ? 600 : 400, spacing: 0.1,
                             color: on ? tab.accent : Palette.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue.capitalized)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(Palette.bg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
