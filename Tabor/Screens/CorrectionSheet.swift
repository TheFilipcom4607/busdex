import SwiftData
import SwiftUI

/// Fix the number, pick the model (database matches first) and note the line.
struct CorrectionSheet: View {
    @Binding var draft: CatchDraft
    var title = String(localized: "Fix the catch")
    @Query private var manual: [ManualAssignment]
    @Environment(\.dismiss) private var dismiss

    @State private var numberText = ""
    @State private var line = ""
    @State private var modelId: String?
    @State private var pickedByHand = false
    @State private var search = ""
    @State private var kind: VehicleKind?
    @FocusState private var numberFocused: Bool

    private let catalog = Fleet.catalog

    var body: some View {
        let number = Int(numberText)
        let match = number.map { catalog.match(number: $0, kind: kind, manual: manual.map) } ?? .unknown
        let candidates = match.candidates
        let others = catalog.pickerOrder(candidates: candidates, kind: kind)
            .dropFirst(candidates.count)
            .filter { search.isEmpty || $0.name.localizedStandardContains(search) || ($0.code ?? "").localizedStandardContains(search) }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: String(localized: "FLEET NUMBER"))
                    TextField("", text: $numberText, prompt: Text("0000").foregroundStyle(Palette.ghost))
                        .font(TaborFont.mono(52, 700))
                        .keyboardType(.numberPad)
                        .focused($numberFocused)
                        .padding(.vertical, 6)
                        .onChange(of: numberText) { old, new in
                            let digits = String(new.filter(\.isNumber).prefix(5))
                            if digits != new { numberText = digits; return }
                            if digits != old { Haptics.shared.detent() }
                            autoPick()
                        }
                    Rectangle().fill(numberFocused ? Palette.yellow : Palette.track).frame(height: 2)
                        .animation(.easeInOut(duration: 0.2), value: numberFocused)

                    Mono(status(match, number: number), size: 10.5, color: statusColor(match, number: number))
                        .padding(.top, 8)

                    HStack(spacing: 7) {
                        kindChip(nil, String(localized: "ANY", comment: "Vehicle kind: bus or tram"))
                        kindChip(.bus, VehicleKind.bus.name)
                        kindChip(.tram, VehicleKind.tram.name)
                        Spacer()
                        HStack(spacing: 6) {
                            Mono("LINE", size: 10.5)
                            TextField("", text: $line, prompt: Text("—").foregroundStyle(Palette.ghost))
                                .font(TaborFont.mono(15, 700))
                                .keyboardType(.asciiCapable)
                                .textInputAutocapitalization(.characters)
                                .frame(width: 54)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Palette.card, in: Capsule())
                    }
                    .padding(.top, 18)

                    if !candidates.isEmpty {
                        SectionLabel(text: candidates.count > 1 ? String(localized: "THIS NUMBER EXISTS ON") : String(localized: "IN THE ZTM DATABASE"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        ForEach(candidates) { m in modelRow(m, number: number) }
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
            numberText = draft.number.map(String.init) ?? ""
            line = draft.line ?? ""
            modelId = draft.modelId
            pickedByHand = draft.modelPickedByHand
            if draft.number == nil { numberFocused = true }
        }
    }

    private func kindChip(_ k: VehicleKind?, _ label: String) -> some View {
        Button {
            Haptics.shared.tick()
            kind = k
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

    /// When the number maps to exactly one model, select it for the user.
    private func autoPick() {
        guard let n = Int(numberText) else { return }
        if case .certain(let m) = catalog.match(number: n, kind: kind, manual: manual.map) {
            if modelId != m.id { Haptics.shared.numberLocked(isNew: false) }
            modelId = m.id
            pickedByHand = false
        }
    }

    private func status(_ match: ModelMatch, number: Int?) -> String {
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
