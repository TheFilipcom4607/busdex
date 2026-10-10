import SwiftData
import SwiftUI

/// Fix the number, pick the model (database matches first) and note the line.
struct CorrectionSheet: View {
    @Binding var draft: CatchDraft
    var title = String(localized: "Fix the catch")
    @Query private var manual: [ManualAssignment]
    @Environment(\.dismiss) private var dismiss

    @State private var numberText = ""
    /// Typing a works car's code (S-9) instead of a number.
    @State private var codeMode = false
    @State private var line = ""
    @State private var modelId: String?
    @State private var pickedByHand = false
    @State private var search = ""
    @State private var kind: VehicleKind?
    /// The line a RUNNING NEARBY chip filled in, so another chip may replace it.
    @State private var lineFromChip: String?
    /// The kind the typed line set, so a different line may change it (a kind you tap stays).
    @State private var kindFromLine: VehicleKind?
    @FocusState private var numberFocused: Bool
    @FocusState private var lineFocused: Bool

    private let catalog = Fleet.catalog
    private let live = LiveFleetService.shared
    private let routes = RoutesUpdater.shared

    var body: some View {
        let number = typedNumber
        let match = number.map { catalog.match(number: $0, kind: kind, manual: manual.map) } ?? .unknown
        let candidates = match.candidates
        let onLine = self.onLine
        let searched = { (m: VehicleModel) in
            search.isEmpty || m.name.localizedStandardContains(search) || (m.code ?? "").localizedStandardContains(search)
        }
        let lineModels = onLine.models.filter { m in !candidates.contains { $0.id == m.id } && searched(m) }
        let lineIds = Set(lineModels.map(\.id))
        let others = catalog.pickerOrder(candidates: candidates, kind: kind)
            .dropFirst(candidates.count)
            .filter { !lineIds.contains($0.id) && searched($0) }
        // As the feed writes it ("L-8"), whatever case and dashes went into the field.
        let lineName = onLine.running.first?.vehicle.line ?? line.trimmingCharacters(in: .whitespaces).uppercased()

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: String(localized: "FLEET NUMBER"))
                    TextField("", text: $numberText, prompt: Text(verbatim: codeMode ? "S-9" : "0000").foregroundStyle(Palette.ghost))
                        .font(TaborFont.mono(52, 700))
                        .keyboardType(codeMode ? .asciiCapable : .numberPad)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($numberFocused)
                        // A focused field keeps its keyboard: a new field brings the other one.
                        .id(codeMode)
                        .padding(.vertical, 6)
                        .onChange(of: numberText) { old, new in
                            // Case is left as typed: rewriting it races fast typing, and codes match any case.
                            let kept = codeMode ? String(new.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(5))
                                : String(new.filter(\.isNumber).prefix(5))
                            if kept != new { numberText = kept; return }
                            if kept != old { Haptics.shared.detent() }
                            autoPick()
                        }
                    Rectangle().fill(numberFocused ? Palette.yellow : Palette.track).frame(height: 2)
                        .animation(.easeInOut(duration: 0.2), value: numberFocused)

                    HStack(alignment: .firstTextBaseline) {
                        Mono(status(match, number: number), size: 10.5, color: statusColor(match, number: number))
                        Spacer(minLength: 8)
                        // A few works cars have a code painted on instead of a number.
                        if !offersCode || codeMode {
                            Button(action: toggleCode) {
                                Mono(codeMode ? String(localized: "A NUMBER") : String(localized: "A CODE, LIKE S-9?"),
                                     size: 10.5, weight: 600, color: Palette.yellow)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)

                    if offersCode, !codeMode {
                        codeBanner.padding(.top, 16)
                    }

                    // Missed the number? What was running right there when you shot (#41).
                    let running = nearbyChoices
                    if !running.isEmpty {
                        SectionLabel(text: String(localized: "RUNNING NEARBY"))
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        ScrollView(.horizontal) {
                            HStack(spacing: 7) {
                                ForEach(running, id: \.self) { n in
                                    vehicleChip(n.vehicle, detail: "\(n.vehicle.line) · \(distanceText(n.distance))",
                                                on: n.vehicle.number == number)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }

                    // Polish chips are wider and used to squeeze LINE's label out, leaving a
                    // bare "—" circle nobody could place (#48); then it goes on a row of its own.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) {
                            kindChips
                            Spacer(minLength: 0)
                            lineField
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 7) { kindChips }
                            lineField
                        }
                    }
                    .padding(.top, 18)

                    // A typed line used to change nothing on screen (#50): now it lists what runs it.
                    if !onLine.running.isEmpty {
                        SectionLabel(text: String(localized: "ON LINE \(lineName) NOW"))
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        ScrollView(.horizontal) {
                            HStack(spacing: 7) {
                                ForEach(onLine.running.prefix(10), id: \.self) { r in
                                    vehicleChip(r.vehicle, detail: r.distance.map(distanceText) ?? "", on: r.vehicle.number == number)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    } else if !lineName.isEmpty {
                        Mono(lineFeedAsked ? String(localized: "LINE \(lineName) ISN'T RUNNING NOW · SAVED WITH THE CATCH")
                                           : String(localized: "THE LINE IS SAVED WITH THE CATCH"),
                             size: 10, color: Palette.dim)
                            .padding(.top, 10)
                    }

                    if !candidates.isEmpty {
                        SectionLabel(text: candidates.count > 1 ? String(localized: "THIS NUMBER EXISTS ON") : String(localized: "IN THE ZTM DATABASE"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        ForEach(candidates) { m in modelRow(m, number: number) }
                    }

                    if !lineModels.isEmpty {
                        SectionLabel(text: String(localized: "MODELS ON LINE \(lineName)"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        VStack(spacing: 6) {
                            ForEach(lineModels) { m in modelRow(m, number: number) }
                        }
                    }

                    SectionLabel(text: candidates.isEmpty ? String(localized: "PICK THE MODEL") : String(localized: "SOMETHING ELSE"))
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    TextField("", text: $search, prompt: Text("Search models").foregroundStyle(Palette.faint))
                        .font(TaborFont.grotesk(15))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 8)
                    LazyVStack(spacing: 6) {
                        ForEach(Array(others)) { m in modelRow(m, number: number) }
                    }
                }
                .padding(22)
                .fitScrollWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        draft.number = number
                        draft.modelId = modelId
                        draft.line = line.nonEmpty
                        // Decided here rather than when the row was tapped: the number may have
                        // changed since, leaving a model picked for another number that ZTM
                        // doesn't list under this one.
                        let listed = number.flatMap { n in modelId.flatMap(catalog.model(id:)).map { $0.numbers.contains(n) } }
                        draft.modelPickedByHand = pickedByHand || listed == false
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(number == nil || modelId == nil)
                }
            }
        }
        .tint(Palette.yellow)
        .presentationDetents([.large])
        .presentationBackground(Palette.bg)
        .onAppear {
            codeMode = draft.number.map(FleetNumber.isCoded) ?? false
            numberText = draft.number.map(FleetNumber.label) ?? ""
            line = draft.line ?? ""
            modelId = draft.modelId
            pickedByHand = draft.modelPickedByHand
            if draft.number == nil { numberFocused = true }
            routes.prepare()
        }
        .onChange(of: onLine.kind) { applyLineKind() }
    }

    /// The live vehicles around you at the shutter, nearest first: camera shots only.
    private var nearbyChoices: [NearbyVehicle] {
        var seen = Set<String>()
        return draft.nearby
            .filter { seen.insert("\($0.vehicle.kind.rawValue)#\($0.vehicle.number)").inserted }
            .prefix(6)
            .map { $0 }
    }

    /// The live feed is only asked about a photo from the last half hour: it says what's out now,
    /// not what was out when an older shot was taken.
    private var lineFeedAsked: Bool {
        Date().timeIntervalSince(draft.date) < 30 * 60 && live.fresh(maxAge: 120) != nil
    }

    private var onLine: LineLookup.Result {
        let here = LocationService.shared.recent(maxAge: 300).map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        return LineLookup.lookup(line, snapshot: lineFeedAsked ? live.fresh(maxAge: 120) : nil, routes: routes.book,
                                 near: here, catalog: catalog, manual: manual.map)
    }

    /// The line says bus or tram, unless you tapped a kind yourself.
    private func applyLineKind() {
        guard kind == nil || kind == kindFromLine, onLine.kind != kind else { return }
        kind = onLine.kind
        kindFromLine = kind
        // Never over a model you picked by hand.
        if !pickedByHand { autoPick() }
    }

    private func distanceText(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 10).rounded()) * 10) m"
            : "\((metres / 1000).formatted(.number.precision(.fractionLength(1)))) km"
    }

    private func vehicleChip(_ v: LiveVehicle, detail: String, on: Bool) -> some View {
        Button {
            Haptics.shared.tick()
            // Picked: the keyboard would only hide the model it just matched.
            lineFocused = false
            numberFocused = false
            numberText = String(v.number)
            kind = v.kind
            // The line comes along unless you typed one yourself.
            if line.isEmpty || line == draft.autoLine || line == lineFromChip {
                line = v.line
                lineFromChip = v.line
            }
            autoPick()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: v.kind == .bus ? "bus.fill" : "tram.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(v.number))
                    .font(TaborFont.mono(14, 700))
                if !detail.isEmpty {
                    Mono(detail, size: 10, color: on ? Palette.bg.opacity(0.7) : Palette.dim)
                }
            }
            .foregroundStyle(on ? Palette.bg : Palette.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(on ? Palette.yellow : Palette.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var kindChips: some View {
        kindChip(nil, String(localized: "ANY", comment: "Vehicle kind: bus or tram"))
        kindChip(.bus, VehicleKind.bus.name)
        kindChip(.tram, VehicleKind.tram.name)
    }

    private var lineField: some View {
        HStack(spacing: 6) {
            Mono("LINE", size: 10.5)
                .fixedSize()
            TextField("", text: $line, prompt: Text("—").foregroundStyle(Palette.ghost))
                .font(TaborFont.mono(15, 700))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .submitLabel(.done)
                .focused($lineFocused)
                .frame(width: 54)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Palette.card, in: Capsule())
        .fixedSize()
    }

    private func kindChip(_ k: VehicleKind?, _ label: String) -> some View {
        Button {
            Haptics.shared.tick()
            kind = k
            kindFromLine = nil
            autoPick()
        } label: {
            Mono(label, size: 11, weight: 600, color: kind == k ? Palette.bg : Palette.sub)
                .padding(.vertical, 7)
                .padding(.horizontal, 11)
                .background(kind == k ? Palette.ink : Palette.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ m: VehicleModel, number: Int?) -> some View {
        let on = m.id == modelId
        let inDatabase = number.map { m.numbers.contains($0) } ?? false
        return Button {
            Haptics.shared.detent()
            modelId = m.id
            // Only remember it as a manual override when it disagrees with ZTM.
            pickedByHand = !inDatabase
        } label: {
            HStack(spacing: 10) {
                KindTag(kind: m.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(TaborFont.grotesk(15, 600)).lineLimit(1)
                    Mono([m.operators.first?.uppercased(), m.yearsDisplay, String(localized: "\(m.fleet) EXIST")]
                        .compactMap { $0 }.joined(separator: " · "), size: 9.5)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Palette.yellow : Palette.ghost)
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(on ? Palette.yellow.opacity(0.08) : Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Palette.yellow.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// Nothing was read, which is all the camera gets off a works car with a code painted on
    /// instead of a number (S-9, P1): say so up front. They're all trams, so not in BUS mode.
    private var offersCode: Bool { draft.number == nil && draft.mode != .bus }

    private var codeBanner: some View {
        let tint = Tier.works.color
        return VStack(alignment: .leading, spacing: 8) {
            Mono(String(localized: "A WORKS TRAM?"), size: 11, weight: 600, spacing: 0.14, color: tint)
            Text("A few of them carry a code like S-9 instead of a number.")
                .font(TaborFont.grotesk(13))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: toggleCode) {
                Mono(String(localized: "TYPE THE CODE"), size: 11, weight: 700, spacing: 0.1, color: Palette.bg)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(tint, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.28)))
    }

    private func toggleCode() {
        Haptics.shared.tick()
        codeMode.toggle()
        numberText = ""
        Task { numberFocused = true }
    }

    /// The number typed, or the one a typed works car's code is kept under.
    private var typedNumber: Int? {
        codeMode ? catalog.vehicle(code: numberText)?.number : Int(numberText)
    }

    /// When the number maps to exactly one model, select it for the user.
    private func autoPick() {
        guard let n = typedNumber else { return }
        if case .certain(let m) = catalog.match(number: n, kind: kind, manual: manual.map) {
            if modelId != m.id { Haptics.shared.numberLocked(isNew: false) }
            modelId = m.id
            pickedByHand = false
        }
    }

    private func status(_ match: ModelMatch, number: Int?) -> String {
        if codeMode, number == nil {
            return numberText.isEmpty ? String(localized: "THE CODE ON THE CAR") : String(localized: "NO WORKS CAR HAS THIS CODE")
        }
        guard number != nil else { return String(localized: "READ IT OFF THE FRONT, SIDE OR BACK") }
        switch match {
        case .certain(let m): return String(localized: "MATCH · \(m.name.uppercased())")
        case .ambiguous(let ms): return String(localized: "\(ms.count) VEHICLES HAVE THIS NUMBER — PICK ONE")
        case .unknown: return String(localized: "NOT IN THE ZTM DATABASE — PICK THE MODEL YOURSELF")
        }
    }

    private func statusColor(_ match: ModelMatch, number: Int?) -> Color {
        guard number != nil else { return Palette.dim }
        switch match {
        case .certain: return Palette.green
        case .ambiguous: return Palette.yellow
        case .unknown: return Palette.dim
        }
    }
}
