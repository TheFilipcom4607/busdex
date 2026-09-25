import CoreHaptics
import SwiftUI
import UIKit

/// Hand-designed Core Haptics patterns. Every moment in the app has its own feel;
/// rarer catches get longer, bigger build-ups. Falls back to UIKit generators on
/// hardware without a Taptic Engine that supports Core Haptics.
///
/// Rules these follow (Apple's "Practice audio haptic design", WWDC21):
/// - Crisp transients carry the feel; continuous events only for a visible build-up,
///   never a buzz under a tap (a transient inside a continuous event gets masked).
/// - Nothing below ~0.3 intensity: the Taptic Engine renders it as mush.
/// - Each hit lands on the frame the eye sees the impact, not when the animation starts.
/// - Selection changes click; navigation stays silent, so the big moments stand out.
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Toggled from Me → Settings.
    static let enabledKey = "hapticsEnabled"

    private var engine: CHHapticEngine?
    private var engineRunning = false
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    /// Last ratchet step played by the hold-to-stick gesture.
    private var holdStep = -1

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private init() {
        prepare()
    }

    /// Keeps the engine warm: auto-shutdown adds a noticeable lag to the first tap after
    /// a pause, which makes every haptic feel late. The system stops it in the background;
    /// the next `play` restarts it.
    func prepare() {
        guard supported, engine == nil else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.engineRunning = false
                    self?.startEngine()
                }
            }
            e.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engineRunning = false }
            }
            engine = e
            startEngine()
        } catch {
            engine = nil
        }
    }

    private func startEngine() {
        guard let engine, !engineRunning else { return }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            engineRunning = false
        }
    }

    // MARK: - Moments

    /// Filter chip / mode / toggle: a light detent, like a segmented control.
    func tick() {
        play([tap(0, 0.5, 0.75)], fallback: .selection)
    }

    /// OCR locked a number: one clean click, like a dial settling.
    /// A never-seen vehicle adds a second, brighter click — "new" without looking.
    func numberLocked(isNew: Bool) {
        var events = [tap(0, 0.75, 0.6)]
        if isNew { events.append(tap(0.09, 0.9, 1)) }
        play(events, fallback: .medium)
    }

    /// Shutter: one firm snap and a soft return, like the iPhone camera.
    func shutter() {
        play([tap(0, 1, 0.6), tap(0.075, 0.4, 0.3)], fallback: .heavy)
    }

    /// Reveal: the sticker lands. Common = one clean thunk; rarer = a build-up that
    /// matches the glow, a landing timed to the visual impact, then a sparkle tail.
    func reveal(tier: Tier, isNewModel: Bool) {
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        let build: TimeInterval
        switch tier {
        case .common:
            build = 0.05
        case .rare:
            // A swell that rises with the glow and stops just before the hit.
            build = 0.35
            events.append(hum(0, build - 0.06, intensity: 1, sharpness: 0.25))
            curves.append(curve(.hapticIntensityControl, [(0, 0.3), (build - 0.06, 0.75)]))
        case .gold:
            // A heartbeat that speeds up and gets harder.
            build = 0.62
            for (t, i) in [(0.0, 0.4), (0.2, 0.5), (0.35, 0.6), (0.46, 0.7), (0.54, 0.8)] as [(TimeInterval, Float)] {
                events.append(tap(t, i, 0.3))
            }
        case .vintage:
            // An old tram over rail joints: ta-tam … ta-tam, getting closer.
            build = 0.62
            for (t, i) in [(0.0, 0.4), (0.1, 0.45), (0.4, 0.6), (0.5, 0.7)] as [(TimeInterval, Float)] {
                events.append(tap(t, i, 0.55))
            }
        case .onTest:
            // An electric motor spinning up: one hum that climbs in strength and pitch.
            build = 0.62
            events.append(hum(0, build - 0.06, intensity: 1, sharpness: 0.3))
            curves.append(curve(.hapticIntensityControl, [(0, 0.2), (build - 0.06, 0.8)]))
            curves.append(curve(.hapticSharpnessControl, [(0, -0.3), (build - 0.06, 0.4)]))
        case .legendary:
            // A drumroll: ticks that accelerate and sharpen, over a swell that cuts out
            // right before the drop so nothing masks it.
            build = 1.0
            var t = 0.0, gap = 0.16
            while t < build - 0.08 {
                let p = Float(t / build)
                events.append(tap(t, 0.4 + 0.5 * p, 0.3 + 0.6 * p))
                t += gap
                gap = max(0.045, gap * 0.8)
            }
            events.append(hum(0.55, 0.37, intensity: 1, sharpness: 0.2))
            curves.append(curve(.hapticIntensityControl, [(0.55, 0.3), (0.92, 0.8)]))
        }
        // The landing: the spring overshoots, so a heavy hit plus a smaller bounce.
        let land = build + 0.1
        events.append(tap(land, 1, tier == .common ? 0.5 : 0.35))
        events.append(tap(land + 0.075, 0.45, 0.3))
        // Sparkle: fast, bright, fading clicks. New model or rare+ only.
        if isNewModel || tier != .common {
            let count = tier == .legendary ? 8 : tier == .gold ? 6 : 4
            for k in 0..<count {
                events.append(tap(land + 0.18 + Double(k) * 0.055, max(0.32, 0.7 - Float(k) * 0.06), 1))
            }
        }
        play(events, curves: curves, fallback: tier == .common ? .medium : .success)
    }

    /// Sticking it into the book: a crackle as it peels off the backing (while the
    /// sticker lifts and straightens), then the slap when it lands in the book.
    func stick() {
        var events = [0.0, 0.03, 0.055, 0.085, 0.11, 0.15].enumerated().map { i, t in
            tap(t, [0.45, 0.55, 0.5, 0.6, 0.5, 0.4][i], 0.95)
        }
        events.append(tap(0.52, 1, 0.2))
        events.append(tap(0.58, 0.5, 0.15))
        play(events, fallback: .heavy)
    }

    /// Batch or model completed: three rising clicks, a big hit, then a warm fade.
    func completed() {
        play([
            tap(0, 0.55, 0.4), tap(0.1, 0.7, 0.55), tap(0.2, 0.85, 0.7),
            tap(0.34, 1, 0.5),
            hum(0.4, 0.5, intensity: 0.8, sharpness: 0.25),
        ], curves: [curve(.hapticIntensityControl, [(0.4, 1), (0.9, 0.35)])], fallback: .success)
    }

    /// Badge unlocked: a coin dropped on a table — metallic clinks that speed up and soften
    /// as it settles, then a warm thud as the medal lands in the toast. Better medals ring
    /// on with bright sparkles; a secret badge rumbles in first, like a drumroll.
    func badgeUnlocked(medal: Medal, secret: Bool) {
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        let lead: TimeInterval = secret ? 0.45 : 0
        if secret {
            events.append(hum(0, 0.4, intensity: 0.6, sharpness: 0.2))
            curves.append(curve(.hapticIntensityControl, [(0, 0.3), (0.4, 1)]))
        }
        let clinks: [(TimeInterval, Float)] = [(0, 0.85), (0.13, 0.75), (0.22, 0.65), (0.29, 0.55), (0.34, 0.48), (0.38, 0.42), (0.41, 0.36)]
        events += clinks.map { tap(lead + $0.0, $0.1, 0.95) }
        events.append(tap(lead + 0.5, 1, 0.35))
        let sparkles: Int
        switch medal {
        case .platinum: sparkles = 4
        case .gold: sparkles = 2
        case .silver: sparkles = 1
        default: sparkles = 0
        }
        events += (0..<sparkles).map { tap(lead + 0.66 + Double($0) * 0.09, 0.55 + Float($0) * 0.08, 1) }
        play(events, curves: curves, fallback: .success)
    }

    /// Spinning a medal in the badge sheet: one crisp, metallic click per face.
    func medalTick() {
        play([tap(0, 0.5, 1)], fallback: .selection)
    }

    /// A locked badge tapped: a dull knock, like tapping a display case.
    func locked() {
        play([tap(0, 0.5, 0.1)], fallback: .soft)
    }

    /// Nothing readable / unknown number: a soft, low double-bump. Never harsh.
    func nope() {
        play([tap(0, 0.55, 0.15), tap(0.12, 0.42, 0.15)], fallback: .warning)
    }

    /// A digit typed in the correction sheet.
    func detent() {
        play([tap(0, 0.4, 0.8)], fallback: .selection)
    }

    /// A sticker in the book gets pressed: a soft, round squish.
    func press() {
        play([tap(0, 0.45, 0.15)], fallback: .soft)
    }

    // MARK: - Hold to stick (driven live by the gesture)

    /// Starts the ratchet. A continuous rumble here felt like a phone vibrating; a
    /// row of clicks that speed up, harden and brighten feels like winding something up.
    func beginHold() {
        holdStep = -1
        updateHold(progress: 0)
    }

    func updateHold(progress: Double) {
        let p = max(0, min(progress, 1))
        // Steps get closer together as it fills: 10 clicks, front-loaded spacing.
        let step = Int((p * p * 0.6 + p * 0.4) * 10)
        guard step > holdStep, step < 10 else { return }
        holdStep = step
        let f = Float(p)
        play([tap(0, 0.35 + 0.5 * f, 0.35 + 0.55 * f)], fallback: .selection)
    }

    func endHold() {
        holdStep = -1
    }

    // MARK: - Lab

    /// Every moment, for tuning on a real phone (Me → Settings → Haptics lab).
    var labMoments: [(name: String, play: () -> Void)] {
        [
            ("Tick (chips, toggles)", { self.tick() }),
            ("Number locked", { self.numberLocked(isNew: false) }),
            ("Number locked · new", { self.numberLocked(isNew: true) }),
            ("Shutter", { self.shutter() }),
            ("Reveal · common", { self.reveal(tier: .common, isNewModel: false) }),
            ("Reveal · common, new model", { self.reveal(tier: .common, isNewModel: true) }),
            ("Reveal · rare", { self.reveal(tier: .rare, isNewModel: false) }),
            ("Reveal · gold", { self.reveal(tier: .gold, isNewModel: false) }),
            ("Reveal · legendary", { self.reveal(tier: .legendary, isNewModel: false) }),
            ("Reveal · vintage", { self.reveal(tier: .vintage, isNewModel: false) }),
            ("Reveal · on test", { self.reveal(tier: .onTest, isNewModel: true) }),
            ("Hold to stick (0.55 s)", { self.demoHold() }),
            ("Stick", { self.stick() }),
            ("Completed", { self.completed() }),
            ("Nope", { self.nope() }),
            ("Digit", { self.detent() }),
            ("Sticker press", { self.press() }),
            ("Badge · bronze", { self.badgeUnlocked(medal: .bronze, secret: false) }),
            ("Badge · gold", { self.badgeUnlocked(medal: .gold, secret: false) }),
            ("Badge · platinum", { self.badgeUnlocked(medal: .platinum, secret: false) }),
            ("Badge · secret", { self.badgeUnlocked(medal: .gold, secret: true) }),
            ("Medal spin tick", { self.medalTick() }),
            ("Locked badge", { self.locked() }),
        ]
    }

    private func demoHold() {
        beginHold()
        Task { @MainActor in
            let start = Date()
            while true {
                let p = Date().timeIntervalSince(start) / 0.55
                if p >= 1 { break }
                updateHold(progress: p)
                try? await Task.sleep(for: .milliseconds(16))
            }
            endHold()
        }
    }

    // MARK: - Building blocks

    private func tap(_ t: TimeInterval, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: intensity),
            .init(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: t)
    }

    private func hum(_ t: TimeInterval, _ duration: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: intensity),
            .init(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: t, duration: duration)
    }

    private func curve(_ id: CHHapticDynamicParameter.ID, _ points: [(TimeInterval, Float)]) -> CHHapticParameterCurve {
        CHHapticParameterCurve(parameterID: id,
                               controlPoints: points.map { .init(relativeTime: $0.0, value: $0.1) },
                               relativeTime: 0)
    }

    private enum Fallback { case light, medium, heavy, soft, selection, success, warning }

    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = [], fallback: Fallback) {
        guard enabled else { return }
        guard let engine else { return playFallback(fallback) }
        startEngine()
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // The engine may have been stopped under us (backgrounding); retry once.
            engineRunning = false
            startEngine()
            do {
                let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
                try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            } catch {
                playFallback(fallback)
            }
        }
    }

    private func playFallback(_ f: Fallback) {
        switch f {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
