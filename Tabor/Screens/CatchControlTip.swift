import SwiftUI

/// The Lock Screen / Control Center / Action button control is the fastest way to a passing
/// bus, but nothing in the system advertises it. CATCH mentions it once, after a few catches,
/// when you know the app and have likely fumbled with Face ID while a bus pulled away.
enum CatchControlTip {
    static let seenKey = "catchControlTipSeen"
    static let afterCatches = 3
}

/// Sits in CATCH's read-chip slot while nothing is read, so it never covers the brackets.
struct CatchControlTipCard: View {
    var open: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 11) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.bg)
                        .frame(width: 34, height: 34)
                        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Mono("BUSES DON'T WAIT", size: 9.5, weight: 700, spacing: 0.12, color: Palette.yellow)
                        Text("Catch straight from the Lock Screen")
                            .font(TaborFont.grotesk(13.5, 600))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 9)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// How to put the catch control where a thumb can reach it without unlocking.
struct CatchControlHowTo: View {
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.track).frame(width: 36, height: 4).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Mono("CATCH FASTER", size: 10.5, weight: 600, spacing: 0.14, color: Palette.yellow)
                        Text("One tap, camera on")
                            .font(TaborFont.grotesk(26, 600))
                        Text("TABOR has a Catch button for your Lock Screen, Control Center and Action button. It opens straight to the camera, even from a locked phone.")
                            .font(TaborFont.grotesk(14))
                            .foregroundStyle(Palette.sub)
                    }
                    place("lock.fill", title: String(localized: "Lock Screen"), steps: [
                        String(localized: "Touch and hold the Lock Screen, then tap Customize."),
                        String(localized: "Tap one of the buttons at the bottom, or − to clear one first."),
                        String(localized: "Search for TABOR and pick Catch a vehicle."),
                    ])
                    place("switch.2", title: String(localized: "Control Center"), steps: [
                        String(localized: "Swipe down from the top-right corner."),
                        String(localized: "Tap + at the top left, then Add a Control."),
                        String(localized: "Search for TABOR and pick Catch a vehicle."),
                    ])
                    place("button.horizontal.top.press", title: String(localized: "Action button"), steps: [
                        String(localized: "On iPhones that have one: Settings › Action Button."),
                        String(localized: "Swipe to Controls, then choose Catch a vehicle."),
                    ])
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(Palette.bg)
    }

    private func place(_ icon: String, title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.yellow)
                    .frame(width: 20)
                Text(title).font(TaborFont.grotesk(16, 600))
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Mono("\(i + 1)", size: 11, weight: 700, color: Palette.faint)
                        .frame(width: 20)
                    Text(step)
                        .font(TaborFont.grotesk(14))
                        .foregroundStyle(Palette.routeInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
    }
}
