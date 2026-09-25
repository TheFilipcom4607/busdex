import SwiftUI

// MARK: - Medal look

extension Medal {
    /// Light to dark, for the rim and face gradients.
    var colors: [Color] {
        switch self {
        case .none: [Color(hex: 0x2A2E34), Color(hex: 0x1B1E23)]
        case .bronze: [Color(hex: 0xF0B27A), Color(hex: 0x8E5327)]
        case .silver: [Color(hex: 0xF4F6F9), Color(hex: 0x87909B)]
        case .gold: [Color(hex: 0xFFE68A), Color(hex: 0xC99700)]
        case .platinum: [Color(hex: 0xEFFCFF), Color(hex: 0x86D6EE), Color(hex: 0xC3B2FF)]
        }
    }

    var glow: Color { colors.count > 1 ? colors[1] : .clear }

    var name: String { rawValue.uppercased() }
}

/// A struck coin: bright metal rim, a recessed face and an embossed symbol, with a sheen
/// that sweeps across when earned. Locked ones are a dark disc with a progress ring.
/// Wrap it in `SpinningCoin` to give it thickness.
struct Medallion: View {
    let badge: Achievement
    var size: CGFloat = 64
    var showsProgress = true

    private var revealed: Bool { !badge.secret || badge.earned }

    var body: some View {
        Group {
            if badge.earned { earned } else { locked }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var earned: some View {
        let colors = badge.medal.colors
        let light = colors[0], dark = colors[colors.count - 1]
        let rim = size * 0.1
        return ZStack {
            // Rim: light catches the top-left, falls off to the bottom-right.
            Circle().fill(LinearGradient(colors: [light, dark], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Face sits below the rim, so it's lit the other way round.
            Circle()
                .fill(LinearGradient(colors: [dark, light], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(rim)
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom).opacity(0.85))
                .padding(rim + size * 0.02)
            glyph(color: dark.mix(with: .black, by: 0.55))
                .shadow(color: light.opacity(0.9), radius: 0, x: -0.6, y: -0.6)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0.8, y: 0.8)
            MedalSheen(seed: badge.id).blendMode(.overlay)
        }
        .mask(Circle())
    }

    private var locked: some View {
        ZStack {
            Circle().fill(Palette.card)
            if badge.secret {
                Circle()
                    .inset(by: size * 0.03)
                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                    .foregroundStyle(Palette.ghost)
            } else if showsProgress {
                Circle()
                    .inset(by: size * 0.035)
                    .stroke(Palette.track, lineWidth: size * 0.05)
                Circle()
                    .inset(by: size * 0.035)
                    .trim(from: 0, to: badge.fraction)
                    .stroke(Palette.yellow, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            glyph(color: revealed ? Palette.dim : Palette.ghost)
        }
    }

    private func glyph(color: Color) -> some View {
        Image(systemName: revealed ? badge.symbol : "questionmark")
            .font(.system(size: size * (revealed ? 0.36 : 0.4), weight: .bold))
            .foregroundStyle(color)
    }
}

/// A band of light crossing the medal every few seconds; each badge on its own beat.
struct MedalSheen: View {
    let seed: String

    var body: some View {
        let offset = Double(abs(seed.hashValue % 1000)) / 1000 * 5.5
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            GeometryReader { g in
                let t = (ctx.date.timeIntervalSinceReferenceDate + offset).truncatingRemainder(dividingBy: 5.5) / 5.5
                let p = min(t / 0.35, 1)
                LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.45, height: g.size.height * 1.8)
                    .rotationEffect(.degrees(22))
                    .offset(x: -g.size.width * 0.7 + g.size.width * 1.9 * p, y: -g.size.height * 0.4)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One pip per level, filled in the medal colour reached.
struct LevelPips: View {
    let badge: Achievement

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<badge.levels, id: \.self) { i in
                Circle()
                    .fill(i < badge.level ? Achievement.medal(level: i + 1, of: badge.levels).colors[1] : Palette.track)
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Shelf on the Me screen

struct BadgeShelf: View {
    let badges: [Achievement]
    @State private var showAll = false
    @State private var selected: Achievement?
    private static let collapsed = 9

    var body: some View {
        // Earned first (best medals up front), then closest to done; secrets last.
        let sorted = badges.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.earned != y.earned { return x.earned }
            if x.earned { return (x.level * 10 / max(x.levels, 1), -a.offset) > (y.level * 10 / max(y.levels, 1), -b.offset) }
            if x.secret != y.secret { return !x.secret }
            if x.fraction != y.fraction { return x.fraction > y.fraction }
            return a.offset < b.offset
        }.map(\.element)
        let shown = showAll ? sorted : Array(sorted.prefix(Self.collapsed))
        let earned = badges.filter(\.earned).count

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "BADGES")
                Spacer()
                Mono("\(earned) OF \(badges.count)", size: 10.5, color: earned > 0 ? Palette.yellow : Palette.faint)
            }
            ProgressBar(fraction: Double(earned) / Double(max(badges.count, 1)), height: 3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 16) {
                ForEach(shown) { badge in
                    Button {
                        if badge.earned { Haptics.shared.medalTick() } else { Haptics.shared.locked() }
                        selected = badge
                    } label: {
                        BadgeCell(badge: badge)
                    }
                    .buttonStyle(MedalPressStyle())
                }
            }
            if badges.count > Self.collapsed {
                Button {
                    Haptics.shared.tick()
                    withAnimation(.snappy) { showAll.toggle() }
                } label: {
                    Mono(showAll ? "SHOW FEWER" : "SHOW ALL \(badges.count)", size: 10.5, color: Palette.yellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Palette.card, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $selected) { BadgeDetailSheet(badge: $0) }
    }
}

private struct BadgeCell: View {
    let badge: Achievement

    var body: some View {
        let revealed = !badge.secret || badge.earned
        VStack(spacing: 6) {
            Medallion(badge: badge, size: 62)
            if badge.tiered { LevelPips(badge: badge) } else { Color.clear.frame(height: 5) }
            Text(revealed ? badge.title : "Secret")
                .font(TaborFont.grotesk(12, 600))
                .foregroundStyle(badge.earned ? Palette.ink : Palette.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Mono(caption, size: 9, weight: 600, spacing: 0.06, color: badge.earned ? badge.medal.glow : Palette.faint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(revealed ? badge.title : "Secret badge")
        .accessibilityValue(badge.earned ? "Earned, \(badge.medal.rawValue)" : revealed ? "\(badge.progress) of \(badge.goal)" : "Locked")
    }

    private var caption: String {
        if badge.secret && !badge.earned { return "???" }
        if badge.maxed { return badge.tiered ? "MAXED" : "EARNED" }
        return "\(badge.progress)/\(badge.goal)"
    }
}

/// Medals dip and wobble when pressed.
private struct MedalPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -4 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// MARK: - Detail sheet

struct BadgeDetailSheet: View {
    let badge: Achievement
    @State private var angle: Double = 0
    @State private var dragStart: Double?
    @State private var lastFace = 0
    @State private var burst = 0

    private var revealed: Bool { !badge.secret || badge.earned }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.track).frame(width: 36, height: 4).padding(.top, 10)
            // Tiered badges list their levels too, so they scroll inside the same half-height sheet.
            if badge.tiered {
                ScrollView { details.padding(.bottom, 16) }
                    .scrollIndicators(.hidden)
            } else {
                details
                Spacer(minLength: 16)
            }
            if badge.earned {
                Mono("DRAG THE MEDAL TO SPIN IT", size: 9.5, color: Palette.ghost).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.medium])
        .presentationBackground(Palette.bg)
        .task {
            // Earned medals arrive with a flourish: one full turn.
            guard badge.earned else { return }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) { angle = 360 }
            Haptics.shared.badgeUnlocked(medal: badge.medal, secret: false)
        }
    }

    private var kicker: String {
        if badge.earned { return badge.tiered ? "LEVEL \(badge.level) OF \(badge.levels) · \(badge.medal.name)" : "EARNED" }
        return badge.secret ? "SECRET" : "LOCKED"
    }

    private var details: some View {
        VStack(spacing: 0) {
            ZStack {
                if badge.earned {
                    SparkleBurst(color: badge.medal.glow, reach: 0.75).id(burst)
                }
                spinningMedal
            }
            .frame(height: 210)
            .padding(.top, 18)
            .contentShape(Rectangle())
            .gesture(spinGesture)

            Mono(kicker, size: 11, weight: 600, spacing: 0.16, color: badge.earned ? badge.medal.glow : Palette.dim)
                .padding(.top, 6)
            Text(revealed ? badge.title : "Secret badge")
                .font(TaborFont.grotesk(26, 700))
                .em(-0.02, size: 26)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text(revealed ? badge.detail : "Keep catching. This one shows itself the moment you earn it.")
                .font(TaborFont.grotesk(14.5))
                .foregroundStyle(Palette.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 30)

            if revealed && !badge.maxed {
                VStack(spacing: 6) {
                    ProgressBar(fraction: badge.fraction, color: Palette.yellow, height: 6)
                    Mono("\(badge.progress) / \(badge.goal)", size: 11, weight: 600, color: Palette.sub)
                }
                .padding(.top, 18)
                .padding(.horizontal, 40)
            }

            if badge.tiered {
                VStack(spacing: 8) {
                    ForEach(Array(badge.steps.enumerated()), id: \.offset) { i, step in
                        let medal = Achievement.medal(level: i + 1, of: badge.levels)
                        HStack(spacing: 10) {
                            Circle().fill(LinearGradient(colors: medal.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 14, height: 14)
                                .opacity(i < badge.level ? 1 : 0.3)
                            Mono(medal.name, size: 10, weight: 700, color: i < badge.level ? medal.glow : Palette.faint)
                                .frame(width: 70, alignment: .leading)
                            Text(step)
                                .font(TaborFont.grotesk(13))
                                .foregroundStyle(i < badge.level ? Palette.ink : Palette.dim)
                            Spacer()
                            if i < badge.level {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(medal.glow)
                            }
                        }
                    }
                }
                .padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 18)
                .padding(.horizontal, 22)
            }
        }
    }

    /// Front shows the symbol; turned past 90° you see the engraved back.
    private var spinningMedal: some View {
        let edge = badge.earned ? badge.medal.colors.last ?? Palette.track : Palette.track
        return SpinningCoin(angle: angle, size: 170, edge: edge) {
            Medallion(badge: badge, size: 170, showsProgress: true)
        } back: {
            medalBack
        }
    }

    private var medalBack: some View {
        let colors = badge.earned ? badge.medal.colors : Medal.none.colors
        return ZStack {
            Circle().fill(LinearGradient(colors: [colors[0], colors[colors.count - 1]], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(LinearGradient(colors: [colors[colors.count - 1], colors[0]], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(17)
            VStack(spacing: 4) {
                Mono("TABOR", size: 13, weight: 700, spacing: 0.3, color: .black.opacity(0.55))
                Text(revealed ? badge.title.uppercased() : "???")
                    .font(TaborFont.mono(10, 600))
                    .foregroundStyle(.black.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                Mono("WARSZAWA", size: 8, weight: 600, spacing: 0.3, color: .black.opacity(0.4))
            }
        }
        .frame(width: 170, height: 170)
    }

    /// Drag to spin: a click on every quarter turn, then it coasts and settles face up.
    private var spinGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart == nil { dragStart = angle }
                angle = (dragStart ?? 0) + v.translation.width * 1.1
                let face = Int((angle / 90).rounded(.down))
                if face != lastFace {
                    lastFace = face
                    Haptics.shared.medalTick()
                }
            }
            .onEnded { v in
                dragStart = nil
                let coast = angle + (v.predictedEndTranslation.width - v.translation.width) * 1.1
                let settle = (coast / 360).rounded() * 360
                withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) { angle = settle }
                lastFace = Int((settle / 90).rounded(.down))
                if badge.earned, abs(settle - coast) < 400, abs(v.predictedEndTranslation.width) > 300 {
                    burst += 1
                    Haptics.shared.badgeUnlocked(medal: badge.medal, secret: false)
                }
            }
    }
}

// MARK: - Unlock toast

/// Notices newly earned badges and level-ups and plays them one at a time.
@MainActor
@Observable
final class BadgeTracker {
    struct Unlock: Identifiable, Equatable {
        let id = UUID()
        let badge: Achievement
        /// More than a handful at once (an import, a sync): one summary instead of a parade.
        var others = 0
    }

    private(set) var current: Unlock?
    private var queue: [Unlock] = []
    private var showing = false
    private static let key = "badgeLevelsSeen"

    func update(_ badges: [Achievement]) {
        let defaults = UserDefaults.standard
        let now = Dictionary(badges.map { ($0.id, $0.level) }, uniquingKeysWith: max)
        guard let seen = defaults.dictionary(forKey: Self.key) as? [String: Int] else {
            // First launch with badges: what's already earned arrives quietly.
            defaults.set(now, forKey: Self.key)
            return
        }
        let fresh = badges.filter { $0.level > (seen[$0.id] ?? 0) }
        // Remember the best level ever reached, so deleting and re-adding a catch doesn't replay it.
        defaults.set(seen.merging(now, uniquingKeysWith: max), forKey: Self.key)
        guard !fresh.isEmpty else { return }
        let best = fresh.sorted { ($0.secret ? 1 : 0, $0.level) > ($1.secret ? 1 : 0, $1.level) }
        queue += best.count > 3 ? [Unlock(badge: best[0], others: best.count - 1)] : best.map { Unlock(badge: $0) }
        if !showing { Task { await playQueue() } }
    }

    func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { current = nil }
    }

    private func playQueue() async {
        showing = true
        defer { showing = false }
        // Let the sticker land in the book first.
        try? await Task.sleep(for: .milliseconds(1400))
        while !queue.isEmpty {
            let next = queue.removeFirst()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { current = next }
            Haptics.shared.badgeUnlocked(medal: next.badge.medal, secret: next.badge.secret)
            for _ in 0..<40 where current?.id == next.id {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if current?.id == next.id { dismiss() }
            try? await Task.sleep(for: .milliseconds(450))
        }
    }
}

struct BadgeToast: View {
    let unlock: BadgeTracker.Unlock
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var flipped = false
    @State private var drag: CGFloat = 0

    var body: some View {
        let b = unlock.badge
        HStack(spacing: 14) {
            ZStack {
                SparkleBurst(color: b.medal.glow, reach: 0.35)
                Medallion(badge: b, size: 58)
                    .rotation3DEffect(.degrees(flipped ? 0 : 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .scaleEffect(flipped ? 1 : 0.4)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Mono(kicker, size: 10, weight: 700, spacing: 0.14, color: b.medal.glow)
                Text(b.title)
                    .font(TaborFont.grotesk(17, 700))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(unlock.others > 0 ? "and \(unlock.others) more. See them all on your shelf." : b.detail)
                    .font(TaborFont.grotesk(12.5))
                    .foregroundStyle(Palette.sub)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(b.medal.glow.opacity(0.5), lineWidth: 1))
        .shadow(color: b.medal.glow.opacity(0.3), radius: 18, y: 6)
        .padding(.horizontal, 14)
        .offset(y: min(drag, 0))
        .gesture(DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { v in
                if v.translation.height < -30 { onDismiss() } else { withAnimation(.spring) { drag = 0 } }
            })
        .onTapGesture(perform: onTap)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55).delay(0.1)) { flipped = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var kicker: String {
        let b = unlock.badge
        if unlock.others > 0 { return "\(unlock.others + 1) BADGES UNLOCKED" }
        if b.secret { return "SECRET BADGE FOUND" }
        if b.tiered && b.level > 1 { return "LEVEL UP · \(b.medal.name)" }
        return b.tiered ? "BADGE UNLOCKED · \(b.medal.name)" : "BADGE UNLOCKED"
    }
}

/// A coin with real thickness, drawn in one flat projection so everything lines up: the
/// near face squashes as it turns, and the rim (the far face's outline plus the band
/// joining the two) shows on the side turning toward you.
struct SpinningCoin<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let size: CGFloat
    let edge: Color
    @ViewBuilder let front: Front
    @ViewBuilder let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let rad = angle * .pi / 180
        let s = CGFloat(sin(rad)), c = CGFloat(cos(rad))
        let depth = size * 0.07
        let frontX = -0.5 * depth * s
        let squash = max(abs(c), 0.001)
        let rim = CoinRim(width: size * squash, frontX: frontX, farX: c >= 0 ? -frontX : frontX)
        let side = c >= 0 ? 1.0 : -1.0
        ZStack {
            ZStack {
                rim.fill(LinearGradient(colors: [edge.mix(with: .black, by: 0.5), edge.mix(with: .white, by: 0.15),
                                                 edge.mix(with: .black, by: 0.5)],
                                        startPoint: .top, endPoint: .bottom))
                ReedLines().stroke(Color.black.opacity(0.12), lineWidth: 0.6)
            }
            .clipShape(rim)
            Group {
                if c >= 0 { front } else { back }
            }
            // The face dims as it turns away, and a glint slides across it with the turn.
            .overlay {
                ZStack {
                    Circle().fill(Color.black.opacity(0.4 * (1 - squash)))
                    Circle().fill(LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                                 startPoint: UnitPoint(x: 0.5 * side * s - 0.1, y: 0),
                                                 endPoint: UnitPoint(x: 0.5 * side * s + 0.5, y: 1)))
                        .blendMode(.overlay)
                }
            }
            .scaleEffect(x: squash)
            .offset(x: c >= 0 ? frontX : -frontX)
        }
        .frame(width: size + depth, height: size)
    }
}

/// The far face's outline and the band between the two faces, as one shape.
private struct CoinRim: Shape {
    var width: CGFloat
    var frontX: CGFloat
    var farX: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.midX + farX - width / 2, y: r.minY, width: width, height: r.height))
        let left = r.midX + min(frontX, -frontX), right = r.midX + max(frontX, -frontX)
        p.addRect(CGRect(x: left, y: r.minY, width: right - left, height: r.height))
        return p
    }
}

/// Fine horizontal grooves across the rim.
private struct ReedLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var y = r.minY + 1.5
        while y < r.maxY {
            p.move(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
            y += 3
        }
        return p
    }
}
