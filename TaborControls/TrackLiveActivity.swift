import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// HUNT's TRACK on the Lock Screen and in the Dynamic Island: how far the vehicle has to go to
/// your stop, as a flight-tracker style progress bar.
struct TrackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackAttributes.self) { context in
            TrackLockScreen(a: context.attributes, s: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(WidgetPalette.ink)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TrackArt(a: a).frame(width: 58, height: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.model).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        WidgetKey(text: TrackText.subtitle(a, s), size: 9)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.isOver ? TrackText.title(a, s) : s.distanceText)
                                .font(.system(size: s.isOver ? 17 : 28, weight: .bold, design: s.isOver ? .default : .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            WidgetKey(text: TrackText.status(a, s), color: TrackText.color(s), size: 9.5)
                        }
                        Spacer(minLength: 8)
                        if !s.isOver || s.phase == .passed { CatchButton() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
            } compactLeading: {
                WidgetNumberTag(number: a.number, tier: a.tier, size: 11)
            } compactTrailing: {
                Text(s.isOver ? "–" : s.phase == .here ? "HERE" : s.distanceText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(TrackText.color(s))
            } minimal: {
                Circle().fill(WidgetPalette.tier(a.tier)).frame(width: 13, height: 13)
            }
            .widgetURL(a.url)
            .keylineTint(WidgetPalette.tier(a.tier))
        }
    }
}

/// Opens the camera, from the Lock Screen or the Dynamic Island.
private struct CatchButton: View {
    var body: some View {
        Button(intent: OpenCatchIntent()) {
            Text("CATCH")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(WidgetPalette.yellow, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Its sticker when it's in your book, else a dashed outline in its rarity's colour, like an
/// empty slot in the book.
struct TrackArt: View {
    let a: TrackAttributes

    var body: some View {
        if a.image != nil {
            WidgetPicture(image: a.image, cutout: a.cutout, number: a.number, tier: a.tier, tag: 0)
        } else {
            let color = WidgetPalette.tier(a.tier)
            ZStack {
                Image(systemName: a.tram ? "tram" : "bus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(color.opacity(0.9))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
            .overlay(alignment: .topTrailing) {
                Text("?").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color).padding(4)
            }
        }
    }
}

private struct TrackLockScreen: View {
    let a: TrackAttributes
    let s: TrackAttributes.ContentState

    var body: some View {
        if s.isOver {
            HStack(spacing: 12) {
                if s.phase == .caught {
                    TrackArt(a: a).frame(width: 58, height: 40)
                } else {
                    Circle().fill(TrackText.color(s)).frame(width: 10, height: 10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(TrackText.title(a, s)).font(.system(size: 15, weight: .semibold)).foregroundStyle(WidgetPalette.ink)
                    WidgetKey(text: TrackText.status(a, s), color: TrackText.color(s))
                }
                Spacer(minLength: 4)
                if s.phase == .passed { CatchButton() }
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TrackArt(a: a).frame(width: 74, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            WidgetNumberTag(number: a.number, tier: a.tier, size: 11)
                            Text(a.line)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(WidgetPalette.ink, in: RoundedRectangle(cornerRadius: 4))
                            WidgetKey(text: TrackText.kind(a), color: WidgetPalette.tier(a.tier))
                        }
                        Text(a.model).font(.system(size: 16, weight: .medium)).foregroundStyle(WidgetPalette.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(s.phase == .here ? String(localized: "HERE") : s.distanceText)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(WidgetPalette.ink)
                            .contentTransition(.numericText())
                        WidgetKey(text: TrackText.status(a, s), color: TrackText.color(s))
                    }
                }
                if s.phase == .here {
                    HStack {
                        WidgetKey(text: String(localized: "GET THE CAMERA OUT"), color: WidgetPalette.yellow, size: 10)
                        Spacer()
                        CatchButton()
                    }
                } else {
                    TrackProgress(s: s, tier: a.tier, tram: a.tram)
                    HStack {
                        WidgetKey(text: s.at?.uppercased() ?? "")
                        Spacer()
                        WidgetKey(text: s.stops == 1 ? String(localized: "1 STOP") : String(localized: "\(s.stops) STOPS"))
                        Spacer()
                        WidgetKey(text: TrackText.yours(a), color: WidgetPalette.yellow)
                    }
                }
            }
        }
    }
}

/// The vehicle sliding along towards you, with the stops still to come as dots.
private struct TrackProgress: View {
    let s: TrackAttributes.ContentState
    let tier: String
    let tram: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(11, min(w - 30, w * s.progress))
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track).frame(height: 4)
                Capsule().fill(WidgetPalette.green).frame(width: x, height: 4)
                // The stops before yours, spread over what's left.
                ForEach(0..<max(0, min(s.stops - 1, 8)), id: \.self) { i in
                    let step = (w - 8 - x) / Double(max(s.stops, 1))
                    Circle().strokeBorder(WidgetPalette.sub, lineWidth: 2).background(Circle().fill(.black))
                        .frame(width: 8, height: 8)
                        .offset(x: x + step * Double(i + 1) - 4)
                }
                Circle().fill(WidgetPalette.yellow).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(WidgetPalette.yellow.opacity(0.3), lineWidth: 4))
                    .offset(x: w - 14)
                Image(systemName: tram ? "tram.fill" : "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tier == "LEGENDARY" ? WidgetPalette.ink : .black)
                    .frame(width: 22, height: 18)
                    .background(WidgetPalette.tag(tier), in: RoundedRectangle(cornerRadius: 5))
                    .offset(x: x - 11)
            }
            .frame(height: 20)
        }
        .frame(height: 20)
    }
}

/// The words, shared by the Lock Screen and the Dynamic Island.
enum TrackText {
    static func kind(_ a: TrackAttributes) -> String {
        a.caught ? String(localized: "IN YOUR BOOK") : a.newModel ? String(localized: "NEW MODEL") : String(localized: "NEW VEHICLE")
    }

    /// "SYTA · YOU", or just "YOU" between stops.
    static func yours(_ a: TrackAttributes) -> String {
        a.stop.map { String(localized: "\($0.uppercased()) · YOU") } ?? String(localized: "YOU")
    }

    static func status(_ a: TrackAttributes, _ s: TrackAttributes.ContentState) -> String {
        switch s.phase {
        case .coming: String(localized: "COMING")
        case .here: String(localized: "AT YOUR STOP")
        case .passed: String(localized: "GONE PAST")
        case .turnedOff: s.at.map { String(localized: "LEFT THE ROUTE AFTER \($0.uppercased())") } ?? String(localized: "LEFT THE ROUTE")
        case .lost: String(localized: "STOPPED REPORTING WHERE IT IS")
        case .ended: String(localized: "STOPPED TRACKING")
        case .caught: String(localized: "IN YOUR BOOK")
        }
    }

    static func title(_ a: TrackAttributes, _ s: TrackAttributes.ContentState) -> String {
        let n = String(a.number)
        return switch s.phase {
        case .coming, .here: a.model
        case .passed: String(localized: "\(n) went past your stop")
        case .turnedOff: String(localized: "\(n) turned off before you")
        case .lost: String(localized: "Lost \(n)")
        case .ended: String(localized: "Stopped tracking \(n)")
        case .caught: String(localized: "Caught \(n)!")
        }
    }

    /// "#1998 · LINE 164 · NOW AT VOGLA".
    static func subtitle(_ a: TrackAttributes, _ s: TrackAttributes.ContentState) -> String {
        var parts = ["#\(a.number)", String(localized: "LINE \(a.line)")]
        if !s.isOver, let at = s.at { parts.append(String(localized: "NOW AT \(at.uppercased())")) }
        return parts.joined(separator: " · ")
    }

    static func color(_ s: TrackAttributes.ContentState) -> Color {
        switch s.phase {
        case .coming, .caught: WidgetPalette.green
        case .here: WidgetPalette.yellow
        case .passed, .turnedOff, .lost: WidgetPalette.red
        case .ended: WidgetPalette.sub
        }
    }
}
