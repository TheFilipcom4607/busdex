import AVFoundation
import SwiftUI

/// First launch: three pages on what TABOR is, each asking for the permission it needs
/// right where it says why. The app proper (and its camera) only starts once it's done;
/// people who already have catches never see it.
struct OnboardingView: View {
    let done: () -> Void
    @State private var page: Page = .welcome
    @State private var askedLocation = false
    private let location = LocationService.shared

    enum Page: Int, CaseIterable { case welcome, camera, hunt }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Mono("TABOR", size: 12, weight: 600, spacing: 0.3, color: Palette.ink)
                Spacer()
                if page != .hunt {
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
                CameraPage().tag(Page.camera)
                HuntPage().tag(Page.hunt)
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
            // Room for "Not now" on the permission pages, so the button doesn't jump.
            Button("Not now") { advance() }
                .font(TaborFont.grotesk(15, 500))
                .foregroundStyle(Palette.dim)
                .frame(height: 44)
                .opacity(needsPermission ? 1 : 0)
                .disabled(!needsPermission)
                .padding(.bottom, 6)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        // Location asks asynchronously; go on once the user has answered.
        .onChange(of: location.authorization) { _, status in
            if askedLocation, status != .notDetermined { finish() }
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
        case .welcome: false
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .hunt: location.authorization == .notDetermined
        }
    }

    private var primaryLabel: String {
        switch page {
        case .welcome: "LET'S GO"
        case .camera: needsPermission ? "ALLOW CAMERA" : "NEXT"
        case .hunt: needsPermission ? "ALLOW LOCATION" : "START CATCHING"
        }
    }

    private func primary() {
        switch page {
        case .welcome:
            advance()
        case .camera:
            guard needsPermission else { return advance() }
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                advance()
            }
        case .hunt:
            guard needsPermission else { return finish() }
            askedLocation = true
            location.requestPermission()
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
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Mono(kicker, size: 11, weight: 600, spacing: 0.16, color: Palette.yellow)
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
        PageLayout(kicker: "WARSAW ROLLING STOCK",
                   title: "Catch every bus and tram in Warsaw.",
                   text: "Photograph a vehicle's fleet number and TABOR turns it into a sticker for your book. \(total.grouped) of them are out there.") {
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

/// A real photo of a whole bus framed in the brackets, with the number on its front picked
/// out: the vehicle is what becomes the sticker, the number only has to be in the shot.
private struct CameraPage: View {
    @State private var found = false
    /// Where "1971" sits on the bus's front in the photo, as fractions of the image.
    private static let number = CGRect(x: 0.2465, y: 0.6625, width: 0.047, height: 0.0475)

    var body: some View {
        PageLayout(kicker: "CATCH",
                   title: "Get the whole bus in the shot.",
                   text: "Front, side or back, with its fleet number somewhere in view. TABOR finds the number, knows the model and cuts the vehicle out as your sticker. The rarer it is, the bigger the reveal.") {
            VStack(spacing: 14) {
                ZStack {
                    Image("ViewfinderBus")
                        .resizable()
                        .scaledToFill()
                    GeometryReader { g in
                        let n = Self.number
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Palette.green, lineWidth: 2.5)
                            .shadow(color: Palette.green.opacity(0.8), radius: 4)
                            .frame(width: g.size.width * n.width, height: g.size.height * n.height)
                            .scaleEffect(found ? 1 : 2.2)
                            .opacity(found ? 1 : 0)
                            .position(x: g.size.width * n.midX, y: g.size.height * n.midY)
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
                    Mono("1971 · YUTONG U12 · TAP TO CATCH", size: 11, weight: 600, spacing: 0.1, color: Palette.ink)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Palette.chip, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline))
                .opacity(found ? 1 : 0.35)
                // CC BY-SA 4.0 asks for the credit wherever the photo is shown.
                Text("Photo: J2 kolej, CC BY-SA 4.0, via Wikimedia Commons")
                    .font(TaborFont.grotesk(10))
                    .foregroundStyle(Palette.faint)
            }
        }
        .task {
            // Framed, then a beat later the number is picked out, like the live camera does.
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { found = true }
        }
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

/// A little HUNT map: you in the middle, uncaught vehicles around you in their rarity colours.
private struct HuntPage: View {
    @State private var bob = false
    @State private var pulse = false

    private struct MockPin: Identifiable {
        let id: Int
        let tier: Tier
        let line: String
        let tram: Bool
        let arrow: String
        let filled: Bool
        let x: CGFloat, y: CGFloat
    }

    private let pins = [
        MockPin(id: 0, tier: .legendary, line: "514", tram: false, arrow: "arrow.up.right", filled: true, x: -82, y: -58),
        MockPin(id: 1, tier: .gold, line: "18", tram: true, arrow: "arrow.left", filled: false, x: 78, y: -34),
        MockPin(id: 2, tier: .rare, line: "157", tram: false, arrow: "arrow.down", filled: true, x: 58, y: 52),
        MockPin(id: 3, tier: .common, line: "9", tram: true, arrow: "arrow.right", filled: false, x: -92, y: 46),
    ]

    var body: some View {
        PageLayout(kicker: "HUNT",
                   title: "See what you haven't caught, live.",
                   text: "HUNT maps every bus and tram running near you that isn't in your book yet, and which way it's going. Location is only used while TABOR is open.") {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Palette.mapBg)
                Streets()
                    .stroke(Color.white.opacity(0.07), lineWidth: 7)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Circle()
                    .fill(Palette.radar.opacity(0.25))
                    .frame(width: pulse ? 70 : 18, height: pulse ? 70 : 18)
                    .opacity(pulse ? 0 : 1)
                Circle()
                    .fill(Palette.radar)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                ForEach(pins) { p in
                    tag(p)
                        .offset(x: p.x, y: p.y + (bob ? -3 : 3) * (p.id.isMultiple(of: 2) ? 1 : -1))
                }
            }
            .frame(width: 300, height: 220)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bob = true }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
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

/// A few crossing streets behind the mock map.
private struct Streets: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.height * 0.3)); p.addLine(to: CGPoint(x: r.maxX, y: r.height * 0.55))
        p.move(to: CGPoint(x: r.minX, y: r.height * 0.82)); p.addLine(to: CGPoint(x: r.maxX, y: r.height * 0.7))
        p.move(to: CGPoint(x: r.width * 0.35, y: r.minY)); p.addLine(to: CGPoint(x: r.width * 0.45, y: r.maxY))
        p.move(to: CGPoint(x: r.width * 0.78, y: r.minY)); p.addLine(to: CGPoint(x: r.width * 0.68, y: r.maxY))
        return p
    }
}
