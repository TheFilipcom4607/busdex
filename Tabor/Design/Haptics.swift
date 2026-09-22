import CoreHaptics
import SwiftUI
import UIKit

/// Hand-designed Core Haptics patterns. Every moment in the app has its own feel;
/// rarer catches get longer, bigger build-ups. Falls back to UIKit generators on
/// hardware without a Taptic Engine that supports Core Haptics.
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Toggled from Me → Settings.
    static let enabledKey = "hapticsEnabled"

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var holdPlayer: CHHapticAdvancedPatternPlayer?

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private init() {
        prepare()
    }

    func prepare() {
        guard supported, engine == nil else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.resetHandler = { [weak self] in
                Task { @MainActor in try? self?.engine?.start() }
            }
            e.stoppedHandler = { _ in }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
    }

    // MARK: - Moments

    /// Tab switch: a crisp, light click.
    func tab() {
        play([tap(0, 0.45, 0.85)], fallback: .light)
    }

    /// Filter chip / sort toggle: a tiny detent.
    func tick() {
        play([tap(0, 0.35, 1.0)], fallback: .selection)
    }

    /// OCR locked a number: two quick clicks, like a dial clicking into place.
    /// A never-seen vehicle adds a short rising shimmer so you can feel "new" without looking.
    func numberLocked(isNew: Bool) {
        var events = [tap(0, 0.5, 0.9), tap(0.055, 0.8, 0.6)]
        if isNew {
            events.append(hum(0.11, 0.18, intensity: 0.25, sharpness: 0.7))
            events += [tap(0.14, 0.3, 1), tap(0.19, 0.4, 1), tap(0.24, 0.5, 1)]
        }
        play(events, fallback: .medium)
    }

    /// Shutter: the sharp snap of the mirror, a short mechanical buzz, then the return.
    func shutter() {
        play([
            tap(0, 1.0, 0.95),
            hum(0.012, 0.07, intensity: 0.45, sharpness: 0.35),
            tap(0.09, 0.55, 0.5),
        ], curves: [curve(.hapticIntensityControl, [(0.012, 1), (0.08, 0.1)])], fallback: .heavy)
    }

    /// Reveal: the sticker lands. Common = a clean thunk, rarer = longer charge-up + sparkle tail.
    func reveal(tier: Tier, isNewModel: Bool) {
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        let build: TimeInterval
        switch tier {
        case .common:
            build = 0
        case .rare:
            build = 0.35
            events.append(hum(0, build, intensity: 1, sharpness: 0.3))
            curves.append(curve(.hapticIntensityControl, [(0, 0.1), (build, 0.7)]))
        case .gold:
            // Heartbeat that speeds up.
            build = 0.62
            for (t, i) in [(0.0, 0.35), (0.22, 0.45), (0.38, 0.55), (0.5, 0.65), (0.58, 0.75)] as [(TimeInterval, Float)] {
                events.append(tap(t, i, 0.25))
            }
            events.append(hum(0.3, 0.32, intensity: 1, sharpness: 0.2))
            curves.append(curve(.hapticIntensityControl, [(0.3, 0.05), (build, 0.6)]))
        case .legendary:
            // A long rumble that swells and sharpens, then the drop.
            build = 1.0
            events.append(hum(0, build, intensity: 1, sharpness: 0.1))
            curves.append(curve(.hapticIntensityControl, [(0, 0.05), (0.6, 0.55), (build, 1)]))
            curves.append(curve(.hapticSharpnessControl, [(0, -0.3), (build, 0.4)]))
            for t in stride(from: 0.55, to: build, by: 0.07) { events.append(tap(t, 0.5, 0.6)) }
        }
        // The landing.
        events.append(tap(build, 1.0, tier == .common ? 0.55 : 0.35))
        events.append(hum(build, 0.09, intensity: 0.7, sharpness: 0.1))
        // Sparkle: fast, bright, fading taps. New model or rare+ only.
        if isNewModel || tier != .common {
            let count = tier == .legendary ? 9 : tier == .gold ? 7 : 5
            for k in 0..<count {
                let t = build + 0.16 + Double(k) * 0.045
                events.append(tap(t, Float(0.55 - Double(k) * 0.05), 1))
            }
        }
        play(events, curves: curves, fallback: tier == .common ? .medium : .success)
    }

    /// Sticking it into the book: the peel (a sharp tearing sweep), a pause, then the
    /// firm slap of the palm, then two soft smoothing strokes.
    func stick() {
        play([
            hum(0, 0.2, intensity: 0.5, sharpness: 1),
            tap(0.27, 1.0, 0.2),
            hum(0.27, 0.06, intensity: 0.8, sharpness: 0),
            hum(0.42, 0.12, intensity: 0.25, sharpness: 0.15),
            hum(0.6, 0.12, intensity: 0.18, sharpness: 0.15),
        ], curves: [
            curve(.hapticSharpnessControl, [(0, 0.4), (0.2, -0.4)]),
            curve(.hapticIntensityControl, [(0, 0.3), (0.12, 1), (0.2, 0.2)]),
        ], fallback: .heavy)
    }

    /// Batch or model completed: three rising taps and a long warm swell.
    func completed() {
        play([
            tap(0, 0.5, 0.4), tap(0.1, 0.7, 0.55), tap(0.2, 0.9, 0.7),
            hum(0.3, 0.6, intensity: 0.9, sharpness: 0.3),
            tap(0.3, 1, 0.5),
        ], curves: [curve(.hapticIntensityControl, [(0.3, 1), (0.9, 0)])], fallback: .success)
    }

    /// Nothing readable / unknown number: a soft, low double-bump. Never harsh.
    func nope() {
        play([tap(0, 0.45, 0.1), tap(0.11, 0.35, 0.1)], fallback: .warning)
    }

    /// A single digit / wheel detent in the correction sheet.
    func detent() {
        play([tap(0, 0.3, 0.7)], fallback: .selection)
    }

    /// A sticker in the book gets pressed: a soft squish.
    func press() {
        play([tap(0, 0.4, 0.3), hum(0, 0.05, intensity: 0.3, sharpness: 0.2)], fallback: .soft)
    }

    // MARK: - Hold to stick (continuous, driven live by the gesture)

    /// Starts a low rumble whose intensity follows `updateHold(progress:)`.
    func beginHold() {
        guard enabled, let engine else { return }
        let pattern = try? CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 1),
                .init(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0, duration: 30),
        ], parameters: [])
        guard let pattern, let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
        holdPlayer = player
        updateHold(progress: 0)
    }

    func updateHold(progress: Double) {
        let p = Float(max(0, min(progress, 1)))
        try? holdPlayer?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.08 + p * p * 0.75, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: -0.2 + p * 0.6, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    func endHold() {
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
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
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            playFallback(fallback)
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
