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
    @State private var editing = false
    @State private var holdProgress = 0.0
    @State private var holding = false
    @State private var sticking = false
    @State private var tilt: CGSize = .zero
    @State private var nudge = false
    @State private var revealRun = 0

    private let catalog = Fleet.catalog
    private let holdDuration = 0.55

    private static let shotDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
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
                HStack {
                    Mono("CONFIRM", size: 12, spacing: 0.16)
                    Spacer()
                    Button {
                        draft.geotag?.cancel()
                        draft.debug?.log("retake", number: draft.number, modelId: draft.modelId)
                        dismiss()
                    } label: { Mono("RETAKE", size: 12) }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
                .padding(.horizontal, 22)

                VStack(alignment: .leading, spacing: 7) {
                    Mono(kicker(isNewVehicle: isNewVehicle, isNewModel: isNewModel, modelOwned: modelOwned, existing: existing),
                         size: 12, spacing: 0.16, color: accent)
                    Text(model?.name ?? (number == nil ? "What did you catch?" : "Which model is it?"))
                        .font(TaborFont.grotesk(30, 700))
                        .em(-0.03, size: 30)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .padding(.top, 20)
                .padding(.horizontal, 26)

                stage(number: number, model: model, tier: tier, isNew: isNewVehicle && ready)
                    .frame(maxWidth: .infinity)
                    .frame(height: 250)
                    .padding(.top, 12)

                if ready, let model, let number {
                    HStack(spacing: 10) {
                        StatTile(label: "YOUR", value: isNewVehicle ? Ordinal.string(modelOwned + 1) : "×\(existing!.timesSeen + 1)",
                                 valueColor: Palette.yellow, caption: isNewVehicle ? "of \(model.fleet)" : "sightings")
                        StatTile(label: "MODEL", value: isNewModel ? "NEW" : "\(modelOwned + (isNewVehicle ? 1 : 0))",
                                 valueColor: isNewModel ? Palette.green : Palette.ink,
                                 caption: isNewModel ? "species" : "of \(model.fleet)")
                        if Calendar.current.isDateInToday(draft.date) {
                            StatTile(label: "STREAK", value: "\(Streak.days(sightings.map(\.date) + [draft.date]))",
                                     caption: "days")
                        } else {
                            // Imported shot from another day: it doesn't touch today's streak.
                            StatTile(label: "SHOT", value: Self.shotDate.string(from: draft.date).uppercased(),
                                     valueSize: 18, caption: Self.shotYear.string(from: draft.date))
                        }
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 26)
                    .opacity(landed ? 1 : 0)
                    .offset(y: landed ? 0 : 14)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: landed)

                    let owned = Set(stats.owned(modelId: model.id).map(\.number)).union([number])
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
                    Button {
                        editing = true
                    } label: {
                        Mono(ready ? "WRONG NUMBER?" : "EDIT DETAILS", size: 12.5, color: Palette.sub)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 20)
                .opacity(sticking ? 0 : 1)
            }
            .foregroundStyle(Palette.ink)
        }
        .sheet(isPresented: $editing) {
            CorrectionSheet(draft: $draft)
        }
        // One key, so fixing number and model together replays the reveal once.
        .onChange(of: "\(draft.number ?? -1)|\(draft.modelId ?? "")") { _, _ in edited() }
        .task { await playReveal(run: 0) }
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
                        .overlay {
                            GlossSweep()
                                .mask(Image(uiImage: img).resizable().scaledToFit())
                        }
                        .shadow(color: .black.opacity(0.6), radius: 14, y: 16)
                        .overlay(alignment: .topTrailing) {
                            if isNew { newBadge }
                        }
                    stickerCaption(number: number, model: model, tier: tier, batch: batch)
                }
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
                Mono([batch?.depotDisplay, batch?.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                     .nonEmpty ?? (model?.kind.rawValue ?? "NUMBER NOT READ"), size: 10.5, spacing: 0.12, color: Palette.sub)
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
        case .vintage: 0.62
        }
    }

    private func playReveal(run: Int) async {
        // Wait for the cut-out (usually ~0.2s on device), capped so a slow model never stalls.
        if stickerImage == nil, let task = draft.sticker {
            let png = await withTaskGroup(of: Data??.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2.5)); return .some(nil) }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? nil
            }
            guard run == revealRun else { return }
            stickerPNG = png
            stickerImage = png.flatMap(UIImage.init(data:))
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
        // Peel: lift and straighten.
        withAnimation(.easeOut(duration: 0.2)) { tilt = .zero }
        try? await Task.sleep(for: .milliseconds(240))
        // Slap: fly down into the book.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { sticking = true }
        save(model: model, number: number)

        let owned = ownedBefore.union([number])
        let batchDone = model.batch(containing: number).map { $0.numbers.allSatisfy(owned.contains) } ?? false
        let firstTime = !ownedBefore.contains(number)
        try? await Task.sleep(for: .milliseconds(480))
        router.openModel(model.id)
        dismiss()
        if firstTime, batchDone || model.numbers.allSatisfy(owned.contains) {
            try? await Task.sleep(for: .milliseconds(450))
            Haptics.shared.completed()
        }
    }

    private func save(model: VehicleModel, number: Int) {
        let s = Sighting(number: number, modelId: model.id, date: draft.date,
                         line: draft.line?.trimmingCharacters(in: .whitespaces).nonEmpty,
                         photoFile: PhotoStore.save(draft.photo, ext: PhotoStore.fileExtension(of: draft.photo)),
                         stickerFile: stickerPNG.flatMap { PhotoStore.save($0, ext: "png") })
        context.insert(s)
        draft.debug?.log("stuck", number: number, modelId: model.id, line: s.line)
        if draft.modelPickedByHand {
            context.assign(number: number, to: model.id, existing: manual)
        }
        try? context.save()
        // After the reveal, never during it: the Photos permission prompt may appear here.
        if draft.fromCamera, saveToGallery {
            let data = draft.photo
            Task.detached { await PhotoStore.saveToGallery(data) }
        }
        // Subject lifting can outlast the reveal's 2.5 s cap (first run loads the model);
        // attach the sticker whenever it's ready instead of losing it.
        if s.stickerFile == nil, let stickerTask = draft.sticker {
            Task { @MainActor in
                guard let png = await stickerTask.value, let file = PhotoStore.save(png, ext: "png") else { return }
                s.stickerFile = file
                try? context.save()
            }
        }
        if let tagTask = draft.geotag {
            Task { @MainActor in
                let tag = await tagTask.value
                let place = tag.map { "\($0.coordinate.latitude), \($0.coordinate.longitude) · \($0.street ?? "?"), \($0.district ?? "?")" }
                draft.debug?.update { $0.geotag = place ?? "no location" }
                guard let tag else { return }
                s.latitude = tag.coordinate.latitude
                s.longitude = tag.coordinate.longitude
                s.street = tag.street
                s.district = tag.district
                try? context.save()
            }
        }
    }

    private func kicker(isNewVehicle: Bool, isNewModel: Bool, modelOwned: Int, existing: OwnedVehicle?) -> String {
        guard model != nil, draft.number != nil else { return "NUMBER NEEDED" }
        if !landed { return "CUTTING IT OUT…" }
        if !isNewVehicle { return "SEEN AGAIN · SIGHTING #\((existing?.timesSeen ?? 0) + 1)" }
        if isNewModel { return "NEW SPECIES · YOUR 1st" }
        return "NEW \(model!.kind.rawValue) · YOUR \(Ordinal.string(modelOwned + 1))"
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
