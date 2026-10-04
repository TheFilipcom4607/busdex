import SwiftUI
import WidgetKit

/// Nothing in iOS tells you an app has widgets. ME mentions them once there's something to
/// show in one, and goes quiet for good once you've added any (or dismissed the tip).
enum WidgetTip {
    static let seenKey = "widgetTipSeen"
    static let afterCatches = 3

    /// Whether any TABOR widget is on the Home or Lock Screen.
    static func anyInstalled() async -> Bool {
        let configs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return configs.contains { WidgetSnapshot.bookKinds.contains($0.kind) }
    }
}

struct WidgetTipCard: View {
    var open: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 11) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.bg)
                        .frame(width: 34, height: 34)
                        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Mono("NEW: WIDGETS", size: 9.5, weight: 700, spacing: 0.12, color: Palette.yellow)
                        Text("Put your book on your Home Screen")
                            .font(TaborFont.grotesk(13.5, 600))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 9)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// The widgets, drawn with your own book in them, and how to add one.
struct WidgetHowTo: View {
    @State private var snapshot = WidgetSnapshot.load() ?? .empty
    @State private var showControls = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.track).frame(width: 36, height: 4).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Mono("WIDGETS", size: 10.5, weight: 600, spacing: 0.14, color: Palette.yellow)
                        Text("Your book, one glance away")
                            .font(TaborFont.grotesk(26, 600))
                        Text("Your stats, a catch from this day in the past, your newest stickers, your rarity sets, or a different sticker every hour. They update after every catch.")
                            .font(TaborFont.grotesk(14))
                            .foregroundStyle(Palette.sub)
                    }

                    previews

                    HowToSteps(icon: "apps.iphone", title: String(localized: "Home Screen"), steps: [
                        String(localized: "Touch and hold an empty spot on the Home Screen until the apps jiggle."),
                        String(localized: "Tap Edit at the top left, then Add Widget."),
                        String(localized: "Search for TABOR, swipe to the widget and size you like, then tap Add Widget."),
                    ])
                    HowToSteps(icon: "lock.fill", title: String(localized: "Lock Screen"), steps: [
                        String(localized: "Touch and hold the Lock Screen, then tap Customize › Lock Screen."),
                        String(localized: "Tap the row under the clock and pick TABOR: your streak and progress fit there."),
                    ])

                    Button {
                        showControls = true
                    } label: {
                        HStack {
                            Text("Catch and Hunt buttons for Control Center")
                                .font(TaborFont.grotesk(14, 600))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(Palette.yellow)
                        .padding(15)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
                    }
                    .buttonStyle(.plain)
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
        .sheet(isPresented: $showControls) { CatchControlHowTo() }
        .onAppear { snapshot = WidgetSnapshot.load() ?? .empty }
    }

    private var previews: some View {
        VStack(spacing: 18) {
            preview(String(localized: "Stats"), family: .systemMedium) {
                StatsWidgetView(summary: snapshot.period(.month), snapshot: snapshot, family: .systemMedium)
            }
            preview(String(localized: "Memories"), family: .systemMedium) {
                MemoryWidgetView(memory: snapshot.memory(on: .now), family: .systemMedium)
            }
            preview(String(localized: "Latest catches"), family: .systemMedium) {
                RecentWidgetView(snapshot: snapshot, family: .systemMedium)
            }
            HStack(alignment: .top, spacing: 16) {
                preview(String(localized: "Your book"), family: .systemSmall) {
                    ProgressWidgetView(entry: ProgressEntry(date: .now, snapshot: snapshot, image: latestImage), family: .systemSmall)
                }
                preview(String(localized: "Sticker shuffle"), family: .systemSmall) {
                    ShuffleWidgetView(entry: ShuffleEntry(date: .now, snapshot: snapshot, card: snapshot.shuffleCard(at: .now)),
                                      family: .systemSmall)
                }
            }
            preview(String(localized: "Rarity sets"), family: .systemMedium) {
                RarityWidgetView(snapshot: snapshot, family: .systemMedium)
            }
        }
        // They're pictures here; the links inside only work on the Home Screen.
        .allowsHitTesting(false)
    }

    private var latestImage: UIImage? {
        snapshot.hasImage ? WidgetSnapshot.imageURL.flatMap { UIImage(contentsOfFile: $0.path) } : nil
    }

    /// A widget at its Home Screen shape: 170 pt squares, 364 × 170 for medium on a 402 pt phone.
    private func preview<V: View>(_ name: String, family: WidgetFamily, @ViewBuilder content: () -> V) -> some View {
        VStack(spacing: 7) {
            content()
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WidgetPalette.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.09)))
                .aspectRatio(family == .systemSmall ? 1 : 364 / 170, contentMode: .fit)
            Mono(name.uppercased(), size: 9.5, weight: 600, spacing: 0.1, color: Palette.sub)
        }
    }
}
