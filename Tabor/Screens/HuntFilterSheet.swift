import SwiftUI

/// Pick what HUNT shows: buses or trams only, and whole rarities or particular models, any
/// of which counts (a wanted list). Changes apply as you tap, so the map behind the
/// half-height sheet follows.
struct HuntFilterSheet: View {
    @Binding var targets: HuntTargets
    /// Every uncaught vehicle running right now, anywhere.
    let running: [WantedPin]
    /// Whether distances in `running` are from you; without a fix they're from the map's
    /// centre, which says nothing about how far you'd have to go, so they aren't shown.
    let hasFix: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// Fixed when the sheet opens, so rows don't jump about as the feed refreshes or as you tick them.
    @State private var order: [String]
    private let catalog = Fleet.catalog

    init(targets: Binding<HuntTargets>, running: [WantedPin], hasFix: Bool) {
        _targets = targets
        self.running = running
        self.hasFix = hasFix
        _order = State(initialValue: Self.initialOrder(Fleet.catalog.models, running: running, picked: targets.wrappedValue.models))
    }

    var body: some View {
        // Read once: the binding decodes the stored filter on every read.
        let picked = targets
        let byKind = Dictionary(grouping: running, by: \.model.kind)
        // Rarity counts follow the type picked, so they say what you'd actually get.
        let ofKind = picked.kind.map { byKind[$0] ?? [] } ?? running
        let byModel = Dictionary(grouping: running, by: \.model.id)
        let byTier = Dictionary(grouping: ofKind, by: \.model.tier)
        let models = shownModels(kind: picked.kind)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: String(localized: "TYPE"))
                        Spacer()
                        Mono("UNCAUGHT, OUT NOW", size: 9.5, color: Palette.faint)
                    }
                    .padding(.bottom, 9)
                    HStack(spacing: 7) {
                        ForEach(VehicleKind.allCases, id: \.self) { k in
                            kindChip(k, count: byKind[k]?.count ?? 0, on: picked.kind == k)
                        }
                    }

                    SectionLabel(text: String(localized: "RARITY"))
                        .padding(.top, 24)
                        .padding(.bottom, 9)
                    FlowRow(spacing: 7) {
                        ForEach(Tier.allCases, id: \.self) { t in
                            tierChip(t, count: byTier[t]?.count ?? 0, on: picked.tiers.contains(t))
                        }
                    }

                    SectionLabel(text: String(localized: "MODELS"))
                        .padding(.top, 24)
                        .padding(.bottom, 9)
                    TextField("", text: $search, prompt: Text("Search models").foregroundStyle(Palette.faint))
                        .font(TaborFont.grotesk(15))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 8)
                    LazyVStack(spacing: 6) {
                        ForEach(models) { m in modelRow(m, out: byModel[m.id] ?? [], on: picked.models.contains(m.id)) }
                    }
                    if models.isEmpty {
                        Mono("NO MODEL MATCHES “\(search.uppercased())”", size: 10.5, color: Palette.faint)
                            .padding(.top, 10)
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.bg)
            .navigationTitle("Filter the hunt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        Haptics.shared.tick()
                        withAnimation(.snappy) { targets = HuntTargets() }
                    }
                    .disabled(picked.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .tint(Palette.radar)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.bg)
    }

    // MARK: - Pieces

    /// One of BUS / TRAM, or neither: tapping the lit one goes back to both.
    private func kindChip(_ k: VehicleKind, count: Int, on: Bool) -> some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) {
                targets.kind = on ? nil : k
                // A model of the other kind could never match any more: drop it.
                if !on { targets.models = targets.models.filter { catalog.model(id: $0)?.kind == k } }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: k == .bus ? "bus.fill" : "tram.fill")
                    .font(.system(size: 11, weight: .bold))
                Mono(k == .bus ? "BUSES" : "TRAMS", size: 11, weight: 700, spacing: 0.1,
                     color: on ? Palette.bg : Palette.ink)
                Mono("\(count)", size: 11, weight: 500, spacing: 0, color: on ? Palette.bg.opacity(0.65) : Palette.faint)
            }
            .foregroundStyle(on ? Palette.bg : Palette.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(on ? Palette.ink : Palette.chip, in: Capsule())
            .overlay(Capsule().stroke(Palette.ink.opacity(on ? 0 : 0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k == .bus ? "Buses only, \(count) out now" : "Trams only, \(count) out now")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tierChip(_ t: Tier, count: Int, on: Bool) -> some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { targets.tiers.formSymmetricDifference([t]) }
        } label: {
            HStack(spacing: 6) {
                Mono(t.name, size: 11, weight: 700, spacing: 0.1, color: on ? t.onMapColor : t.mapColor)
                Mono("\(count)", size: 11, weight: 500, spacing: 0, color: on ? t.onMapColor.opacity(0.65) : Palette.faint)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(on ? t.mapColor : Palette.chip, in: Capsule())
            .overlay(Capsule().stroke(t.mapColor.opacity(on ? 0 : 0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.name.capitalized), \(count) out now")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func modelRow(_ m: VehicleModel, out: [WantedPin], on: Bool) -> some View {
        let nearest = hasFix ? out.map(\.distance).min() : nil
        return Button {
            Haptics.shared.detent()
            withAnimation(.snappy) { targets.models.formSymmetricDifference([m.id]) }
        } label: {
            HStack(spacing: 10) {
                KindTag(kind: m.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.name)
                        .font(TaborFont.grotesk(15, 600))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    HStack(spacing: 7) {
                        Mono(m.tier.name, size: 9.5, weight: 700, spacing: 0.1, color: m.tier.mapColor)
                        Mono(Self.outText(out.count, nearest: nearest), size: 9.5,
                             color: out.isEmpty ? Palette.faint : Palette.sub)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Palette.radar : Palette.ghost)
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(on ? Palette.radar.opacity(0.08) : Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Palette.radar.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Data

    /// Search matches every word anywhere in the name or ZTM code, ignoring case and accents
    /// ("guleryuz cobra" finds the Güleryüz Cobra GD272). Only the type picked, if one is.
    private func shownModels(kind: VehicleKind?) -> [VehicleModel] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return order.compactMap(catalog.model(id:)).filter { m in
            (kind == nil || m.kind == kind) && words.allSatisfy { w in m.name.localizedStandardContains(w) || (m.code ?? "").localizedStandardContains(w) }
        }
    }

    /// "2 OUT · NEAREST 1.2 KM", or "NONE OUT NOW".
    private static func outText(_ count: Int, nearest: Double?) -> String {
        guard count > 0 else { return String(localized: "NONE OUT NOW") }
        guard let nearest else { return String(localized: "\(count) OUT") }
        return String(localized: "\(count) OUT · NEAREST \(HuntDistance.text(nearest))")
    }

    /// What you'd picked before first; then models out on the road now, rarest first and
    /// nearest within a rarity; then the rest, regular stock before vintage and test, by name.
    private static func initialOrder(_ models: [VehicleModel], running: [WantedPin], picked: Set<String>) -> [String] {
        let nearest = Dictionary(running.map { ($0.model.id, $0.distance) }, uniquingKeysWith: min)
        return models.sorted { a, b in
            let pa = picked.contains(a.id), pb = picked.contains(b.id)
            if pa != pb { return pa }
            let na = nearest[a.id], nb = nearest[b.id]
            if (na != nil) != (nb != nil) { return na != nil }
            if let na, let nb {
                let ra = Wanted.huntRank(a.tier), rb = Wanted.huntRank(b.tier)
                if ra != rb { return ra < rb }
                if na != nb { return na < nb }
            } else if a.regular != b.regular {
                return a.regular
            }
            return a.name < b.name
        }.map(\.id)
    }
}
