import SwiftData
import SwiftUI

struct VehicleView: View {
    let modelId: String
    let number: Int
    @Query(sort: \Sighting.date, order: .reverse) private var sightings: [Sighting]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @State private var share: CatchShare?
    @State private var editing: Sighting?
    @Environment(SightingUndo.self) private var undo

    var body: some View {
        let model = Fleet.catalog.model(id: modelId)
        let mine = sightings.filter { $0.number == number && $0.modelId == modelId }
        let first = mine.last
        let batch = model?.batch(containing: number)

        // A plain List rather than a ScrollView so sightings can be swiped to edit or delete.
        return List {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Button { dismiss() } label: {
                        Mono("← \((model?.name ?? String(localized: "BACK")).uppercased())", size: 12, spacing: 0.16)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } trailing: {
                    if let share {
                        ShareLink(item: Image(uiImage: share.image), subject: Text(share.title), message: Text(share.message),
                                  preview: SharePreview(share.title, image: Image(uiImage: share.image))) {
                            Mono("SHARE", size: 12)
                        }
                        // Plain, or a List row fires every button in it on any tap.
                        .buttonStyle(.plain)
                    }
                }

                HStack(alignment: .bottom, spacing: 12) {
                    Text(String(number))
                        .font(TaborFont.mono(58, 700))
                        .em(0.01, size: 58)
                        .lineLimit(1)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model?.name ?? String(localized: "Unknown model"))
                            .font(TaborFont.grotesk(14, 600))
                            .lineLimit(1)
                        Mono(batch?.placeDisplay.nonEmpty ?? model?.operators.first?.uppercased() ?? "", size: 11, color: Palette.sub)
                            .lineLimit(1)
                        if let livery = model?.livery(of: number) {
                            HStack(spacing: 5) {
                                Image(systemName: "paintbrush.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Mono(livery.name, size: 10, weight: 700, spacing: 0.1, color: Palette.yellow)
                            }
                            .foregroundStyle(Palette.yellow)
                            .padding(.top, 5)
                            .accessibilityLabel(Text("Special livery: \(livery.name.lowercased())"))
                        }
                        if let coupled = coupledWith {
                            Button {
                                router.openVehicle(modelId: coupled.modelId, number: coupled.number)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "link")
                                        .font(.system(size: 9, weight: .bold))
                                    Mono("COUPLED WITH #\(String(coupled.number))", size: 10, weight: 700, spacing: 0.1, color: Palette.ink)
                                }
                                .foregroundStyle(Palette.ink)
                                .padding(.top, 5)
                                .contentShape(Rectangle())
                            }
                            // Plain, or a List row fires every button in it on any tap.
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                let photo = mine.photo(number: number, modelId: modelId)
                CatchPhoto(file: photo, maxPixel: 1200, placeholder: String(localized: "NO PHOTO YET"))
                    // The photo's own shape, so a tall shot isn't cut to a strip (#27). Up to
                    // about half the screen for an upright one; panoramas no thinner than 150 pt.
                    .aspectRatio(min(max(photo.flatMap(PhotoStore.aspect) ?? 2.4, 0.85), 2.4), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
                    .padding(.top, 16)
                    .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                    StatTile(label: String(localized: "VEHICLE AGE"), value: age(batch?.year), valueSize: 20,
                             caption: batch?.year.map { String(localized: "built \(String($0))") } ?? String(localized: "year unknown"))
                    StatTile(label: String(localized: "FIRST SEEN"), value: first.map { Self.dayMonth.string(from: $0.date).uppercased() } ?? "—",
                             valueSize: 20, caption: first.map(place) ?? String(localized: "not caught yet"))
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Mono("TIMES SEEN", size: 10, spacing: 0.12)
                        Text("\(mine.count)").font(TaborFont.mono(20, 700)).padding(.vertical, 3)
                    }
                    Spacer()
                    if let model {
                        let ownedOfModel = sightings.stats.ownedCount(modelId: model.id)
                        Text("\(ownedOfModel) of \(model.fleet) \(model.name)\nin your book")
                            .font(TaborFont.grotesk(11.5))
                            .foregroundStyle(Palette.sub)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(2)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
                .padding(.top, 9)
                .padding(.horizontal, 22)

                let lines = orderedLines(mine)
                if !lines.isEmpty {
                    SectionLabel(text: String(localized: "SEEN ON LINES"))
                        .padding(.top, 18)
                        .padding(.bottom, 9)
                        .padding(.horizontal, 22)
                    FlowRow(spacing: 7) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(TaborFont.mono(12, 600))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .foregroundStyle(i == 0 ? Color.white : Palette.routeInk)
                                .background(i == 0 ? Palette.red : Palette.track, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 22)
                }

                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: String(localized: "YOUR SIGHTINGS"))
                    Spacer()
                    if !mine.isEmpty { Mono("SWIPE TO EDIT", size: 9.5, color: Palette.faint) }
                }
                .padding(.top, 18)
                .padding(.bottom, 10)
                .padding(.horizontal, 22)
            }
            .plainRow()

            // With more than one picture to choose from, each row shows its own, and the one the
            // book uses is tagged; another can be picked by swiping right or holding the row.
            let pictured = mine.filter(\.hasPicture)
            let inBook = mine.cover(number: number, modelId: modelId) ?? pictured.first
            ForEach(Array(mine.enumerated()), id: \.element.id) { i, s in
                let choosable = pictured.count > 1 && s.hasPicture
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 3) {
                        Circle().fill(i == 0 ? Palette.yellow : Palette.dim).frame(width: 9, height: 9)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: choosable ? 40 : 26)
                    }
                    .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.stamp.string(from: s.date))
                            .font(TaborFont.grotesk(13.5, 600))
                        Mono(logLine(s, isFirst: i == mine.count - 1), size: 11, spacing: 0.05, color: Palette.sub)
                        if choosable, s.id == inBook?.id {
                            Mono("IN THE BOOK", size: 9.5, weight: 700, spacing: 0.1, color: Palette.yellow)
                                .padding(.top, 5)
                        }
                    }
                    .padding(.bottom, 10)
                    Spacer(minLength: 0)
                    if choosable {
                        SightingPicture(sighting: s)
                            .frame(width: 64, height: 44)
                            .opacity(s.id == inBook?.id ? 1 : 0.55)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 22)
                .contentShape(Rectangle())
                .plainRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { delete(s, wasLast: mine.count == 1) } label: { Label("Delete", systemImage: "trash") }
                    Button { editing = s } label: { Label("Edit", systemImage: "pencil") }
                        .tint(Palette.dim)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if choosable, s.id != inBook?.id {
                        Button { useInBook(s, of: mine) } label: { Label("Show in book", systemImage: "book") }
                            .tint(Palette.yellow)
                    }
                }
                .contextMenu {
                    if choosable, s.id != inBook?.id {
                        Button { useInBook(s, of: mine) } label: { Label("Show this picture in the book", systemImage: "book") }
                    }
                    Button { editing = s } label: { Label("Fix number, model or line", systemImage: "pencil") }
                    Button(role: .destructive) { delete(s, wasLast: mine.count == 1) } label: { Label("Delete sighting", systemImage: "trash") }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Circle().stroke(Color.white.opacity(0.25)).frame(width: 9, height: 9).padding(.top, 4)
                Mono(mine.isEmpty ? "NOT CAUGHT YET — GO FIND IT" : "NOTHING ELSE YET — GO FIND IT AGAIN",
                     size: 11.5, spacing: 0.05, color: Palette.faint)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
            .plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollIndicators(.hidden)
        .taborScreen()
        .sheet(item: $editing) { s in
            EditSightingSheet(sighting: s) { moved in
                // The sighting now belongs to another vehicle: follow it there.
                if moved { router.openVehicle(modelId: s.modelId, number: s.number) }
            }
        }
        // Render the share card up front so SHARE opens instantly, again whenever another picture
        // is picked: the card shows the picked catch, its day and place with its sticker.
        .task(id: [mine.first?.id, mine.cover(number: number, modelId: modelId)?.id]) {
            guard let shown = mine.cover(number: number, modelId: modelId) ?? mine.first else { return share = nil }
            // The second car added with it in the same catch, if any.
            let partner = shown.pairedWith ?? sightings.first {
                isSecondCar($0) && abs($0.date.timeIntervalSince(shown.date)) < 1
            }?.number
            share = CatchShare.make(number: number, model: model, sighting: shown,
                                    sticker: sightings.sticker(number: number, modelId: modelId),
                                    photo: sightings.photo(number: number, modelId: modelId),
                                    owned: sightings.stats.ownedCount(modelId: modelId), partner: partner)
        }
    }

    /// The car this one was last caught coupled to: the car it was added with, or the second
    /// car added with it. A trailer's motor car is another model's.
    private var coupledWith: (number: Int, modelId: String)? {
        let catalog = Fleet.catalog
        guard let model = catalog.model(id: modelId) else { return nil }
        return sightings.lazy.compactMap { s in
            if s.modelId == modelId, s.number == number, let p = s.pairedWith {
                return catalog.secondCarModel(p, of: number, model: model).map { (p, $0.id) }
            }
            return isSecondCar(s) ? (s.number, s.modelId) : nil
        }.first
    }

    /// A catch added as this vehicle's second car: paired with its number, in a model that pairs
    /// with it (so not a second car of a bus or tram that only shares the number).
    private func isSecondCar(_ s: Sighting) -> Bool {
        let catalog = Fleet.catalog
        guard s.pairedWith == number, let model = catalog.model(id: modelId) else { return false }
        return catalog.secondCarModel(s.number, of: number, model: model)?.id == s.modelId
    }

    /// The book, the widgets and the share card show this sighting's picture from now on.
    private func useInBook(_ s: Sighting, of mine: [Sighting]) {
        for other in mine { other.cover = other.id == s.id ? true : nil }
        try? context.save()
        Haptics.shared.tick()
    }

    /// No dialog: it goes at once, and the toast at the bottom can bring it back.
    private func delete(_ s: Sighting, wasLast: Bool) {
        withAnimation { undo.delete(s, in: context, closingPage: wasLast) }
        Haptics.shared.nope()
        // Its only sighting: the vehicle has left the book, so its page goes too.
        if wasLast { dismiss() }
    }

    private func age(_ year: Int?) -> String {
        guard let year else { return "—" }
        let y = Calendar.current.component(.year, from: .now) - year
        return y <= 0 ? String(localized: "NEW", comment: "Vehicle age: built this year") : String(localized: "\(y)y", comment: "Vehicle age in years, short")
    }

    private func place(_ s: Sighting) -> String {
        [s.street, s.line.map { String(localized: "line \($0)") }].compactMap { $0 }.joined(separator: ", ").nonEmpty
            ?? String(localized: "location off")
    }

    private func logLine(_ s: Sighting, isFirst: Bool) -> String {
        var parts = [String]()
        if let street = s.street { parts.append(street.uppercased()) }
        if let line = s.line { parts.append(String(localized: "LINE \(line)")) }
        parts.append(isFirst ? String(localized: "CAUGHT") : String(localized: "SEEN AGAIN"))
        return parts.joined(separator: " · ")
    }

    /// Most recent line first, no repeats.
    private func orderedLines(_ list: [Sighting]) -> [String] {
        var seen = Set<String>()
        return list.compactMap(\.line).filter { seen.insert($0).inserted }
    }

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("dMMMyyyyHHmm")
        return f
    }()
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// One sighting's own sticker, or its photo, small: for choosing which the book shows.
private struct SightingPicture: View {
    let sighting: Sighting

    var body: some View {
        if let sticker = sighting.stickerFile, let img = PhotoStore.thumbnail(sticker, maxPixel: 200) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CatchPhoto(file: sighting.photoFile, maxPixel: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private extension View {
    /// A List row that looks like plain stacked content: no insets, separators or fill.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Fix a saved sighting's number, model or line, reusing the catch correction sheet.
struct EditSightingSheet: View {
    let sighting: Sighting
    /// Called after saving; true when the sighting moved to another vehicle.
    let onSave: (Bool) -> Void
    @State private var draft: CatchDraft
    @Query private var manual: [ManualAssignment]
    @Query private var sightings: [Sighting]
    @Environment(\.modelContext) private var context

    init(sighting: Sighting, onSave: @escaping (Bool) -> Void) {
        self.sighting = sighting
        self.onSave = onSave
        _draft = State(initialValue: CatchDraft(photo: Data(), number: sighting.number, modelId: sighting.modelId,
                                                line: sighting.line, date: sighting.date, fromCamera: false))
    }

    var body: some View {
        // The sheet only writes the draft back when Done is tapped.
        CorrectionSheet(draft: $draft, title: String(localized: "Edit sighting"))
            .onDisappear(perform: apply)
    }

    private func apply() {
        guard let number = draft.number, let modelId = draft.modelId else { return }
        let line = draft.line?.trimmingCharacters(in: .whitespaces).nonEmpty
        let moved = number != sighting.number || modelId != sighting.modelId
        guard moved || line != sighting.line else { return }
        if moved { relink(to: number, modelId: modelId) }
        sighting.number = number
        sighting.modelId = modelId
        sighting.line = line
        if draft.modelPickedByHand { context.assign(number: number, to: modelId, existing: manual) }
        try? context.save()
        onSave(moved)
    }

    /// A coupled link only holds between cars that run together (coupled cars of one model, or
    /// a trailer and a car that pulls it): a second car added with this one follows its
    /// corrected number, and a link that no longer fits goes.
    private func relink(to number: Int, modelId: String) {
        let catalog = Fleet.catalog
        if let p = sighting.pairedWith, !catalog.match(number: p, kind: .tram).candidates.contains(where: {
            catalog.secondCarModel(number, of: p, model: $0)?.id == modelId
        }) {
            sighting.pairedWith = nil
        }
        let model = catalog.model(id: modelId)
        for second in sightings where second.pairedWith == sighting.number && second.id != sighting.id
            && abs(second.date.timeIntervalSince(sighting.date)) < 1 {
            let fits = model.flatMap { catalog.secondCarModel(second.number, of: number, model: $0) }?.id == second.modelId
            second.pairedWith = fits ? number : nil
        }
    }
}

/// Wrapping row of chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            let needed = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if needed > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur = (cur.items + [i], needed, max(cur.height, s.height))
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
