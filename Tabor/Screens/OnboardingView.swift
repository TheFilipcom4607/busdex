import AVFoundation
import MapKit
import SwiftUI

/// First launch: what TABOR is and why you'd play it, then how, each permission asked for
/// right where it says why. The app proper (and its camera) only starts once it's done;
/// people who already have catches never see it.
struct OnboardingView: View {
    let done: () -> Void
    @State private var page: Page = .welcome
    @State private var askedLocation = false
    private let location = LocationService.shared

    enum Page: Int, CaseIterable { case welcome, book, rarity, camera, buttons, hunt, specials }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Mono("TABOR", size: 12, weight: 600, spacing: 0.3, color: Palette.ink)
                Spacer()
                if page != .specials {
                    Button("SKIP") { finish() }
                        .font(TaborFont.mono(12, 500))
                        .foregroundStyle(Palette.dim)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(height: 36)

            TabView(selection: $page) {
                WelcomePage().tag(Page.welcome)
                BookPage().tag(Page.book)
                RarityPage().tag(Page.rarity)
                CameraPage().tag(Page.camera)
                ButtonsPage().tag(Page.buttons)
                HuntPage().tag(Page.hunt)
                SpecialsPage(active: page == .specials).tag(Page.specials)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { Haptics.shared.tick() }

            dots
                .padding(.bottom, 22)
            Button(action: primary) {
                Mono(primaryLabel, size: 13, weight: 700, spacing: 0.14, color: Palette.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(StickerPressStyle())
            .padding(.horizontal, 24)
            // Room for "Not now" on the permission pages, so the button doesn't jump. The last
            // page puts its photo credit there instead.
            ZStack {
                Button("Not now") { advance() }
                    .font(TaborFont.grotesk(15, 500))
                    .foregroundStyle(Palette.dim)
                    .opacity(needsPermission ? 1 : 0)
                    .disabled(!needsPermission)
                Text("Konstal 13N #795 photo: Janusz Jakubowski, CC BY 2.0, cut out as a sticker.")
                    .font(TaborFont.grotesk(10))
                    .foregroundStyle(Palette.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(page == .specials ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: page)
            }
            .frame(height: 44)
            .padding(.bottom, 6)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        // Location asks asynchronously; go on once the user has answered.
        .onChange(of: location.authorization) { _, status in
            if askedLocation, status != .notDetermined { askedLocation = false; advance() }
        }
    }

    // MARK: - Controls

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { p in
                Capsule()
                    .fill(p == page ? Palette.yellow : Palette.ghost)
                    .frame(width: p == page ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
    }

    /// The permission this page is about hasn't been asked for yet.
    private var needsPermission: Bool {
        switch page {
        case .welcome, .book, .rarity, .specials, .buttons: false
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .hunt: location.authorization == .notDetermined
        }
    }

    private var primaryLabel: String {
        switch page {
        case .welcome: String(localized: "LET'S GO")
        case .book, .rarity, .buttons: String(localized: "NEXT")
        case .camera: needsPermission ? String(localized: "ALLOW CAMERA") : String(localized: "NEXT")
        case .hunt: needsPermission ? String(localized: "ALLOW LOCATION") : String(localized: "NEXT")
        case .specials: String(localized: "START CATCHING")
        }
    }

    private func primary() {
        switch page {
        case .welcome, .book, .rarity, .buttons:
            advance()
        case .camera:
            guard needsPermission else { return advance() }
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                advance()
            }
        case .hunt:
            guard needsPermission else { return advance() }
            askedLocation = true
            location.requestPermission()
        case .specials:
            finish()
        }
    }

    private func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else { return finish() }
        withAnimation(.snappy) { page = next }
    }

    private func finish() {
        Haptics.shared.stick()
        done()
    }
}

// MARK: - Pages

/// Art on top, words below: the same shape on every page, so swiping feels steady.
private struct PageLayout<Art: View>: View {
    let kicker: String
    let title: String
    let text: String
    /// False holds the kicker and text back, so a page can reveal its art first.
    var wordsShown = true
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Mono(kicker, size: 11, weight: 600, spacing: 0.16, color: Palette.yellow)
                .opacity(wordsShown ? 1 : 0)
            Text(title)
                .font(TaborFont.grotesk(30, 700))
                .em(-0.03, size: 30)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text(text)
                .font(TaborFont.grotesk(16))
                .foregroundStyle(Palette.sub)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .opacity(wordsShown ? 1 : 0)
                .offset(y: wordsShown ? 0 : 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 26)
    }
}

/// The app's sticker slaps down, like a catch landing in the book.
private struct WelcomePage: View {
    @State private var landed = false
    private let total = Fleet.catalog.totalFleet

    var body: some View {
        PageLayout(kicker: String(localized: "A COLLECTING GAME FOR WARSAW"),
                   title: String(localized: "Catch every bus and tram in Warsaw."),
                   text: String(localized: "Snap one and it becomes a sticker in your book. Some models run by the hundred; a few, only a handful. \(total.grouped) vehicles to find.")) {
            ZStack {
                RadialGradient(colors: [Palette.yellow.opacity(landed ? 0.22 : 0), .clear],
                               center: .center, startRadius: 10, endRadius: 190)
                if landed { SparkleBurst(color: Palette.yellow, reach: 0.9) }
                Image("WelcomeSticker")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .scaleEffect(landed ? 1 : 1.6)
                    .rotationEffect(.degrees(landed ? 0 : -14))
                    .opacity(landed ? 1 : 0)
            }
        }
        .task {
            guard !landed else { return }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { landed = true }
            try? await Task.sleep(for: .milliseconds(120))
            Haptics.shared.stick()
        }
    }
}

/// Why you'd keep going: a few book rows filling up, one per rarity, so "rare" means
/// something before the first catch does.
private struct BookPage: View {
    @State private var filled = false

    /// The biggest regular model in each tier, buses and trams taking turns: real names,
    /// and the fleet sizes that make the rarity obvious (a dozen against hundreds).
    private let rows: [(model: VehicleModel, share: Double)] = {
        let regular = Fleet.catalog.models.filter(\.regular)
        let picks: [(Tier, VehicleKind, Double)] = [(.legendary, .bus, 0.17), (.gold, .tram, 0.4), (.rare, .bus, 0.55), (.common, .tram, 0.72)]
        return picks.compactMap { tier, kind, share in
            let inTier = regular.filter { $0.tier == tier }
            let pick = inTier.filter { $0.kind == kind }.max { $0.fleet < $1.fleet } ?? inTier.max { $0.fleet < $1.fleet }
            return pick.map { ($0, share) }
        }
    }()

    var body: some View {
        PageLayout(kicker: String(localized: "BOOK"),
                   title: String(localized: "Fill the book, model by model."),
                   text: String(localized: "Every model has a page and every vehicle a slot, and badges come along the way. The colours are rarity: more on that next.")) {
            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    MiniRow(model: row.model, share: filled ? row.share : 0)
                        .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(Double(i) * 0.12), value: filled)
                }
            }
            .frame(width: 310)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            filled = true
        }
    }

    /// A slimmer book row: name and rarity, then how much of the model is caught.
    private struct MiniRow: View {
        let model: VehicleModel
        let share: Double

        var body: some View {
            let owned = Int((Double(model.fleet) * share).rounded(.up))
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.kind == .tram ? "tram.fill" : "bus.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.sub)
                    Text(model.name)
                        .font(TaborFont.grotesk(14, 600))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Mono(model.tier.name, size: 10, weight: 700, spacing: 0.12, color: model.tier.color)
                }
                HStack(spacing: 10) {
                    ProgressBar(fraction: share, color: model.tier.bar, height: 5)
                    OwnedCount(owned: owned, fleet: model.fleet, size: 12)
                        .contentTransition(.numericText())
                        .frame(minWidth: 58, alignment: .trailing)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
        }
    }
}

/// Why a model is the rarity it is, since it isn't obvious: it's how many of it there are,
/// not how old or odd it looks. One dot per vehicle at each tier's ceiling, so the gap
/// between a dozen and hundreds is something you see rather than read.
private struct RarityPage: View {
    @State private var shown = false
    private static let perRow = 32
    /// COMMON has no ceiling; three full rows trailing off say "and lots more".
    private static let commonDots = perRow * 3
    private static let ladder: [Tier] = [.legendary, .gold, .rare, .common]

    var body: some View {
        PageLayout(kicker: String(localized: "RARITY"),
                   title: String(localized: "The fewer there are, the rarer."),
                   text: String(localized: "Rarity is how many of a model run in Warsaw, not how old or unusual it is. A legendary has 12 or fewer, so each one is a find.")) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(Self.ladder.enumerated()), id: \.offset) { i, tier in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Mono(tier.name, size: 11, weight: 700, spacing: 0.12, color: tier.color)
                            Spacer()
                            Mono(range(i), size: 11, weight: 600, spacing: 0.08, color: Palette.sub)
                        }
                        dots(tier.maxFleet ?? Self.commonDots, color: tier.bar, fades: tier.maxFleet == nil)
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown ? 0 : 6)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.15), value: shown)
                    }
                }
            }
            .frame(width: 310)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            shown = true
        }
    }

    /// Each tier starts one above the ceiling of the tier before it.
    private func range(_ i: Int) -> String {
        let floor = (i > 0 ? Self.ladder[i - 1].maxFleet! : 0) + 1
        guard let max = Self.ladder[i].maxFleet else { return String(localized: "\(floor) OR MORE") }
        return i == 0 ? String(localized: "\(max) OR FEWER") : "\(floor)–\(max)"
    }

    private func dots(_ count: Int, color: Color, fades: Bool) -> some View {
        let pitch = 310 / CGFloat(Self.perRow)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(pitch), spacing: 0), count: Self.perRow),
                         alignment: .leading, spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(color).frame(width: pitch - 3, height: pitch - 3)
            }
        }
        .mask {
            if fades {
                LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
    }
}

/// The last page, a "one more thing": the stock outside the rarity scale. Works cars most of
/// all: most people don't know they exist, and they're off the live map, so without this
/// you'd see one and think it can't be caught. Their book section only opens once you do.
/// The title stands alone for a beat, then a real sticker of each lands, tier by tier, then
/// the words.
private struct SpecialsPage: View {
    let active: Bool
    @State private var stuck = 0
    @State private var told = false

    /// Laid out on a 340 × 290 board, scaled down to whatever room the page leaves.
    private static let board = CGSize(width: 340, height: 290)
    private static let stickers: [(image: String, tier: Tier, width: CGFloat, at: CGPoint, tilt: Double)] = [
        ("IntroStickerVintage", .vintage, 150, CGPoint(x: 88, y: 72), -7),
        ("IntroStickerTest", .onTest, 180, CGPoint(x: 246, y: 66), 5),
        ("IntroStickerWorks", .works, 270, CGPoint(x: 178, y: 200), -2),
    ]

    var body: some View {
        PageLayout(kicker: String(localized: "SPECIALS"),
                   title: String(localized: "One more thing…"),
                   text: String(localized: "Museum buses and trams on summer weekends, buses here on trial, and the tram company's own works cars: measuring, welding and transport cars with no timetable and no spot on the live map. Spot one, catch it. None of them count toward the fleet %."),
                   wordsShown: told) {
            GeometryReader { g in
                let scale = min(1, g.size.width / Self.board.width, g.size.height / Self.board.height)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(Self.stickers.enumerated()), id: \.offset) { i, s in
                        sticker(s.image, tier: s.tier, width: s.width, shown: stuck > i)
                            .rotationEffect(.degrees(s.tilt))
                            .position(s.at)
                    }
                }
                .frame(width: Self.board.width, height: Self.board.height)
                .scaleEffect(scale)
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        // Only once it's the page on screen: a TabView builds its neighbours early.
        .task(id: active) {
            guard active, stuck == 0 else { return }
            try? await Task.sleep(for: .milliseconds(1300))
            for i in Self.stickers.indices {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { stuck = i + 1 }
                try? await Task.sleep(for: .milliseconds(110))
                Haptics.shared.stick()
                try? await Task.sleep(for: .milliseconds(i == Self.stickers.count - 1 ? 400 : 480))
            }
            withAnimation(.easeOut(duration: 0.45)) { told = true }
        }
    }

    /// A sticker slapping down onto the page, its tier on a tag at the corner.
    private func sticker(_ image: String, tier: Tier, width: CGFloat, shown: Bool) -> some View {
        Image(image)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            .overlay(alignment: .bottomLeading) {
                Mono(tier.name, size: 10, weight: 700, spacing: 0.12, color: tier.color)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .background(Palette.chip, in: Capsule())
                    .overlay(Capsule().stroke(tier.color.opacity(0.5)))
                    .offset(x: 6, y: 8)
            }
            .scaleEffect(shown ? 1 : 1.6)
            .rotationEffect(.degrees(shown ? 0 : -12))
            .opacity(shown ? 1 : 0)
    }
}

/// A real photo of a whole bus framed in the brackets, with the number on its front picked
/// out: the vehicle is what becomes the sticker, the number only has to be in the shot.
/// The line number on its display is marked too, because that's the one people read first.
private struct CameraPage: View {
    @State private var found = false
    /// Where "1972" and the line "163" sit in the photo, as fractions of the image.
    private static let number = CGRect(x: 0.293, y: 0.612, width: 0.05, height: 0.05)
    private static let line = CGRect(x: 0.136, y: 0.214, width: 0.048, height: 0.072)

    var body: some View {
        PageLayout(kicker: String(localized: "CATCH"),
                   title: String(localized: "Get the whole bus in the shot."),
                   text: String(localized: "Front, side or back, with its fleet number in view: the number painted on the vehicle, not the line number. TABOR finds it, knows the model and cuts the vehicle out as your sticker. The rarer it is, the bigger the reveal.")) {
            VStack(spacing: 14) {
                ZStack {
                    Image("ViewfinderBus")
                        .resizable()
                        .scaledToFill()
                    GeometryReader { g in
                        mark(Self.line, in: g.size, color: .white.opacity(0.75), label: String(localized: "LINE"), above: true)
                            .opacity(found ? 1 : 0)
                        mark(Self.number, in: g.size, color: Palette.green, label: String(localized: "FLEET NO."), above: false)
                            .scaleEffect(found ? 1 : 2.2)
                            .opacity(found ? 1 : 0)
                    }
                    Brackets()
                        .stroke(Palette.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .padding(12)
                }
                .frame(width: 320, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                HStack(spacing: 7) {
                    Circle().fill(Palette.green).frame(width: 6, height: 6)
                    Mono("1972 · YUTONG U12", size: 11, weight: 600, spacing: 0.1, color: Palette.ink)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Palette.chip, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline))
                .opacity(found ? 1 : 0.35)
            }
        }
        .task {
            // Framed, then a beat later the number is picked out, as the shot's read does.
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { found = true }
        }
    }

    /// A box around a spot in the photo, with a small label just outside it.
    private func mark(_ r: CGRect, in size: CGSize, color: Color, label: String, above: Bool) -> some View {
        let box = CGRect(x: size.width * r.minX, y: size.height * r.minY, width: size.width * r.width, height: size.height * r.height)
        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(color, lineWidth: 2.5)
                .shadow(color: color.opacity(0.8), radius: 4)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
            Mono(label, size: 8.5, weight: 700, spacing: 0.1, color: .black)
                .fixedSize()
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .position(x: box.midX, y: above ? box.minY - 10 : box.maxY + 10)
        }
    }
}

/// The hardware shutter: the phone held sideways, as you'd hold it for a bus, its shutter
/// buttons pressed one at a time (one lights up, the photo flashes) so it reads as either
/// button, not both. Camera Control only on phones that have it (iPhone 16 and later, not
/// the 16e), which the capture session knows without a list of models.
private struct ButtonsPage: View {
    private enum Press { case none, volumeUp, volumeDown, control }
    private static let hasCameraControl = AVCaptureSession().supportsControls
    @State private var press = Press.none

    /// The phone in the art's points. Held with Camera Control on top, so the volume
    /// buttons end up on the bottom edge and the Dynamic Island on the left.
    private static let size = CGSize(width: 340, height: 230)
    private static let phone = CGRect(x: 40, y: 52, width: 260, height: 126)

    var body: some View {
        PageLayout(kicker: String(localized: "SHUTTER"),
                   title: String(localized: "Press a button, catch the bus."),
                   text: Self.hasCameraControl
                       ? String(localized: "Click Camera Control or either volume button to take the shot: quicker than finding the shutter as a bus pulls away. Slide along Camera Control to zoom.")
                       : String(localized: "Press either volume button to take the shot: quicker than finding the shutter as a bus pulls away.")) {
            let r = Self.phone
            ZStack {
                // Where they sit along an iPhone 16 Pro, from the Dynamic Island end. Bottom
                // edge: Action button, volume up, volume down; top edge: the side button
                // across from the volume buttons, then Camera Control.
                key(x: r.minX + 0.22 * r.width, length: 12, top: false, shutter: false, pressed: false)
                key(x: r.minX + 0.32 * r.width, length: 22, top: false, shutter: true, pressed: press == .volumeUp)
                key(x: r.minX + 0.43 * r.width, length: 22, top: false, shutter: true, pressed: press == .volumeDown)
                label(String(localized: "VOLUME"), x: r.minX + 0.375 * r.width, top: false,
                      pressed: press == .volumeUp || press == .volumeDown)
                key(x: r.minX + 0.375 * r.width, length: 32, top: true, shutter: false, pressed: false)
                if Self.hasCameraControl {
                    key(x: r.minX + 0.66 * r.width, length: 24, top: true, shutter: true, pressed: press == .control)
                    label(String(localized: "CAMERA CONTROL"), x: r.minX + 0.66 * r.width, top: true, pressed: press == .control)
                }
                phone
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .task {
            // One button per shot, each in turn, slowly enough to read, for as long as the
            // page is up.
            while !Task.isCancelled {
                for p in Self.hasCameraControl ? [Press.volumeUp, .control, .volumeDown] : [.volumeUp, .volumeDown] {
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) { press = p }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeOut(duration: 0.35)) { press = .none }
                }
            }
        }
    }

    /// The welcome sticker in the viewfinder; each shot flashes the screen and bumps the
    /// sticker, like a catch landing.
    private var phone: some View {
        let body = RoundedRectangle(cornerRadius: 30, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let shot = press != .none
        return ZStack {
            body.fill(Palette.card)
                .overlay(body.stroke(Color.white.opacity(0.14), lineWidth: 1.5))
            ZStack {
                RadialGradient(colors: [Palette.yellow.opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 120)
                Image("WelcomeSticker")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(shot ? 4 : -6))
                    .scaleEffect(shot ? 1.08 : 1)
                Brackets()
                    .stroke(Palette.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 128, height: 104)
                // The Dynamic Island, on the left with the phone on its side.
                Capsule().fill(Color.white.opacity(0.08))
                    .frame(width: 9, height: 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                Color.white.opacity(shot ? 0.55 : 0)
            }
            .background(Palette.bg)
            .clipShape(screen)
            .padding(6)
        }
    }

    /// A button on the phone's top or bottom edge. Only the one being pressed lights up and
    /// sinks in, so it reads as "either of these", never "both".
    private func key(x: CGFloat, length: CGFloat, top: Bool, shutter: Bool, pressed: Bool) -> some View {
        let r = Self.phone
        let edge = top ? r.minY - 1.5 : r.maxY + 1.5
        return Capsule()
            .fill(pressed ? Palette.yellow : shutter ? Palette.sub.opacity(0.7) : Palette.ghost)
            .frame(width: length, height: 3)
            .shadow(color: Palette.yellow.opacity(pressed ? 0.8 : 0), radius: 6)
            .position(x: x, y: edge + (pressed ? (top ? 1.5 : -1.5) : 0))
    }

    /// The button's name, lit while it's the one being pressed.
    private func label(_ text: String, x: CGFloat, top: Bool, pressed: Bool) -> some View {
        let r = Self.phone
        return Mono(text, size: 10, weight: 700, spacing: 0.12, color: pressed ? Palette.bg : Palette.dim)
            .fixedSize()
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(pressed ? Palette.yellow : Color.clear, in: Capsule())
            .position(x: x, y: top ? r.minY - 20 : r.maxY + 20)
    }
}

/// Camera-style corner brackets.
private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        let l: CGFloat = 26
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1, 1), (r.minX, r.maxY, 1, -1), (r.maxX, r.maxY, -1, -1)] {
            p.move(to: CGPoint(x: x, y: y + dy * l))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

/// A little HUNT map on the real city: you at Centrum, uncaught vehicles on the streets
/// around you in their rarity colours. It's a picture, not a map to use, so it doesn't
/// take touches (and the page still swipes over it).
private struct HuntPage: View {
    private struct MockPin: Identifiable {
        let id: Int
        let tier: Tier
        let line: String
        let tram: Bool
        let arrow: String
        let filled: Bool
        let at: CLLocationCoordinate2D
    }

    /// Rondo Dmowskiego, where Marszałkowska crosses Aleje Jerozolimskie.
    private static let here = CLLocationCoordinate2D(latitude: 52.2302, longitude: 21.0117)
    private static let camera = MapCameraPosition.region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.2304, longitude: 21.0117),
                           latitudinalMeters: 1100, longitudinalMeters: 1100))

    private let pins = [
        MockPin(id: 0, tier: .legendary, line: "128", tram: false, arrow: "arrow.up", filled: true,
                at: CLLocationCoordinate2D(latitude: 52.2326, longitude: 21.0105)),
        MockPin(id: 1, tier: .gold, line: "25", tram: true, arrow: "arrow.left", filled: false,
                at: CLLocationCoordinate2D(latitude: 52.2309, longitude: 21.0150)),
        MockPin(id: 2, tier: .rare, line: "175", tram: false, arrow: "arrow.right", filled: true,
                at: CLLocationCoordinate2D(latitude: 52.2295, longitude: 21.0080)),
        MockPin(id: 3, tier: .common, line: "18", tram: true, arrow: "arrow.down", filled: false,
                at: CLLocationCoordinate2D(latitude: 52.2280, longitude: 21.0128)),
        MockPin(id: 4, tier: .common, line: "507", tram: false, arrow: "arrow.right", filled: true,
                at: CLLocationCoordinate2D(latitude: 52.2320, longitude: 21.0195)),
        MockPin(id: 5, tier: .gold, line: "160", tram: false, arrow: "arrow.left", filled: true,
                at: CLLocationCoordinate2D(latitude: 52.2284, longitude: 21.0040)),
    ]

    var body: some View {
        PageLayout(kicker: String(localized: "HUNT"),
                   title: String(localized: "See what you haven't caught, live."),
                   text: String(localized: "HUNT maps every bus and tram running near you that isn't in your book yet, and which way it's going. Location is only used while TABOR is open.")) {
            Map(initialPosition: Self.camera, interactionModes: []) {
                Annotation("", coordinate: Self.here) {
                    ZStack {
                        // Animated from inside the annotation: one started outside the map
                        // doesn't carry into it.
                        Circle()
                            .fill(Palette.radar.opacity(0.3))
                            .phaseAnimator([false, true]) { c, out in
                                c.scaleEffect(out ? 1 : 0.25).opacity(out ? 0 : 1)
                            } animation: { out in out ? .easeOut(duration: 1.8) : nil }
                            .frame(width: 70, height: 70)
                        Circle()
                            .fill(Palette.radar)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                    .frame(width: 70, height: 70)
                }
                .annotationTitles(.hidden)
                ForEach(pins) { p in
                    Annotation("", coordinate: p.at, anchor: .bottom) {
                        tag(p)
                            .phaseAnimator([false, true]) { t, up in
                                t.offset(y: (up ? -3 : 3) * (p.id.isMultiple(of: 2) ? 1 : -1))
                            } animation: { _ in .easeInOut(duration: 1.4) }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {}
            .environment(\.colorScheme, .dark)
            // Shown before the tiles load, or if they can't.
            .background(Palette.mapBg)
            .allowsHitTesting(false)
            .frame(maxWidth: 360, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
        }
    }

    /// Like HUNT's own pins: filled for a model new to you, outlined for one you have.
    private func tag(_ p: MockPin) -> some View {
        let color = p.tier.mapColor
        return HStack(spacing: 4) {
            Image(systemName: p.tram ? "tram.fill" : "bus.fill")
                .font(.system(size: 11, weight: .bold))
            Text(p.line)
                .font(TaborFont.mono(13, 700))
            Image(systemName: p.arrow)
                .font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(p.filled ? p.tier.onMapColor : color)
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(p.filled ? color : Palette.bg.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color, lineWidth: p.filled ? 0 : 1.5))
        .shadow(color: color.opacity(0.45), radius: 6)
    }
}
