import SwiftData
import SwiftUI

enum DexFilter: String, CaseIterable {
    case all = "ALL", bus = "BUS", tram = "TRAM", missing = "MISSING"
}

struct BookIndexView: View {
    @Query private var sightings: [Sighting]
    @State private var filter: DexFilter = .all
    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let rows = catalog.models.filter { m in
            switch filter {
            case .all: true
            case .bus: m.kind == .bus
            case .tram: m.kind == .tram
            // Prototype rule: under a quarter collected.
            case .missing: Double(stats.ownedCount(modelId: m.id)) / Double(max(m.fleet, 1)) < 0.25
            }
        }
        // Models you've started float to the top (most complete first); the rest go rarest first.
        .sorted { a, b in
            let oa = stats.ownedCount(modelId: a.id), ob = stats.ownedCount(modelId: b.id)
            if (oa > 0) != (ob > 0) { return oa > 0 }
            if oa > 0 {
                let pa = Double(oa) / Double(a.fleet), pb = Double(ob) / Double(b.fleet)
                if pa != pb { return pa > pb }
            }
            if a.fleet != b.fleet { return a.fleet < b.fleet }
            return a.name < b.name
        }

        VStack(alignment: .leading, spacing: 0) {
            TopBar {
                Mono("YOUR BOOK", size: 12, spacing: 0.16)
            } trailing: {
                // Same count as the widget: the total leaves vintage and test stock out, so the count must too.
                Mono("\(stats.fleetCaught(catalog: catalog).grouped) / \(catalog.totalFleet.grouped)", size: 12)
            }
            ScreenTitle(text: "Warsaw rolling stock")
                .padding(.top, 14)
                .padding(.horizontal, 22)
            HStack(spacing: 7) {
                ForEach(DexFilter.allCases, id: \.self) { f in
                    Button {
                        guard f != filter else { return }
                        Haptics.shared.tick()
                        withAnimation(.snappy) { filter = f }
                    } label: {
                        Mono(f.rawValue, size: 11.5, weight: 600, spacing: 0.1,
                             color: f == filter ? Palette.bg : Palette.sub)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(f == filter ? Palette.ink : Palette.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 2)
            .padding(.horizontal, 22)

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(rows.filter(\.regular)) { m in row(m, stats: stats) }
                    // Test and tourist-line stock live in sections of their own: they're
                    // passing through or seasonal, not rare.
                    let onTest = rows.filter(\.onTest)
                    if !onTest.isEmpty {
                        sectionHeader(.onTest, note: "ON TRIAL FOR A FEW WEEKS · NOT PART OF THE FLEET %")
                        ForEach(onTest) { m in row(m, stats: stats) }
                    }
                    let vintage = rows.filter(\.vintage)
                    if !vintage.isEmpty {
                        sectionHeader(.vintage, note: "TOURIST LINES ON SUMMER WEEKENDS · NOT PART OF THE FLEET %")
                        ForEach(vintage) { m in row(m, stats: stats) }
                    }
                    Mono(catalog.source.uppercased(), size: 9, spacing: 0.06, color: Palette.faint)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 18)
                }
                .padding(.top, 10)
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
            .softTopEdge()
        }
        .taborScreen()
    }

    private func sectionHeader(_ tier: Tier, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Mono(tier.rawValue, size: 10.5, weight: 700, spacing: 0.14, color: tier.color)
            Mono(note, size: 9.5, color: Palette.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private func row(_ m: VehicleModel, stats: CollectionStats) -> some View {
        NavigationLink(value: BookRoute.model(m.id)) {
            DexRow(model: m, owned: stats.ownedCount(modelId: m.id), latest: latestSticker(m.id, stats: stats))
        }
        .buttonStyle(RowPressStyle())
    }

    private func latestSticker(_ modelId: String, stats: CollectionStats) -> (number: Int, sticker: String?, photo: String?)? {
        guard let v = stats.owned(modelId: modelId).max(by: { $0.lastSeen < $1.lastSeen }) else { return nil }
        return (v.number, sightings.sticker(number: v.number, modelId: modelId), sightings.photo(number: v.number, modelId: modelId))
    }
}

struct DexRow: View {
    let model: VehicleModel
    let owned: Int
    var latest: (number: Int, sticker: String?, photo: String?)? = nil

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                KindTag(kind: model.kind)
                Text(model.name)
                    .font(TaborFont.grotesk(15, 600))
                    .em(-0.015, size: 15)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OwnedCount(owned: owned, fleet: model.fleet, size: 13)
            }
            ProgressBar(fraction: Double(owned) / Double(max(model.fleet, 1)), color: model.tier.bar, height: 5)
            HStack {
                Mono(detail, size: 10.5, spacing: 0.1)
                Spacer()
                Mono(model.tier.rawValue, size: 10, weight: 700, spacing: 0.12, color: model.tier.color)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .padding(.trailing, latest == nil ? 0 : 64)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
        // Your latest catch of this model, peeking off the edge of the row.
        .overlay(alignment: .trailing) {
            if let latest {
                DieCut(number: latest.number, sticker: latest.sticker, photo: latest.photo, height: 44, tagSize: 9, maxPixel: 240)
                    .frame(width: 74)
                    .rotationEffect(.degrees(stickerTilt(latest.number, range: 6)))
                    .offset(x: 6)
            }
        }
        .contentShape(Rectangle())
    }

    /// "2005—2016 · 9 BATCHES", or the number span for single-batch models.
    private var detail: String {
        let years = model.yearsDisplay ?? model.trial ?? "YEAR ?"
        if model.batches.count > 1 { return "\(years) · \(model.batches.count) BATCHES" }
        return "\(years) · \(model.rangeDisplay)"
    }
}

/// Rows dim and shrink a touch under the finger. Silent: navigation doesn't click.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// "3/48" with the denominator dimmed.
struct OwnedCount: View {
    let owned: Int
    let fleet: Int
    var size: CGFloat = 13

    var body: some View {
        (Text("\(owned)").foregroundStyle(Palette.ink)
            + Text("/\(fleet)").foregroundStyle(Palette.faint))
            .font(TaborFont.mono(size, 700))
    }
}

extension Int {
    /// "2 836" — thin grouping like the design.
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}
