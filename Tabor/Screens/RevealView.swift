import SwiftData
import SwiftUI

/// The reveal: your photo "develops", the vehicle gets cut out of it, and the die-cut
/// sticker slams down in sync with a haptic build-up that scales with rarity.
struct RevealView: View {
    @State var draft: CatchDraft
    @Query private var sightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @AppStorage("saveToGallery") private var saveToGallery = true
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router

    /// Photo shown, waiting for the cut-out / build-up.
    @State private var developing = true
    /// The sticker has landed.
    @State private var landed = false
    @State private var charge = 0.0
    @State private var sparkle = false
    @State private var stickerImage: UIImage?
    @State private var stickerPNG: Data?
    /// The sticker's cut, kept so WRONG CUTOUT? can try the next object in the photo.
    @State private var cut: StickerCut?
    @State private var recutting = false
    @State private var recuts = 0
    @State private var editing = false
    @State private var holdProgress = 0.0
    @State private var holding = false
    @State private var sticking = false
    @State private var tilt: CGSize = .zero
    @State private var nudge = false
    @State private var revealRun = 0
    @State private var pickingPartner = false
    /// Every number read in the photo, once the read is done; feeds the partner suggestions.
    @State private var photoNumbers: [Int] = []
    /// The whole read, for other vehicles in the photo.
    @State private var photoReport: TextReader.Report?
    /// Other vehicles' stickers, cut as soon as they're offered, by number. A number that
    /// turns out to be painted on the caught vehicle is in `misreads` instead.
    @State private var alsoStickers: [Int: Data] = [:]
    @State private var misreads: Set<Int> = []
    @State private var missingInsets = EdgeInsets()

    private let catalog = Fleet.catalog
    private let holdDuration = 0.55

    private static let shotDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let shotYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    private var model: VehicleModel? { draft.modelId.flatMap(catalog.model(id:)) }

    var body: some View {
        let stats = sightings.stats
        let model = model
        let number = draft.number
        let existing = (model != nil && number != nil) ? stats.vehicle(number: number!, modelId: model!.id) : nil
        let isNewVehicle = existing == nil
        let modelOwned = model.map { stats.ownedCount(modelId: $0.id) } ?? 0
        // A coupled tram's other car goes in the book too, so the counts include it.
        let partner = secondCar(model: model, number: number)
        let partnerIsNew = partner.map { stats.vehicle(number: $0.number, modelId: $0.model.id) == nil } ?? false
        // A trailer and its motor car are different models: only a same-model car adds to this one's count.
        let added = (isNewVehicle ? 1 : 0) + (partnerIsNew && partner?.model.id == model?.id ? 1 : 0)
        let isNewModel = modelOwned == 0
        let tier = model?.tier ?? .common
        let ready = model != nil && number != nil
        let accent = tier == .common ? Palette.yellow : tier.color

        ZStack {
            Palette.bg.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.08 + 0.34 * charge), .clear],
                           center: .init(x: 0.5, y: 0.34), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // Just the way out: a CONFIRM title here was taken for a button that did nothing.
                HStack {
                    Spacer()
                    Button {
                        draft.geotag?.cancel()
                        draft.debug?.log("retake", number: draft.number, modelId: draft.modelId)
                        dismiss()
                    } label: {
                        Mono(draft.fromCamera ? "RETAKE" : "CANCEL", size: 12)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // The bigger target overlaps the space around the row, not the layout.
                .padding(.top, -2)
                .padding(.bottom, -12)

                VStack(alignment: .leading, spacing: 7) {
                    Mono(kicker(isNewVehicle: isNewVehicle, isNewModel: isNewModel, modelOwned: modelOwned, added: added, existing: existing),
                         size: 12, spacing: 0.16, color: accent)
                    Text(model?.name ?? (number == nil ? String(localized: "What did you catch?") : String(localized: "Which model is it?")))
                        .font(TaborFont.grotesk(30, 700))
                        .em(-0.03, size: 30)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let line = draft.line?.nonEmpty {
                        Mono("LINE \(line.uppercased())", size: 11, weight: 600, spacing: 0.12, color: Palette.sub)
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, 26)

                stage(number: number, model: model, tier: tier, isNew: isNewVehicle && ready)
                    .frame(maxWidth: .infinity)
                    .frame(height: 250)
                    .padding(.top, 12)

                if ready, let model, let number {
                    HStack(spacing: 10) {
                        let seen = (existing?.timesSeen ?? 0) + 1
                        StatTile(label: String(localized: "YOUR", comment: "Reveal tile: your Nth of this model"),
                                 value: isNewVehicle ? Ordinal.string(modelOwned + added) : "×\(seen)",
                                 valueColor: Palette.yellow,
                                 caption: isNewVehicle ? String(localized: "of \(model.fleet)") : PluralCaption.sightings(seen))
                        StatTile(label: String(localized: "MODEL"), value: isNewModel ? String(localized: "NEW", comment: "Reveal tile: a model new to you") : "\(modelOwned + added)",
                                 valueColor: isNewModel ? Palette.green : Palette.ink,
                                 caption: isNewModel ? String(localized: "species") : String(localized: "of \(model.fleet)"))
                        if Calendar.current.isDateInToday(draft.date) {
                            let streak = Streak.days(sightings.map(\.date) + [draft.date])
                            StatTile(label: String(localized: "STREAK"), value: "\(streak)",
                                     caption: PluralCaption.days(streak))
                        } else {
                            // Imported shot from another day: it doesn't touch today's streak.
                            StatTile(label: String(localized: "SHOT", comment: "Reveal tile: the date an imported photo was taken"), value: Self.shotDate.string(from: draft.date).uppercased(),
                                     valueSize: 18, caption: Self.shotYear.string(from: draft.date))
                        }
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 26)
                    .opacity(landed ? 1 : 0)
                    .offset(y: landed ? 0 : 14)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: landed)

                    let also = draft.alsoInShot.filter { !misreads.contains($0.number) }
                    if model.takesSecondCar(number) || !also.isEmpty {
                        let chips = HStack(spacing: 8) {
                            if model.takesSecondCar(number) { partnerChip(partner: partner?.number, isNew: partnerIsNew) }
                            ForEach(also) { v in
                                alsoChip(v, isNew: stats.vehicle(number: v.number, modelId: v.model.id) == nil)
                            }
                        }
                        .padding(.horizontal, 26)
                        // Two other vehicles and a second car don't fit across: then they scroll.
                        ViewThatFits(in: .horizontal) {
                            chips.frame(maxWidth: .infinity, alignment: .leading)
                            ScrollView(.horizontal, showsIndicators: false) { chips }
                        }
                        // A scroll view takes any height it's offered; just the chips'.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .opacity(landed ? 1 : 0)
                        .offset(y: landed ? 0 : 16)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.14), value: landed)
                    }

                    // A trailer is another model's: it doesn't count toward this one.
                    let sameModel = partner.flatMap { $0.model.id == model.id ? [$0.number] : nil } ?? []
                    let owned = Set(stats.owned(modelId: model.id).map(\.number)).union([number] + sameModel)
                    Text(RevealHint.text(model: model, number: number, owned: owned,
                                         isNewVehicle: isNewVehicle, timesSeen: (existing?.timesSeen ?? 0) + 1))
                        .font(TaborFont.grotesk(13))
                        .foregroundStyle(Palette.greenInk)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 15)
                        .background(Palette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.green.opacity(0.28)))
                        .padding(.top, 14)
                        .padding(.horizontal, 26)
                        .opacity(landed ? 1 : 0)
                        .offset(y: landed ? 0 : 18)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.18), value: landed)
                }

                Spacer(minLength: 16)

                VStack(spacing: 10) {
                    if ready {
                        holdButton
                    } else {
                        Button {
                            editing = true
                        } label: {
                            Text(number == nil ? "Type the number" : "Pick the model")
                                .font(TaborFont.grotesk(16, 700))
                                .frame(maxWidth: .infinity)
                                .padding(17)
                                .foregroundStyle(Palette.bg)
                                .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(StickerPressStyle())
                    }
                    HStack(spacing: 10) {
                        Button {
                            editing = true
                        } label: {
                            secondaryLabel(ready ? String(localized: "WRONG NUMBER?") : String(localized: "EDIT DETAILS"))
                        }
                        .buttonStyle(.plain)
                        // Only when the photo had something else worth cutting.
                        if ready, landed, stickerImage != nil, cut?.canRecut == true {
                            Button(action: recut) {
                                secondaryLabel(String(localized: "WRONG CUTOUT?"))
                                    .opacity(recutting ? 0.5 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(recutting)
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 20)
                .opacity(sticking ? 0 : 1)
            }
            .foregroundStyle(Palette.ink)
            .padding(.top, missingInsets.top)
            .padding(.bottom, missingInsets.bottom)
        }
        // Belt and braces for imports: a reveal that came up while the photo picker was still
        // leaving was laid out with no safe area (CANCEL under the status bar). Whatever the
        // presentation reports, keep clear of what the window itself keeps clear of.
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.safeAreaInsets, initial: true) { _, insets in
                    let window = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }
                        .compactMap(\.keyWindow).first?.safeAreaInsets ?? .zero
                    missingInsets = EdgeInsets(top: max(0, window.top - insets.top), leading: 0,
                                               bottom: max(0, window.bottom - insets.bottom), trailing: 0)
                }
            }
        }
        .sheet(isPresented: $editing) {
            CorrectionSheet(draft: $draft)
        }
        .sheet(isPresented: $pickingPartner) {
            if let model, let number {
                PartnerSheet(model: model, number: number, suggestions: draft.partnerSuggestions,
                             owned: Set(catalog.secondCarModels(of: number, model: model)
                                .flatMap { stats.owned(modelId: $0.id).map(\.number) }),
                             partner: $draft.partner)
            }
        }
        // One key, so fixing number and model together replays the reveal once.
        .onChange(of: "\(draft.number ?? -1)|\(draft.modelId ?? "")") { _, _ in edited() }
        .onChange(of: draft.partner) { _, _ in refreshAlso() }
        .task {
            Haptics.shared.warmUp()
            await playReveal(run: 0)
            // A live lock's still read may still be going: its numbers sharpen the suggestions.
            if let read = draft.photoNumbers {
                photoNumbers = await read.value
                refreshPartner()
            }
            if let read = draft.photoRead {
                photoReport = await read.value
                refreshAlso()
            }
        }
    }

    /// The other car and the model it goes under (a trailer's motor car is another model's),
    /// while it still fits the number and model on screen.
    private func secondCar(model: VehicleModel?, number: Int?) -> (number: Int, model: VehicleModel)? {
        guard let p = draft.partner, let model, let number,
              let other = catalog.secondCarModel(p, of: number, model: model)
        else { return nil }
        return (p, other)
    }

    /// "+ SECOND CAR", or the car you added, with a way to take it off again.
    private func partnerChip(partner: Int?, isNew: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                Haptics.shared.tick()
                pickingPartner = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tram.fill").font(.system(size: 11, weight: .bold))
                    if let partner {
                        let tag = isNew ? String(localized: "NEW", comment: "Reveal tile: a model new to you") : String(localized: "SEEN AGAIN")
                        Mono("+ \(String(partner)) · \(tag)" as String, size: 12, weight: 700, spacing: 0.1,
                             color: isNew ? Palette.green : Palette.ink)
                    } else {
                        Mono("+ SECOND CAR", size: 12, weight: 700, spacing: 0.12, color: Palette.yellow)
                    }
                }
                .foregroundStyle(partner == nil ? Palette.yellow : isNew ? Palette.green : Palette.ink)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .padding(.trailing, partner == nil ? 14 : 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(partner.map { Text("Second car \(String($0)). Change it") } ?? Text("Add the second car"))
            if partner != nil {
                Button {
                    Haptics.shared.tick()
                    draft.partner = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.sub)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove the second car")
            }
        }
        .overlay(Capsule().strokeBorder(partner == nil ? Palette.yellow.opacity(0.6) : Color.white.opacity(0.14),
                                        style: StrokeStyle(lineWidth: 1, dash: partner == nil ? [4, 3] : [])))
        .animation(.snappy, value: partner)
    }

    /// Suggestions follow the number and model; a partner that no longer fits them goes.
    private func refreshPartner() {
        guard let model, let number = draft.number else {
            draft.partnerSuggestions = []
            draft.partner = nil
            return
        }
        draft.partnerSuggestions = CoupledSet.suggestions(for: number, model: model, photoNumbers: photoNumbers,
                                                          nearby: draft.nearby, catalog: catalog)
        draft.partner = secondCar(model: model, number: number)?.number
    }

    /// "+ 5897 · ALSO IN SHOT" for another vehicle read in the photo; tap to add it as a catch
    /// of its own, tap again to leave it out.
    private func alsoChip(_ v: AlsoInShot.Vehicle, isNew: Bool) -> some View {
        let added = draft.alsoAdded.contains(v.number)
        let tint = !added ? Palette.yellow : isNew ? Palette.green : Palette.ink
        return Button {
            Haptics.shared.tick()
            withAnimation(.snappy) {
                if added { draft.alsoAdded.removeAll { $0 == v.number } } else { draft.alsoAdded.append(v.number) }
            }
        } label: {
            HStack(spacing: 7) {
                // Its sticker says which vehicle in the photo this is.
                if let png = alsoStickers[v.number], let img = UIImage(data: png) {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 30, height: 20)
                } else {
                    Image(systemName: v.model.kind == .tram ? "tram.fill" : "bus.fill").font(.system(size: 11, weight: .bold))
                }
                if added {
                    let tag = isNew ? String(localized: "NEW", comment: "Reveal tile: a model new to you") : String(localized: "SEEN AGAIN")
                    Mono("+ \(String(v.number)) · \(tag)" as String, size: 12, weight: 700, spacing: 0.1, color: tint)
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.sub)
                } else {
                    Mono("+ \(String(v.number)) · \(String(localized: "ALSO IN SHOT"))" as String, size: 12, weight: 700,
                         spacing: 0.1, color: tint)
                }
            }
            .foregroundStyle(tint)
            .padding(.vertical, alsoStickers[v.number] == nil ? 10 : 6)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Capsule().strokeBorder(added ? Color.white.opacity(0.14) : Palette.yellow.opacity(0.6),
                                        style: StrokeStyle(lineWidth: 1, dash: added ? [] : [4, 3])))
        .accessibilityLabel(added ? Text("\(String(v.number)), \(v.model.name), added. Leave it out")
                                  : Text("Also in the photo: \(String(v.number)), \(v.model.name). Add it"))
    }

    /// Other vehicles follow the number, model and second car; one you added that's no longer
    /// offered goes. Each gets its sticker cut straight away: a number one digit off the caught
    /// one that's painted on the caught vehicle is a misreading, and drops out.
    private func refreshAlso() {
        guard let report = photoReport, let model, let number = draft.number else {
            draft.alsoInShot = []
            draft.alsoAdded = []
            return
        }
        draft.alsoInShot = AlsoInShot.vehicles(in: report.reads, caught: number, model: model, partner: draft.partner,
                                               catalog: catalog, nearby: draft.nearby, manual: manual.map)
        let offered = Set(draft.alsoInShot.map(\.number))
        draft.alsoAdded.removeAll { !offered.contains($0) }
        let caught = number
        for v in draft.alsoInShot where alsoStickers[v.number] == nil && !misreads.contains(v.number) {
            guard let task = draft.sticker else { continue }
            let avoid = cut?.label, box = v.box, n = v.number
            Task {
                let other = await Task.detached(priority: .userInitiated) { () -> StickerCut.Other in
                    guard let main = await task.value else { return .none }
                    return StickerCut.other(main.lift, numberBox: box, avoiding: avoid ?? main.label)
                }.value
                // The number was fixed meanwhile: this was judged against the old one.
                guard draft.number == caught else { return }
                switch other {
                case .sticker(let png):
                    withAnimation(.snappy) { alsoStickers[n] = png }
                case .sameObject where AlsoInShot.couldBeMisread(n, of: caught):
                    withAnimation(.snappy) {
                        misreads.insert(n)
                        draft.alsoAdded.removeAll { $0 == n }
                    }
                default:
                    break
                }
                draft.debug?.log("also-in-shot", number: n, modelId: draft.alsoInShot.first { $0.number == n }?.model.id,
                                 note: "\(other)")
            }
        }
    }

    private func secondaryLabel(_ text: String) -> some View {
        Mono(text, size: 12.5, color: Palette.sub)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14)))
            // A plain button only takes taps on what's drawn: make the whole box count.
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The lifter found more than one object and kept the wrong one: cut the next instead.
    private func recut() {
        guard let current = cut, !recutting else { return }
        recutting = true
        Haptics.shared.tick()
        Task {
            let next = await Task.detached(priority: .userInitiated) { current.next() }.value
            recutting = false
            guard let next else { return Haptics.shared.nope() }
            recuts += 1
            let n = recuts
            draft.debug?.update { $0.sticker?.recuts = n }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                cut = next
                stickerPNG = next.png
                stickerImage = UIImage(data: next.png)
            }
        }
    }

    // MARK: - Stage

    /// Photo while developing, die-cut sticker once landed.
    @ViewBuilder
    private func stage(number: Int?, model: VehicleModel?, tier: Tier, isNew: Bool) -> some View {
        let batch = number.flatMap { model?.batch(containing: $0) }
        ZStack {
            // 1. The raw photo, washed out and pulsing while the cut-out is made.
            //    If no subject could be lifted, the photo card itself becomes the sticker.
            if !landed || stickerImage == nil {
                VStack(spacing: 10) {
                    photoCard
                    if landed { stickerCaption(number: number, model: model, tier: tier, batch: batch) }
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            // 2. The sticker.
            if landed, let img = stickerImage {
                VStack(spacing: 10) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 330, maxHeight: 170)
                        // Shadow before the sheen: under it, the blur was redrawn every frame.
                        .shadow(color: .black.opacity(0.6), radius: 14, y: 16)
                        .overlay {
                            GlossSweep()
                                .mask(Image(uiImage: img).resizable().scaledToFit())
                        }
                        .overlay(alignment: .topTrailing) {
                            if isNew { newBadge }
                        }
                    stickerCaption(number: number, model: model, tier: tier, batch: batch)
                }
                // A re-cut slaps down like the first one did.
                .id(cut?.index ?? 0)
                .transition(.asymmetric(insertion: .scale(scale: 1.35).combined(with: .opacity), removal: .opacity))
            }
        }
        .overlay { if sparkle { SparkleBurst(color: tier == .common ? Palette.yellow : tier.color) } }
        .rotation3DEffect(.degrees(Double(tilt.width) / 8), axis: (x: 0, y: 1, z: 0))
        .rotation3DEffect(.degrees(Double(-tilt.height) / 8), axis: (x: 1, y: 0, z: 0))
        .rotationEffect(.degrees(sticking ? 0 : -2.2 + (nudge ? 3 : 0)))
        .scaleEffect(sticking ? 0.18 : (holding ? 1 - 0.06 * holdProgress : 1))
        .offset(y: sticking ? 520 : 0)
        .opacity(sticking ? 0 : 1)
        .gesture(
            DragGesture()
                .onChanged { v in tilt = CGSize(width: max(-90, min(90, v.translation.width)),
                                                height: max(-90, min(90, v.translation.height))) }
                .onEnded { _ in withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { tilt = .zero } }
        )
    }

    private var photoCard: some View {
        Group {
            if let img = draft.preview {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Palette.photoWell
            }
        }
        .frame(width: 286, height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // A tall imported photo would otherwise take taps outside the card.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(developing ? 0.45 * (1 - charge) + 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 14)
        .blur(radius: developing ? 3 * (1 - charge) : 0)
        .phaseAnimator([1.0, 0.97]) { v, s in v.scaleEffect(developing ? s : 1) } animation: { _ in .easeInOut(duration: 0.7) }
    }

    private var newBadge: some View {
        Mono("NEW", size: 11, weight: 700, spacing: 0.14, color: .white)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(Palette.red, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.white, lineWidth: 2.5))
            .rotationEffect(.degrees(8))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
            .offset(x: 4, y: -6)
            .transition(.scale(scale: 0.2).combined(with: .opacity))
    }

    private func stickerCaption(number: Int?, model: VehicleModel?, tier: Tier, batch: Batch?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(number.map(String.init) ?? "????")
                .font(TaborFont.mono(30, 700))
                .em(0.02, size: 30)
                .foregroundStyle(Palette.stickerInk)
                .padding(.vertical, 2)
                .padding(.horizontal, 10)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(-2))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Mono([batch?.placeDisplay.nonEmpty, batch?.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                     .nonEmpty ?? (model?.kind.name ?? String(localized: "NUMBER NOT READ")), size: 10.5, spacing: 0.12, color: Palette.sub)
                    .lineLimit(1)
                if let model { TierPill(tier: tier, fleet: model.fleet, solid: false) }
            }
        }
    }

    // MARK: - Hold to stick

    private var holdButton: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.yellow)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.45))
                    .frame(width: geo.size.width * holdProgress)
            }
            Text(holding ? "Keep holding…" : "Hold to stick it in the book")
                .font(TaborFont.grotesk(16, 700))
                .em(-0.01, size: 16)
                .foregroundStyle(Palette.bg)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(holding ? 0.97 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: holding)
        .opacity(landed ? 1 : 0.4)
        .allowsHitTesting(landed)
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            Task { await stick() }
        } onPressingChanged: { down in
            if down { beginHold() } else if !sticking { cancelHold() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Stick it in the book")
        .accessibilityAction { Task { await stick() } }
    }

    private func beginHold() {
        holding = true
        Haptics.shared.beginHold()
        let start = Date()
        Task { @MainActor in
            while holding, !sticking {
                let p = min(Date().timeIntervalSince(start) / holdDuration, 1)
                holdProgress = p
                Haptics.shared.updateHold(progress: p)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func cancelHold() {
        holding = false
        Haptics.shared.endHold()
        // A quick tap: teach the gesture with a wobble instead of doing nothing.
        if holdProgress < 0.35 {
            Haptics.shared.nope()
            withAnimation(.spring(response: 0.2, dampingFraction: 0.3)) { nudge = true }
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) { nudge = false }
            }
        }
        withAnimation(.spring(response: 0.35)) { holdProgress = 0 }
    }

    // MARK: - Sequencing

    private static func buildTime(_ t: Tier) -> Double {
        switch t {
        case .common: 0.05
        case .rare: 0.35
        case .gold: 0.62
        case .legendary: 1.0
        case .vintage, .onTest: 0.62
        }
    }

    private func playReveal(run: Int) async {
        // Wait for the cut-out (usually ~0.2s on device), capped so a slow model never stalls.
        if stickerImage == nil, let task = draft.sticker {
            let made = await withTaskGroup(of: StickerCut??.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2.5)); return .some(nil) }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? nil
            }
            guard run == revealRun else { return }
            cut = made
            stickerPNG = made?.png
            stickerImage = made.flatMap { UIImage(data: $0.png) }
        }

        guard let model, draft.number != nil else {
            // Nothing to celebrate yet: show the sticker and ask.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { developing = false; charge = 1; landed = true }
            Haptics.shared.nope()
            try? await Task.sleep(for: .milliseconds(350))
            editing = true
            return
        }
        let isNewModel = sightings.stats.ownedCount(modelId: model.id) == 0
        let build = Self.buildTime(model.tier)
        Haptics.shared.reveal(tier: model.tier, isNewModel: isNewModel)
        withAnimation(.easeIn(duration: build)) { charge = 1 }
        try? await Task.sleep(for: .seconds(build))
        guard run == revealRun else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
            developing = false
            landed = true
        }
        sparkle = isNewModel || model.tier != .common
        try? await Task.sleep(for: .seconds(0.9))
        withAnimation(.easeOut(duration: 0.8)) { charge = 0.35 }
    }

    private func edited() {
        refreshPartner()
        // Misreads were judged against the old number, and a cut avoided the old vehicle.
        misreads = []
        alsoStickers = [:]
        refreshAlso()
        // A line the feed filled in follows a corrected number, unless you typed your own.
        if draft.fromCamera, (draft.line ?? "") == (draft.autoLine ?? ""),
           let number = draft.number, let model {
            draft.line = LiveHints.line(for: number, kind: model.kind, snapshot: LiveFleetService.shared.snapshot,
                                        at: draft.date, model: model, nearby: draft.nearby, catalog: catalog)
            draft.autoLine = draft.line
        }
        draft.debug?.log("edited", number: draft.number, modelId: draft.modelId, line: draft.line)
        replayReveal()
    }

    private func replayReveal() {
        revealRun += 1
        landed = false
        developing = true
        charge = 0
        sparkle = false
        let run = revealRun
        Task { await playReveal(run: run) }
    }

    private func stick() async {
        guard let model, let number = draft.number, !sticking else { return }
        holding = false
        Haptics.shared.endHold()
        Haptics.shared.stick()
        holdProgress = 1

        let ownedBefore = Set(sightings.stats.owned(modelId: model.id).map(\.number))
        let partner = secondCar(model: model, number: number)
        let cars = [number] + (partner.flatMap { $0.model.id == model.id ? [$0.number] : nil } ?? [])
        // Peel: lift and straighten.
        withAnimation(.easeOut(duration: 0.2)) { tilt = .zero }
        try? await Task.sleep(for: .milliseconds(240))
        // Slap: fly down into the book.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { sticking = true }
        save(model: model, number: number)

        let owned = ownedBefore.union(cars)
        let batchDone = cars.contains { model.batch(containing: $0)?.numbers.allSatisfy(owned.contains) ?? false }
        let firstTime = !ownedBefore.isSuperset(of: cars)
        try? await Task.sleep(for: .milliseconds(480))
        router.openModel(model.id, landing: number)
        dismiss()
        if firstTime, batchDone || model.numbers.allSatisfy(owned.contains) {
            try? await Task.sleep(for: .milliseconds(450))
            Haptics.shared.completed()
        }
    }

    private func save(model: VehicleModel, number: Int) {
        let line = draft.line?.trimmingCharacters(in: .whitespaces).nonEmpty
        let ext = PhotoStore.fileExtension(of: draft.photo)
        let s = Sighting(number: number, modelId: model.id, date: draft.date, line: line,
                         photoFile: PhotoStore.save(draft.photo, ext: ext),
                         stickerFile: stickerPNG.flatMap { PhotoStore.save($0, ext: "png") })
        context.insert(s)
        draft.debug?.log("stuck", number: number, modelId: model.id, line: s.line)
        // A coupled tram's other car: a catch of its own, with its own copies of the files so
        // deleting either car leaves the other whole. The model you shot, or for a trailer and
        // its motor car the tram model that pairs (never `catalog.match`: its number may be a
        // bus's too), and a millisecond earlier so lists keep the shot car on top.
        var cars = [s]
        if let (p, pModel) = secondCar(model: model, number: number) {
            let second = Sighting(number: p, modelId: pModel.id, date: draft.date.addingTimeInterval(-0.001), line: line,
                                  photoFile: PhotoStore.save(draft.photo, ext: ext),
                                  stickerFile: stickerPNG.flatMap { PhotoStore.save($0, ext: "png") })
            second.pairedWith = number
            context.insert(second)
            cars.append(second)
            let source = draft.partnerSuggestions.first { $0.number == p }?.source.rawValue ?? "typed"
            draft.debug?.log("partner", number: p, modelId: pModel.id, line: line, note: source)
        }
        // The caught vehicle (and its second car) share the sticker; other vehicles in the shot
        // have their own, or none.
        let shot = cars
        // Other vehicles in the shot: catches of their own, each with its own copy of the photo,
        // and a moment earlier still so the one you shot stays on top.
        for (i, n) in draft.alsoAdded.enumerated() {
            guard let v = draft.alsoInShot.first(where: { $0.number == n }), !misreads.contains(n) else { continue }
            let vLine = draft.fromCamera
                ? LiveHints.line(for: n, kind: v.model.kind, snapshot: LiveFleetService.shared.snapshot,
                                 at: draft.date, model: v.model, nearby: draft.nearby, catalog: catalog)
                : nil
            let other = Sighting(number: n, modelId: v.model.id, date: draft.date.addingTimeInterval(-0.002 - 0.001 * Double(i)),
                                 line: vLine, photoFile: PhotoStore.save(draft.photo, ext: ext),
                                 stickerFile: alsoStickers[n].flatMap { PhotoStore.save($0, ext: "png") })
            context.insert(other)
            cars.append(other)
            draft.debug?.log("also-added", number: n, modelId: v.model.id, line: vLine)
        }
        if draft.modelPickedByHand {
            context.assign(number: number, to: model.id, existing: manual)
        }
        try? context.save()
        // Shrinking a full-size shot takes a moment: off the main thread, then each sighting
        // points at its own small copy (HEIC, so a new name) and the full-size one goes.
        let files = cars.map(\.photoFile)
        if files.contains(where: { $0 != nil }) {
            let original = draft.photo
            Task { @MainActor in
                guard let small = await Task.detached(priority: .utility, operation: { PhotoStore.compact(original) }).value
                else { return }
                var replaced: [String] = []
                for (car, file) in zip(cars, files) {
                    // Deleted (or edited) meanwhile: leave it be.
                    guard let file, !car.isDeleted, car.modelContext != nil, car.photoFile == file,
                          let smallFile = PhotoStore.save(small, ext: "heic") else { continue }
                    car.photoFile = smallFile
                    replaced.append(file)
                }
                guard !replaced.isEmpty else { return }
                try? context.save()
                replaced.forEach(PhotoStore.delete)
            }
        }
        // After the reveal, never during it: the Photos permission prompt may appear here.
        if draft.fromCamera, saveToGallery {
            let data = draft.photo
            Task.detached { await PhotoStore.saveToGallery(data) }
        }
        // Subject lifting can outlast the reveal's 2.5 s cap (first run loads the model);
        // attach the sticker whenever it's ready instead of losing it.
        if s.stickerFile == nil, let stickerTask = draft.sticker {
            Task { @MainActor in
                guard let png = await stickerTask.value?.png else { return }
                for car in shot where car.stickerFile == nil && !car.isDeleted && car.modelContext != nil {
                    car.stickerFile = PhotoStore.save(png, ext: "png")
                }
                try? context.save()
            }
        }
        if let tagTask = draft.geotag {
            Task { @MainActor in
                let tag = await tagTask.value
                let place = tag.map { "\($0.coordinate.latitude), \($0.coordinate.longitude) · \($0.street ?? "?"), \($0.district ?? "?")" }
                draft.debug?.update { $0.geotag = place ?? "no location" }
                guard let tag else { return }
                for car in cars where !car.isDeleted && car.modelContext != nil {
                    car.latitude = tag.coordinate.latitude
                    car.longitude = tag.coordinate.longitude
                    car.street = tag.street
                    car.district = tag.district
                }
                try? context.save()
            }
        }
    }

    private func kicker(isNewVehicle: Bool, isNewModel: Bool, modelOwned: Int, added: Int, existing: OwnedVehicle?) -> String {
        guard let model, draft.number != nil else { return String(localized: "NUMBER NEEDED") }
        if !landed { return String(localized: "CUTTING IT OUT…") }
        if !isNewVehicle { return String(localized: "SEEN AGAIN · SIGHTING #\((existing?.timesSeen ?? 0) + 1)") }
        // Both cars of a coupled tram are new.
        if added == 2 {
            let first = Ordinal.string(modelOwned + 1), second = Ordinal.string(modelOwned + 2)
            return isNewModel ? String(localized: "NEW SPECIES · YOUR \(first) & \(second)")
                : String(localized: "TWO NEW CARS · YOUR \(first) & \(second)")
        }
        if isNewModel { return String(localized: "NEW SPECIES · YOUR \(Ordinal.string(1))") }
        let nth = Ordinal.string(modelOwned + added)
        return model.kind == .tram ? String(localized: "NEW TRAM · YOUR \(nth)") : String(localized: "NEW BUS · YOUR \(nth)")
    }
}

/// A one-shot burst of tier-coloured sparks from behind the sticker.
struct SparkleBurst: View {
    let color: Color
    /// 1 for the reveal sticker; smaller for badge medals.
    var reach: CGFloat = 1
    @State private var go = false
    private let sparks: [(angle: Double, dist: CGFloat, size: CGFloat, delay: Double)] = (0..<22).map { i in
        (Double(i) / 22 * 360 + .random(in: -8...8), .random(in: 150...240), .random(in: 3...8), .random(in: 0...0.08))
    }

    var body: some View {
        ZStack {
            ForEach(Array(sparks.enumerated()), id: \.offset) { _, s in
                Circle()
                    .fill(s.size > 5 ? color : .white)
                    .frame(width: s.size, height: s.size)
                    .offset(x: go ? cos(s.angle * .pi / 180) * s.dist * reach : 0,
                            y: go ? sin(s.angle * .pi / 180) * s.dist * 0.7 * reach : 0)
                    .opacity(go ? 0 : 1)
                    .scaleEffect(go ? 0.3 : 1)
                    .animation(.easeOut(duration: 0.8).delay(s.delay), value: go)
            }
        }
        .allowsHitTesting(false)
        .onAppear { go = true }
    }
}

/// A count's noun without the count ("days" under a big "5"). String catalogs insist a
/// plural variant shows its number, so the form (Polish has three) is picked here.
enum PluralCaption {
    private static func form(_ n: Int) -> String {
        guard n != 1 else { return "one" }
        let ones = n % 10, tens = n % 100
        return (2...4).contains(ones) && !(12...14).contains(tens) ? "few" : "many"
    }

    static func days(_ n: Int) -> String {
        switch form(n) {
        case "one": String(localized: "caption.days.one", defaultValue: "day")
        case "few": String(localized: "caption.days.few", defaultValue: "days")
        default: String(localized: "caption.days.many", defaultValue: "days")
        }
    }

    static func sightings(_ n: Int) -> String {
        switch form(n) {
        case "one": String(localized: "caption.sightings.one", defaultValue: "sighting")
        case "few": String(localized: "caption.sightings.few", defaultValue: "sightings")
        default: String(localized: "caption.sightings.many", defaultValue: "sightings")
        }
    }
}
