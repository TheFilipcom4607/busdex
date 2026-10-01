import SwiftUI

/// A coupled tram's other car: tap one of the likeliest numbers, or type it off the car.
struct PartnerSheet: View {
    let model: VehicleModel
    let number: Int
    let suggestions: [CoupledSet.Suggestion]
    /// This model's numbers already in the book, for NEW vs SEEN AGAIN.
    let owned: Set<Int>
    @Binding var partner: Int?
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let typed = Int(text)
        let problem = typed.flatMap(problem(with:))

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Older trams run as two cars, each with its own number. Add the other car to your book with this one.")
                        .font(TaborFont.grotesk(14))
                        .foregroundStyle(Palette.sub)
                        .lineSpacing(3)

                    if !suggestions.isEmpty {
                        SectionLabel(text: String(localized: "COUPLED TO \(String(number))?"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        VStack(spacing: 6) {
                            ForEach(suggestions, id: \.number) { s in
                                Button { pick(s.number) } label: { row(s) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }

                    SectionLabel(text: suggestions.isEmpty ? String(localized: "ITS FLEET NUMBER") : String(localized: "OR TYPE IT"))
                        .padding(.top, 22)
                    TextField("", text: $text, prompt: Text("0000").foregroundStyle(Palette.ghost))
                        .font(TaborFont.mono(44, 700))
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .padding(.vertical, 4)
                        .onChange(of: text) { old, new in
                            let digits = String(new.filter(\.isNumber).prefix(5))
                            if digits != new { text = digits; return }
                            if digits != old { Haptics.shared.detent() }
                        }
                    Rectangle().fill(focused ? Palette.yellow : Palette.track).frame(height: 2)
                        .animation(.easeInOut(duration: 0.2), value: focused)
                    if let typed {
                        Mono(problem ?? "+ \(typed) · \(tag(typed))", size: 10.5, color: problem == nil ? Palette.green : Palette.red)
                            .padding(.top, 8)
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.bg)
            .navigationTitle(String(localized: "Second car"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { typed.map(pick) }
                        .fontWeight(.bold)
                        .disabled(typed == nil || problem != nil)
                }
            }
        }
        .tint(Palette.yellow)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.bg)
        .onAppear {
            text = partner.map(String.init) ?? ""
            if suggestions.isEmpty { focused = true }
        }
    }

    private func row(_ s: CoupledSet.Suggestion) -> some View {
        let on = s.number == partner
        return HStack(spacing: 12) {
            Text(String(s.number))
                .font(TaborFont.mono(22, 700))
            VStack(alignment: .leading, spacing: 2) {
                Mono(tag(s.number), size: 10, weight: 700, color: owned.contains(s.number) ? Palette.sub : Palette.green)
                Mono(why(s.source), size: 9.5)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(on ? Palette.yellow : Palette.ghost)
        }
        .foregroundStyle(Palette.ink)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(on ? Palette.yellow.opacity(0.08) : Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Palette.yellow.opacity(0.5) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pick(_ n: Int) {
        Haptics.shared.detent()
        partner = n
        dismiss()
    }

    private func tag(_ n: Int) -> String {
        owned.contains(n) ? String(localized: "SEEN AGAIN") : String(localized: "NEW", comment: "Reveal tile: a model new to you")
    }

    private func why(_ source: CoupledSet.Suggestion.Source) -> String {
        switch source {
        case .fixed: String(localized: "ALWAYS RUNS WITH IT")
        case .photo: String(localized: "ALSO READ IN YOUR PHOTO")
        case .feed: String(localized: "RUNNING RIGHT HERE NOW")
        case .neighbour: String(localized: "ONE NUMBER AWAY")
        }
    }

    /// Why a typed number can't be the other car, or nil if it can.
    private func problem(with n: Int) -> String? {
        if n == number { return String(localized: "THAT'S THE CAR YOU SHOT") }
        if !model.has(n) { return String(localized: "NOT A \(model.name.uppercased()) NUMBER") }
        if !model.isCoupled(n) { return String(localized: "THAT CAR DOESN'T RUN COUPLED") }
        return nil
    }
}
