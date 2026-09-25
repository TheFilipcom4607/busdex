import SwiftData
import SwiftUI

enum StickerSort: String {
    case number = "NUMBER", date = "DATE"
}

struct ModelPageView: View {
    let modelId: String
    @Query private var sightings: [Sighting]
    @State private var sort: StickerSort = .number
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    /// Debug: the vehicle picked for deletion, waiting for confirmation.
    @State private var deleting: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 11), count: 3)

    var body: some View {
        if let model = Fleet.catalog.model(id: modelId) {
            content(model)
        } else {
            missingModel
        }
    }

    /// A catch whose model a fleet update dropped (retired, or renamed by ZTM): a way back,
    /// not a dead end.
    private var missingModel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopBar {
                Button { dismiss() } label: { Mono("← BACK", size: 12, spacing: 0.16) }
                    .buttonStyle(.plain)
            } trailing: { EmptyView() }
            ScreenTitle(text: "Model not in the fleet data")
                .padding(.top, 16)
                .padding(.horizontal, 22)
            Text("ZTM no longer lists this model, so it has no page in the book. Your catches of it are still saved.")
                .font(TaborFont.grotesk(14))
                .foregroundStyle(Palette.sub)
                .padding(.top, 8)
                .padding(.horizontal, 22)
        }
        .taborScreen()
    }

    private func content(_ model: VehicleModel) -> some View {
        let stats = sightings.stats
        let owned = stats.owned(modelId: model.id)
        let ownedByNumber = Dictionary(uniqueKeysWithValues: owned.map { ($0.number, $0) })

        return VStack(alignment: .leading, spacing: 0) {
            TopBar {
                Button { dismiss() } label: { Mono("← ALL MODELS", size: 12, spacing: 0.16) }
                    .buttonStyle(.plain)
            } trailing: {
                Button {
                    Haptics.shared.tick()
                    withAnimation(.snappy) { sort = sort == .number ? .date : .number }
                } label: {
                    Mono("SORT: \(sort.rawValue)", size: 12)
                }
                .buttonStyle(.plain)
            }

            // Tags above the name (as on the share card), so the name and the subtitle get
            // the full width instead of wrapping and truncating next to the pill.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    KindTag(kind: model.kind)
                    TierPill(tier: model.tier, fleet: model.fleet)
                }
                // One line at full size, else one line a little smaller, else wrap on spaces.
                ViewThatFits(in: .horizontal) {
                    title(model.name, size: 27).lineLimit(1)
                    title(model.name, size: 23).lineLimit(1)
                    title(model.name, size: 25).lineLimit(2)
                }
                .padding(.top, 10)
                Mono(subtitle(model), size: 11, spacing: 0.1, color: Palette.sub)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            if let place = model.vintageWhere {
                Mono(place, size: 10.5, spacing: 0.1, color: Palette.brass)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 22)
                    .padding(.top, -6)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 11) {
                ProgressBar(fraction: Double(owned.count) / Double(max(model.fleet, 1)), color: model.tier.bar)
                OwnedCount(owned: owned.count, fleet: model.fleet)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.batches.enumerated()), id: \.offset) { i, batch in
                        batchHeader(batch, have: batch.numbers.filter { ownedByNumber[$0] != nil }.count)
                            .padding(.top, i == 0 ? 6 : 18)
                            .padding(.bottom, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                            .padding(.top, i == 0 ? 0 : 14)
                        LazyVGrid(columns: columns, spacing: 11) {
                            ForEach(ordered(batch.numbers, owned: ownedByNumber), id: \.self) { n in
                                if let v = ownedByNumber[n] {
                                    // A button, not a NavigationLink: a link steals the long press
                                    // the debug delete menu needs.
                                    Button { router.bookPath.append(.vehicle(modelId: model.id, number: n)) } label: {
                                        DieCut(number: n, sticker: sightings.sticker(number: n, modelId: model.id),
                                               photo: sightings.photo(number: n, modelId: model.id)) {
                                            if v.timesSeen > 1 {
                                                Mono("×\(v.timesSeen)", size: 9.5, spacing: 0, color: Palette.stickerCount)
                                            }
                                        }
                                        .frame(height: 104)
                                    }
                                    .buttonStyle(StickerPressStyle(tilt: stickerTilt(n)))
                                    .contextMenu { debugMenu(n) }
                                } else {
                                    EmptySlot(label: String(n)).frame(height: 104)
                                }
                            }
                        }
                    }
                    let strays = owned.filter { v in !model.numbers.contains(v.number) }
                    if !strays.isEmpty {
                        Mono("NOT IN ZTM DATABASE · ADDED BY YOU", size: 10, spacing: 0.14, color: Palette.faint)
                            .padding(.top, 32)
                            .padding(.bottom, 10)
                        LazyVGrid(columns: columns, spacing: 11) {
                            ForEach(strays, id: \.number) { v in
                                Button { router.bookPath.append(.vehicle(modelId: model.id, number: v.number)) } label: {
                                    DieCut(number: v.number, sticker: sightings.sticker(number: v.number, modelId: model.id),
                                           photo: sightings.photo(number: v.number, modelId: model.id))
                                        .frame(height: 104)
                                }
                                .buttonStyle(StickerPressStyle(tilt: stickerTilt(v.number)))
                                .contextMenu { debugMenu(v.number) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .softTopEdge()
        }
        .taborScreen()
        // String(n): a fleet number is an id, never "1,075".
        .confirmationDialog(Text(verbatim: deleting.map { "Delete #\(String($0)) from your book?" } ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            if let n = deleting {
                let count = sightings.filter { $0.number == n && $0.modelId == model.id }.count
                Button(count > 1 ? "Delete all \(count) sightings" : "Delete it", role: .destructive) { delete(n, model: model) }
            }
        } message: {
            Text("Its photos and sticker go too; the rest of your book stays. Shots saved to Photos stay. This can't be undone.")
        }
    }

    /// Debug only: long-press a caught sticker to take it out of the book.
    @ViewBuilder
    private func debugMenu(_ number: Int) -> some View {
        if debugMode {
            Button("Delete from book", systemImage: "trash", role: .destructive) {
                // Let the menu finish closing, or the dialog has nothing to present from.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    deleting = number
                }
            }
        }
    }

    private func delete(_ number: Int, model: VehicleModel) {
        sightings.filter { $0.number == number && $0.modelId == model.id }.forEach(context.deleteSighting)
        try? context.save()
        deleting = nil
        Haptics.shared.nope()
    }

    private func subtitle(_ m: VehicleModel) -> String {
        // The ZTM type code is what's painted in the depot books; the operator tells you where to look.
        var parts = [String]()
        if let code = m.code, code != m.name { parts.append(code.uppercased()) }
        parts.append(m.operators.prefix(2).joined(separator: " / ").uppercased())
        if let years = m.yearsDisplay { parts.append(years) }
        return parts.joined(separator: " · ")
    }

    private func title(_ name: String, size: CGFloat) -> some View {
        Text(name)
            .font(TaborFont.grotesk(size, 700))
            .em(-0.03, size: size)
    }

    /// "2022 BATCH · R-3 MOKOTÓW · 4209—4282" with how much of it you have; green once complete.
    private func batchHeader(_ b: Batch, have: Int) -> some View {
        let year = b.year.map { "\($0) BATCH" } ?? "YEAR UNKNOWN"
        let done = have == b.numbers.count
        return HStack(spacing: 8) {
            Mono([year, b.depotDisplay, b.rangeDisplay].filter { !$0.isEmpty }.joined(separator: " · "),
                 size: 10, spacing: 0.14, color: Palette.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Palette.green)
            }
            Mono("\(have)/\(b.numbers.count)", size: 10, weight: done ? 700 : 400, spacing: 0.06,
                 color: done ? Palette.green : have > 0 ? Palette.sub : Palette.faint)
                .fixedSize()
        }
    }

    /// Owned first (as the design shows), then the rest, by number or catch date.
    private func ordered(_ numbers: [Int], owned: [Int: OwnedVehicle]) -> [Int] {
        let have = numbers.filter { owned[$0] != nil }
        let rest = numbers.filter { owned[$0] == nil }
        switch sort {
        case .number: return have.sorted() + rest.sorted()
        case .date: return have.sorted { owned[$0]!.lastSeen > owned[$1]!.lastSeen } + rest.sorted()
        }
    }
}
