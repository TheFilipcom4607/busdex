import SwiftData
import SwiftUI

enum StickerSort: String {
    case number = "NUMBER", date = "DATE"

    var name: String {
        switch self {
        case .number: String(localized: "NUMBER", comment: "Sort stickers by")
        case .date: String(localized: "DATE", comment: "Sort stickers by")
        }
    }
}

struct ModelPageView: View {
    let modelId: String
    @Query private var sightings: [Sighting]
    @State private var sort: StickerSort = .number
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    @AppStorage("huntTargets") private var huntTargets = HuntTargets()
    @AppStorage("huntFilter") private var huntFilter: HuntFilter = .uncaught
    /// Debug: the vehicle picked for deletion, waiting for confirmation.
    @State private var deleting: Int?
    /// The sticker just stuck in, bouncing once it's scrolled into view.
    @State private var landed: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router

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
            ScreenTitle(text: String(localized: "Model not in the fleet data"))
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
                    Mono("SORT: \(sort.name)", size: 12)
                }
                .buttonStyle(.plain)
            }

            // Tags above the name (as on the share card), so the name and the subtitle get
            // the full width instead of wrapping and truncating next to the pill.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    KindTag(kind: model.kind)
                    TierPill(tier: model.tier, fleet: model.fleet)
                    Spacer(minLength: 0)
                    if owned.count < model.fleet {
                        showOnMapButton(model, haveSome: !owned.isEmpty)
                    }
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

            if let place = model.whereToFind {
                // Wraps rather than shrinking away: a test bus's lines and dates run long.
                Mono(place, size: 10.5, spacing: 0.1, color: model.tier.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.top, -6)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 11) {
                ProgressBar(fraction: Double(owned.count) / Double(max(model.fleet, 1)), color: model.tier.bar)
                OwnedCount(owned: owned.count, fleet: model.fleet)
            }
            .padding(.horizontal, 22)
            // The scroll's soft top edge makes up the rest of the gap.
            .padding(.bottom, 4)

            ScrollViewReader { reader in
                ScrollView {
                    // One lazy stack of rows, not a lazy grid per batch: scrolled to a catch far down,
                    // the nested grids guessed their heights, and a sticker redrawn mid-way (its bounce)
                    // threw the page back up or to the bottom (TestFlight, 123N #2158).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // At the top of the scroll rather than above it, so the stickers keep the room.
                        // Starts below the soft top edge, which should only fade what's scrolled up.
                        if let spread = model.spread {
                            specsRow(spread, kind: model.kind)
                                .padding(.top, Self.softEdge)
                                .padding(.bottom, 16)
                        }
                        ForEach(Array(model.batches.enumerated()), id: \.offset) { i, batch in
                            batchHeader(batch, have: batch.numbers.filter { ownedByNumber[$0] != nil }.count, trial: model.trialDisplay,
                                        drive: model.drive(of: batch))
                                // The first one clears the soft top edge itself when there's no specs
                                // row above it (works cars, older vintage): otherwise it starts faded.
                                .padding(.top, i == 0 ? (model.spread == nil ? Self.softEdge : 6) : 18)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                                .padding(.top, i == 0 ? 0 : 14)
                            stickerRows(ordered(batch.numbers, owned: ownedByNumber), grid: i) { n in
                                if let v = ownedByNumber[n] {
                                    sticker(n, model: model, timesSeen: v.timesSeen)
                                } else {
                                    EmptySlot(label: FleetNumber.label(n)).frame(height: Self.cell)
                                }
                            }
                        }
                        let strays = owned.filter { v in !model.numbers.contains(v.number) }
                        if !strays.isEmpty {
                            Mono("NOT IN ZTM DATABASE · ADDED BY YOU", size: 10, spacing: 0.14, color: Palette.faint)
                                .padding(.top, 32)
                                .padding(.bottom, 10)
                            stickerRows(strays.map(\.number), grid: Self.strays) { n in sticker(n, model: model, timesSeen: 1) }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                    .fitScrollWidth()
                }
                .scrollIndicators(.hidden)
                .softTopEdge(Self.softEdge)
                // A catch just stuck in: down to it, wherever its batch is, rather than the top (#51).
                .task(id: router.landing) {
                    guard let n = router.landing, let row = row(of: n, model: model, owned: owned) else { return }
                    // Cleared so coming back from a vehicle page doesn't scroll again, but only at the
                    // end: it's the task's id, and changing it cancels the task.
                    defer { router.landing = nil }
                    // The reveal has gone by now (`Router.revealGone`); a beat for the page to settle.
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.easeInOut(duration: 0.45)) { reader.scrollTo(row, anchor: .center) }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { landed = n }
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { landed = nil }
                }
            }
        }
        .taborScreen()
        // String(n): a fleet number is an id, never "1,075".
        .confirmationDialog(deleting.map { Text("Delete #\(FleetNumber.label($0)) from your book?") } ?? Text(verbatim: ""),
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

    private static let softEdge: CGFloat = 16
    private static let cell: CGFloat = 104, columns = 3
    /// The strays' grid, after the batches.
    private static let strays = -1

    /// One row of stickers, the scroll's target for a catch in it.
    private struct Row: Hashable {
        let grid: Int, index: Int
    }

    /// Numbers three to a row, each row its own item in the lazy stack.
    private func stickerRows(_ numbers: [Int], grid: Int, @ViewBuilder cell: @escaping (Int) -> some View) -> some View {
        let rows = stride(from: 0, to: numbers.count, by: Self.columns).map { Array(numbers[$0..<min($0 + Self.columns, numbers.count)]) }
        return ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
            HStack(spacing: 11) {
                ForEach(0..<Self.columns, id: \.self) { c in
                    Group {
                        if c < row.count { cell(row[c]) } else { Color.clear.frame(height: Self.cell) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, r == 0 ? 0 : 11)
            .id(Row(grid: grid, index: r))
        }
    }

    private func sticker(_ n: Int, model: VehicleModel, timesSeen: Int) -> some View {
        // A button, not a NavigationLink: a link steals the long press the debug delete menu needs.
        Button { router.bookPath.append(.vehicle(modelId: model.id, number: n)) } label: {
            DieCut(number: n, sticker: sightings.sticker(number: n, modelId: model.id),
                   photo: sightings.photo(number: n, modelId: model.id)) {
                if timesSeen > 1 {
                    Mono("×\(timesSeen)", size: 9.5, spacing: 0, color: Palette.stickerCount)
                }
            }
            .frame(height: Self.cell)
            .scaleEffect(landed == n ? 1.12 : 1)
        }
        .buttonStyle(StickerPressStyle(tilt: stickerTilt(n)))
        .contextMenu { debugMenu(n) }
    }

    /// The row a caught number's sticker is in, laid out as the page draws it.
    private func row(of n: Int, model: VehicleModel, owned: [OwnedVehicle]) -> Row? {
        guard owned.contains(where: { $0.number == n }) else { return nil }
        if let i = model.batches.firstIndex(where: { $0.numbers.contains(n) }) {
            let byNumber = Dictionary(uniqueKeysWithValues: owned.map { ($0.number, $0) })
            return ordered(model.batches[i].numbers, owned: byNumber).firstIndex(of: n).map { Row(grid: i, index: $0 / Self.columns) }
        }
        // In the order the strays' rows draw them.
        return owned.filter { !model.numbers.contains($0.number) }.firstIndex { $0.number == n }
            .map { Row(grid: Self.strays, index: $0 / Self.columns) }
    }

    /// Length, drive and room, from the city's open data; each tile only if it's known. A model
    /// the city lists under several types shows each drive and the range of the rest.
    private func specsRow(_ s: SpecsSpread, kind: VehicleKind) -> some View {
        let drives = s.drives.isEmpty && kind == .tram ? [ModelSpecs.Drive.electric] : s.drives
        let airCon: String? = switch s.airCon {
        case .all: String(localized: "Air-conditioned")
        case .none: String(localized: "No air-con")
        case .some: String(localized: "Some air-conditioned")
        case nil: nil
        }
        let metres = FloatingPointFormatStyle<Double>(locale: .app).precision(.fractionLength(0...1))
        return HStack(spacing: 9) {
            if let m = s.metres {
                StatTile(label: String(localized: "LENGTH"), value: "\(span(m) { $0.formatted(metres) }) M",
                         valueSize: 17, caption: s.floor?.name, stretch: true)
            }
            if !drives.isEmpty {
                // One drive a line: "ELECTRIC / DIESEL" on one would shrink to fit a third of the screen.
                StatTile(label: String(localized: "DRIVE"), value: drives.map(\.name).joined(separator: " /\n"),
                         valueSize: 17, valueLines: drives.count, caption: airCon, stretch: true)
            }
            if let places = s.places {
                StatTile(label: String(localized: "PASSENGERS"), value: span(places) { "\($0)" }, valueSize: 17,
                         caption: s.seats.map { String(localized: "\(span($0) { "\($0)" }) seated") }, stretch: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "18", or "10.5—12" where the vehicles differ. Word joiners keep a range on one line:
    /// "siedzących: 25—29" otherwise broke before the dash on a 390 pt phone.
    private func span<T>(_ r: ClosedRange<T>, _ show: (T) -> String) -> String {
        r.lowerBound == r.upperBound ? show(r.lowerBound) : "\(show(r.lowerBound))\u{2060}—\u{2060}\(show(r.upperBound))"
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
    /// The drive goes after the year when the model has more than one.
    private func batchHeader(_ b: Batch, have: Int, trial: String?, drive: ModelSpecs.Drive?) -> some View {
        let year = b.year.map { String(localized: "\(String($0)) BATCH") } ?? trial ?? String(localized: "YEAR UNKNOWN")
        let done = have == b.numbers.count
        return HStack(spacing: 8) {
            Mono([year, drive?.name ?? "", b.placeDisplay, b.rangeDisplay].filter { !$0.isEmpty }.joined(separator: " · "),
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
    /// Adds the model to HUNT's filter and goes to where it's running (#45).
    private func showOnMapButton(_ model: VehicleModel, haveSome: Bool) -> some View {
        Button {
            Haptics.shared.tick()
            huntTargets = huntTargets.adding(model)
            // MISSING hides a model you already have, so it would show nothing.
            if haveSome, huntFilter == .newModels { huntFilter = .uncaught }
            router.showOnHunt(model.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                Mono("SHOW ON MAP", size: 10.5, weight: 600, spacing: 0.1, color: Palette.radar)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Palette.radar.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(Palette.radar.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show on the HUNT map")
    }

    private func ordered(_ numbers: [Int], owned: [Int: OwnedVehicle]) -> [Int] {
        let have = numbers.filter { owned[$0] != nil }
        let rest = numbers.filter { owned[$0] == nil }
        switch sort {
        case .number: return have.sorted() + rest.sorted()
        case .date: return have.sorted { owned[$0]!.lastSeen > owned[$1]!.lastSeen } + rest.sorted()
        }
    }
}
