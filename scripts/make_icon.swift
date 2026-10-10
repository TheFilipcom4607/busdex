// Renders TABOR's app icon: the front of a Warsaw Yutong U12 as a chunky, cute white
// die-cut sticker on the app's dark background — ram-horn mirrors, big round-shouldered
// windscreen, the chrome bar with upturned ends, LED-ringed pill headlights, a green
// electric plate. Tagged 1971.
// Usage: swift scripts/make_icon.swift   (writes the icon, its alternate backgrounds for
// Settings › App icon (#62), and the onboarding sticker into Tabor/Resources/Assets.xcassets)
import AppKit
import CoreText

let S: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("..")
let assets = root.appendingPathComponent("Tabor/Resources/Assets.xcassets")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

enum Variant { case normal, dark, tinted }

/// What the sticker sits on. Only the light icon changes: the dark one is transparent (iOS
/// gives it its own backdrop) and the tinted one is greyscale anyway.
enum Backdrop {
    case black, white, blue

    var fill: CGColor {
        switch self {
        case .black: rgb(0x0B0C0E)
        case .white: rgb(0xF3F1EC)
        case .blue: rgb(0x0B2E6B)
        }
    }

    /// The warm light behind the sticker; on white it would only muddy it, so it's faint there.
    var glow: CGFloat {
        switch self {
        case .black: 0.30
        case .white: 0.22
        case .blue: 0.26
        }
    }

    /// A softer shadow on white, where a black one turns into a smudge.
    var shadow: CGFloat { self == .white ? 0.28 : 0.65 }
}

struct Palette {
    let yellow, red, glass, trim, led, lamp, chrome: CGColor
    init(_ v: Variant) {
        let tinted = v == .tinted
        yellow = tinted ? rgb(0xD8D8D8) : rgb(0xFFCE00)
        red = tinted ? rgb(0x6A6A6A) : rgb(0xE4002B)
        glass = rgb(0x121417)
        trim = rgb(0x1C1E22)
        led = tinted ? rgb(0xFFFFFF) : rgb(0xFF9A1F)
        lamp = tinted ? rgb(0xFFFFFF) : rgb(0xFFF6D6)
        chrome = tinted ? rgb(0xF0F0F0) : rgb(0xDCE1E7)
    }
}

/// Rounded rect with separate top and bottom corner radii.
func body(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + top, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: top)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: bottom)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bottom)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: top)
    p.closeSubpath()
    return p
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func mirrored(_ p: CGPath) -> CGPath {
    var t = CGAffineTransform(translationX: S, y: 0).scaledBy(x: -1, y: 1)
    return p.copy(using: &t)!
}

/// Every piece of the sticker's silhouette, so the white die-cut border can follow it.
struct Shape {
    let bodyRect: CGRect
    let bodyPath: CGPath
    let wheels: [CGRect]
    /// Ram-horn mirror stalks (stroked) and heads (filled), left then right.
    let arms: [CGPath]
    let heads: [CGPath]
    var armWidth: CGFloat = 24
}

/// Which vehicle the sticker shows. The Yutong is the main icon; the others are the tip
/// jar's thank-you icons.
enum Vehicle {
    case yutong, urbino, rotem, konstal

    /// A real fleet number of that model.
    var tag: String {
        switch self {
        case .yutong: "1971"
        case .urbino: "5900"
        case .rotem: "4267"
        case .konstal: "1282"
        }
    }

    var scale: CGFloat { self == .urbino ? 1.1 : 1 }

    func shape() -> Shape {
        switch self {
        case .yutong: yutongShape()
        case .urbino: urbinoShape()
        case .rotem: rotemShape()
        case .konstal: konstalShape()
        }
    }

    func face(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
        switch self {
        case .yutong: yutongFace(ctx, r, c)
        case .urbino: urbinoFace(ctx, r, c)
        case .rotem: rotemFace(ctx, r, c)
        case .konstal: konstalFace(ctx, r, c)
        }
    }
}

func yutongShape() -> Shape {
    let r = CGRect(x: 302, y: 222, width: 420, height: 588)
    let path = body(r, top: 104, bottom: 56)
    // Stalk leaves the roof corner, arcs out, and hangs the mirror beside the windscreen.
    let arm = CGMutablePath()
    arm.move(to: CGPoint(x: r.minX + 30, y: r.minY + 34))
    arm.addCurve(to: CGPoint(x: r.minX - 64, y: r.minY + 70),
                 control1: CGPoint(x: r.minX - 10, y: r.minY - 20),
                 control2: CGPoint(x: r.minX - 64, y: r.minY + 6))
    arm.addLine(to: CGPoint(x: r.minX - 64, y: r.minY + 120))
    let head = rounded(CGRect(x: r.minX - 92, y: r.minY + 104, width: 56, height: 128), 26)
    return Shape(bodyRect: r, bodyPath: path,
                 wheels: [CGRect(x: r.minX + 26, y: r.maxY - 44, width: 100, height: 94),
                          CGRect(x: r.maxX - 126, y: r.maxY - 44, width: 100, height: 94)],
                 arms: [arm, mirrored(arm)], heads: [head, mirrored(head)])
}

func render(_ variant: Variant, on backdrop: Backdrop = .black, vehicle: Vehicle = .yutong) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to top-left origin so the geometry reads like the screen.
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

    // Background: near-black with a warm glow behind the sticker.
    if variant != .dark {
        let backdrop = variant == .tinted ? .black : backdrop
        ctx.setFillColor(backdrop.fill); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFCE00, backdrop.glow), rgb(0xFFCE00, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 470), endRadius: 520, options: [])
    }

    // Keep the sticker inside the icon's safe area, tilted like it was slapped on.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.9, y: 0.9)
    ctx.translateBy(x: -512, y: -530)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 520)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.translateBy(x: -512, y: -520)
    // The squarer Urbino would look small next to the Yutong at the same scale.
    ctx.translateBy(x: 512, y: 540); ctx.scaleBy(x: vehicle.scale, y: vehicle.scale); ctx.translateBy(x: -512, y: -540)

    let sh = vehicle.shape()
    let c = Palette(variant)

    // 1. Die-cut white border + shadow: every shape, fattened.
    let border: CGFloat = 60
    ctx.saveGState()
    let shadow = variant == .normal ? backdrop.shadow : 0.65
    ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: rgb(0x000000, shadow))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    for p in [sh.bodyPath] + sh.heads + sh.wheels.map({ rounded($0, 26) }) {
        ctx.addPath(p); ctx.setLineWidth(border * 2); ctx.drawPath(using: .fillStroke)
    }
    for a in sh.arms { ctx.addPath(a); ctx.setLineWidth(sh.armWidth + border * 2); ctx.strokePath() }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 2. Mirrors and tyres, under the body.
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(c.trim)
    for a in sh.arms { ctx.addPath(a); ctx.setLineWidth(sh.armWidth); ctx.strokePath() }
    ctx.setFillColor(c.trim)
    for h in sh.heads { ctx.addPath(h); ctx.fillPath() }
    for w in sh.wheels { ctx.addPath(rounded(w, 26)); ctx.fillPath() }
    // A glint on each mirror.
    ctx.setFillColor(rgb(0xFFFFFF, 0.18))
    for h in sh.heads {
        let b = h.boundingBox
        ctx.addPath(rounded(CGRect(x: b.minX + 12, y: b.minY + 14, width: 12, height: b.height - 50), 6)); ctx.fillPath()
    }

    // 3. The face.
    ctx.saveGState()
    ctx.addPath(sh.bodyPath); ctx.clip()
    vehicle.face(ctx, sh.bodyRect, c)
    ctx.restoreGState()

    ctx.restoreGState()

    // 4. The little white number tag, stuck over the corner like a second sticker.
    numberTag(ctx, vehicle.tag)
    return ctx.makeImage()!
}

/// Windscreen with the amber destination display along its top and a glassy sheen.
func windscreen(_ ctx: CGContext, _ glass: CGPath, display: CGRect, _ c: Palette) {
    ctx.setFillColor(c.glass); ctx.addPath(glass); ctx.fillPath()
    // LED "route": a chunky line number, then the destination as bars.
    ctx.setFillColor(c.led)
    let y = display.midY - 15
    var x = display.minX + 22
    // Narrower than the buses' (the tram's display is a box in the glass): shrink to fit.
    let k = min(1, (display.width - 44) / 304)
    for w in [52.0, 120.0, 92.0] as [CGFloat] {
        ctx.addPath(rounded(CGRect(x: x, y: y, width: w * k, height: 30), 9)); ctx.fillPath()
        x += (w + (w == 52 ? 24 : 16)) * k
    }
    ctx.saveGState()
    ctx.addPath(glass); ctx.clip()
    let b = glass.boundingBox
    ctx.setFillColor(rgb(0x2A2E34)); ctx.fill(CGRect(x: b.minX, y: display.maxY, width: b.width, height: 6))
    let top = display.maxY + 6
    for (x0, w, a) in [(b.minX + 150, 80.0, 0.12), (b.minX + 256, 26.0, 0.08)] as [(CGFloat, CGFloat, CGFloat)] {
        let s = CGMutablePath()
        s.move(to: CGPoint(x: x0, y: top)); s.addLine(to: CGPoint(x: x0 + w, y: top))
        s.addLine(to: CGPoint(x: x0 + w - 110, y: b.maxY)); s.addLine(to: CGPoint(x: x0 - 110, y: b.maxY)); s.closeSubpath()
        ctx.setFillColor(rgb(0xFFFFFF, a)); ctx.addPath(s); ctx.fillPath()
    }
    ctx.restoreGState()
}

/// Polish plate; electric vehicles get the light green one.
func plate(_ ctx: CGContext, center: CGPoint, electric: Bool) {
    let r = CGRect(x: center.x - 62, y: center.y - 17, width: 124, height: 34)
    ctx.setFillColor(electric ? rgb(0xB9EFC4) : rgb(0xFFFFFF)); ctx.addPath(rounded(r, 7)); ctx.fillPath()
    ctx.setFillColor(rgb(0x2B59C3)); ctx.fill(CGRect(x: r.minX + 4, y: r.minY + 4, width: 14, height: r.height - 8))
}

func yutongFace(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
    ctx.setFillColor(c.yellow); ctx.fill(r)
    let skirt = r.minY + 440
    ctx.setFillColor(c.red); ctx.fill(CGRect(x: r.minX, y: skirt, width: r.width, height: r.maxY - skirt))
    // Big round-shouldered windscreen, destination display inside the glass.
    let glassRect = CGRect(x: r.minX + 26, y: r.minY + 28, width: r.width - 52, height: 326)
    let glass = body(glassRect, top: 82, bottom: 22)
    windscreen(ctx, glass, display: CGRect(x: r.minX + 26, y: r.minY + 44, width: r.width - 52, height: 64), c)
    // Two long wipers lying almost flat along the bottom of the glass.
    ctx.setStrokeColor(rgb(0x5A616B)); ctx.setLineWidth(10); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: glassRect.minX + 34, y: glassRect.maxY - 22))
    ctx.addLine(to: CGPoint(x: r.midX + 20, y: glassRect.maxY - 40)); ctx.strokePath()
    ctx.move(to: CGPoint(x: r.midX + 4, y: glassRect.maxY - 52))
    ctx.addLine(to: CGPoint(x: glassRect.maxX - 40, y: glassRect.maxY - 22)); ctx.strokePath()
    // The chrome bar: straight, with upturned ends — the Yutong's smile.
    let bar = CGMutablePath()
    bar.move(to: CGPoint(x: r.minX + 100, y: r.minY + 384))
    bar.addLine(to: CGPoint(x: r.minX + 124, y: r.minY + 404))
    bar.addLine(to: CGPoint(x: r.maxX - 124, y: r.minY + 404))
    bar.addLine(to: CGPoint(x: r.maxX - 100, y: r.minY + 384))
    ctx.setStrokeColor(c.chrome); ctx.setLineWidth(12); ctx.setLineJoin(.round)
    ctx.addPath(bar); ctx.strokePath()
    // Tall pill headlights: two round lamps in a dark pod, ringed by a white LED light.
    for x in [r.minX + 26, r.maxX - 90] {
        let pill = CGRect(x: x, y: r.minY + 372, width: 64, height: 132)
        ctx.setFillColor(c.trim); ctx.addPath(rounded(pill, 32)); ctx.fillPath()
        ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(8)
        ctx.addPath(rounded(pill.insetBy(dx: 4, dy: 4), 28)); ctx.strokePath()
        ctx.setFillColor(c.lamp)
        for cy in [pill.minY + 40, pill.maxY - 40] {
            ctx.fillEllipse(in: CGRect(x: pill.midX - 17, y: cy - 17, width: 34, height: 34))
        }
    }
    plate(ctx, center: CGPoint(x: r.midX, y: r.minY + 504), electric: true)
}

/// The 4th-generation Solaris Urbino in Warsaw colours: a tall, nearly square black face
/// under a thin yellow roof edge, a yellow bumper band with the chrome oval badge, and a red
/// skirt that wraps up around black light pods in the lower corners. Rabbit-ear mirrors.
func urbinoShape() -> Shape {
    // Nearly square, roof to bumper, like the real front. Every edge below was measured off a
    // photo of a Warsaw Urbino 18 electric, scaled to this width.
    let r = CGRect(x: 286, y: 270, width: 452, height: 500)
    let path = body(r, top: 34, bottom: 30)
    // Rabbit ears: a short stalk off each roof corner and a tall paddle hanging from it.
    func ear(drop: CGFloat) -> (arm: CGPath, head: CGPath) {
        let arm = CGMutablePath()
        arm.move(to: CGPoint(x: r.minX + 18, y: r.minY + 10))
        arm.addCurve(to: CGPoint(x: r.minX - 48, y: r.minY + 20 + drop),
                     control1: CGPoint(x: r.minX - 10, y: r.minY - 8),
                     control2: CGPoint(x: r.minX - 48, y: r.minY - 4 + drop))
        return (arm, rounded(CGRect(x: r.minX - 74, y: r.minY + 10 + drop, width: 50, height: 132), 20))
    }
    let left = ear(drop: 0), right = ear(drop: 0)
    return Shape(bodyRect: r, bodyPath: path,
                 wheels: [CGRect(x: r.minX + 28, y: r.maxY - 44, width: 100, height: 94),
                          CGRect(x: r.maxX - 128, y: r.maxY - 44, width: 100, height: 94)],
                 arms: [left.arm, mirrored(right.arm)], heads: [left.head, mirrored(right.head)])
}

func urbinoFace(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x, y: r.minY + y) }
    func poly(_ points: [CGPoint], _ color: CGColor) {
        let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath()
        ctx.setFillColor(color); ctx.addPath(p); ctx.fillPath()
    }
    let w = r.width
    // Black edge to edge: the windscreen's frame is the whole front, unlike the Yutong's.
    ctx.setFillColor(c.trim); ctx.fill(r)
    // A thin yellow roof cap.
    ctx.setFillColor(c.yellow); ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: 13))
    // Display and windscreen: one black sheet, with a lip of the frame below it.
    let glass = CGMutablePath()
    glass.addLines(between: [pt(14, 24), pt(w - 14, 24), pt(w - 14, 326), pt(14, 356)]); glass.closeSubpath()
    windscreen(ctx, glass, display: CGRect(x: r.minX + 14, y: r.minY + 24, width: w - 28, height: 54), c)
    // The bumper band. Its top edge runs gently downhill across the front (the glass is
    // deeper on the door side). At each corner its bottom edge is cut back on one straight
    // diagonal, steepening just before it meets the band's bottom.
    poly([pt(0, 372), pt(w, 342), pt(w, 404), pt(w - 93, 427), pt(w - 102, 433),
          pt(102, 433), pt(93, 427), pt(0, 404)], c.yellow)
    // Red: a wide, shallow centre panel with a blank plate recess. Its sides slant out of
    // the way of the slatted wedges.
    poly([pt(102, 433), pt(w - 102, 433), pt(w - 130, 478), pt(130, 478)], c.red)
    ctx.setFillColor(rgb(0x000000, 0.12))
    ctx.addPath(rounded(CGRect(x: r.midX - 62, y: r.minY + 446, width: 124, height: 26), 5)); ctx.fillPath()
    for side in [false, true] {
        func x(_ d: CGFloat) -> CGFloat { side ? w - d : d }
        // Grey slats in the wedge between the corner frame and the centre panel.
        ctx.setStrokeColor(rgb(0x3A3E45)); ctx.setLineWidth(3)
        for y in stride(from: CGFloat(452), through: 472, by: 7) {
            let t = (y - 433) / 45
            ctx.move(to: pt(x(93 + t * 14), y)); ctx.addLine(to: pt(x(104 + t * 26), y)); ctx.strokePath()
        }
        // The corner frame: a red ring (slanted top bar, outer side, bottom bar) round a black
        // recess with the fog lamp in it.
        poly([pt(x(0), 428), pt(x(89), 448), pt(x(106), 478), pt(x(0), 478)], c.red)
        poly([pt(x(22), 441), pt(x(80), 453), pt(x(90), 466), pt(x(22), 466)], c.trim)
        ctx.setFillColor(rgb(0x2A2E34))
        ctx.fillEllipse(in: CGRect(x: r.minX + x(44) - 6, y: r.minY + 456 - 6, width: 12, height: 12))
        // In the slanted strip between band and frame: the LED ring lamp, nearly as tall as
        // the strip, and a smaller round lamp inboard.
        let big = pt(x(28), 423)
        ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: big.x - 9, y: big.y - 9, width: 18, height: 18))
        ctx.setFillColor(c.lamp)
        ctx.fillEllipse(in: CGRect(x: big.x - 4, y: big.y - 4, width: 8, height: 8))
        let small = pt(x(62), 430)
        ctx.setFillColor(rgb(0xB8BEC6))
        ctx.fillEllipse(in: CGRect(x: small.x - 7, y: small.y - 7, width: 14, height: 14))
    }
    // The chrome oval badge in the middle of the band, with the S swept across it.
    let badge = CGRect(x: r.midX - 40, y: r.minY + 378, width: 80, height: 40)
    ctx.setFillColor(c.chrome); ctx.fillEllipse(in: badge)
    ctx.setStrokeColor(rgb(0x8A929C)); ctx.setLineWidth(4)
    ctx.strokeEllipse(in: badge.insetBy(dx: 5, dy: 5))
    let sweep = CGMutablePath()
    sweep.move(to: CGPoint(x: badge.minX + 15, y: badge.maxY - 13))
    sweep.addCurve(to: CGPoint(x: badge.maxX - 15, y: badge.minY + 13),
                   control1: CGPoint(x: badge.midX, y: badge.maxY - 10),
                   control2: CGPoint(x: badge.midX, y: badge.minY + 10))
    ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.addPath(sweep); ctx.strokePath()
}

/// The Hyundai Rotem 140N, Warsaw's newest tram: a tall front (straight-sided here; the real
/// one flares out to the bottom, which looked odd as a sticker), red
/// roof cap, a yellow frame round a big rounded windscreen, a yellow brow carrying the fleet
/// number with black headlight wedges cut into its corners, and a black smile across the
/// bumper. Measured off a head-on photo of #4107 (a 141N, same front).
func rotemShape() -> Shape {
    let r = CGRect(x: 312, y: 226, width: 400, height: 593)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x, y: r.minY + y) }
    let p = CGMutablePath()
    p.move(to: pt(9, 573)); p.addLine(to: pt(9, 104))
    p.addQuadCurve(to: pt(108, 0), control: pt(13, 6))
    p.addLine(to: pt(292, 0)); p.addQuadCurve(to: pt(391, 104), control: pt(387, 6))
    p.addLine(to: pt(391, 573)); p.addQuadCurve(to: pt(371, 593), control: pt(391, 593))
    p.addLine(to: pt(29, 593)); p.addQuadCurve(to: pt(9, 573), control: pt(9, 593))
    p.closeSubpath()
    // Mirrors on short stalks off the top corners. (A pantograph on the roof just read as a
    // squiggle at icon size.)
    let arm = CGMutablePath()
    arm.move(to: pt(26, 56))
    arm.addCurve(to: pt(-40, 82), control1: pt(0, 40), control2: pt(-40, 50))
    let head = rounded(CGRect(x: r.minX - 62, y: r.minY + 74, width: 44, height: 104), 16)
    var shape = Shape(bodyRect: r, bodyPath: p, wheels: [],
                      arms: [arm, mirrored(arm)], heads: [head, mirrored(head)])
    shape.armWidth = 18
    return shape
}

func rotemFace(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x, y: r.minY + y) }
    func poly(_ points: [CGPoint], _ color: CGColor) {
        let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath()
        ctx.setFillColor(color); ctx.addPath(p); ctx.fillPath()
    }
    let w = r.width
    // Red roof cap: the yellow sits inside it, so the red thins away down the shoulders.
    ctx.setFillColor(c.red); ctx.fill(r)
    let yellow = CGMutablePath()
    // Out past the sides below the shoulders, so no red fringe shows along the edges.
    yellow.move(to: pt(-10, 600)); yellow.addLine(to: pt(-10, 140)); yellow.addLine(to: pt(9, 128))
    yellow.addQuadCurve(to: pt(112, 30), control: pt(15, 34))
    yellow.addLine(to: pt(288, 30)); yellow.addQuadCurve(to: pt(391, 128), control: pt(385, 34))
    yellow.addLine(to: pt(410, 140)); yellow.addLine(to: pt(410, 600)); yellow.closeSubpath()
    ctx.setFillColor(c.yellow); ctx.addPath(yellow); ctx.fillPath()
    // The black: windscreen down to the brow, headlight wedges below it.
    let black = CGMutablePath()
    black.move(to: pt(30, 470)); black.addLine(to: pt(30, 108))
    black.addQuadCurve(to: pt(98, 46), control: pt(32, 48))
    black.addLine(to: pt(302, 46)); black.addQuadCurve(to: pt(370, 108), control: pt(368, 48))
    black.addLine(to: pt(370, 470)); black.closeSubpath()
    ctx.setFillColor(c.trim); ctx.addPath(black); ctx.fillPath()
    let glass = CGMutablePath()
    glass.move(to: pt(33, 384)); glass.addLine(to: pt(33, 110))
    glass.addQuadCurve(to: pt(100, 50), control: pt(35, 52))
    glass.addLine(to: pt(300, 50)); glass.addQuadCurve(to: pt(367, 110), control: pt(365, 52))
    glass.addLine(to: pt(367, 384)); glass.closeSubpath()
    windscreen(ctx, glass, display: CGRect(x: r.minX + 89, y: r.minY + 74, width: 229, height: 44), c)
    // The brow: thin arms over the headlights, deep in the middle, its top edge sagging.
    let brow = CGMutablePath()
    brow.move(to: pt(30, 400)); brow.addQuadCurve(to: pt(370, 400), control: pt(200, 448))
    // addLine, not addLines(between:): that starts a new subpath, and the two overlapping
    // pieces left seams across the front.
    for p in [pt(370, 428), pt(268, 467), pt(132, 467), pt(30, 428)] { brow.addLine(to: p) }
    brow.closeSubpath()
    ctx.setFillColor(c.yellow); ctx.addPath(brow); ctx.fillPath()
    for side in [false, true] {
        func x(_ d: CGFloat) -> CGFloat { side ? w - d : d }
        // A slit of daytime light at the brow's top corner.
        ctx.setStrokeColor(c.lamp); ctx.setLineWidth(4); ctx.setLineCap(.round)
        ctx.move(to: pt(x(34), 391)); ctx.addLine(to: pt(x(54), 397)); ctx.strokePath()
        // In the wedge: the red-ringed lamp at the corner.
        let red = pt(x(48), 446)
        ctx.setFillColor(rgb(0xD8283A)); ctx.fillEllipse(in: CGRect(x: red.x - 10, y: red.y - 10, width: 20, height: 20))
        ctx.setFillColor(c.lamp); ctx.fillEllipse(in: CGRect(x: red.x - 4, y: red.y - 4, width: 8, height: 8))
    }
    // The smile: a black band across the bumper that curls up into a lamp pocket each side.
    let smile = CGMutablePath()
    smile.move(to: pt(39, 504))
    for p in [pt(91, 504), pt(91, 543), pt(309, 543), pt(309, 504), pt(361, 504)] { smile.addLine(to: p) }
    smile.addQuadCurve(to: pt(310, 569), control: pt(355, 560))
    smile.addLine(to: pt(90, 569)); smile.addQuadCurve(to: pt(39, 504), control: pt(45, 560))
    smile.closeSubpath()
    ctx.setFillColor(c.trim); ctx.addPath(smile); ctx.fillPath()
    for side in [false, true] {
        func x(_ d: CGFloat) -> CGFloat { side ? w - d : d }
        let white = pt(x(70), 532)
        ctx.setFillColor(c.lamp); ctx.fillEllipse(in: CGRect(x: white.x - 11, y: white.y - 11, width: 22, height: 22))
    }
}

/// The Konstal 105Na ("akwarium"), proportions from Tramwaje Warszawskie's head-on drawing,
/// simplified for the icon: a grey roof edge with the route box on top, one dark glass band
/// across the front (a big windscreen with a sun strip, a narrow pane each side), two square
/// headlights close together in the middle, red corners round a big black bumper.
func konstalShape() -> Shape {
    let r = CGRect(x: 312, y: 290, width: 400, height: 500)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x, y: r.minY + y) }
    // The body and the route box on its roof, as one silhouette.
    let p = CGMutablePath()
    p.addPath(body(r, top: 40, bottom: 20))
    p.addPath(rounded(CGRect(x: r.minX + 110, y: r.minY - 40, width: 180, height: 52), 12))
    // Mirror stalks off the top corners, like the others.
    let arm = CGMutablePath()
    arm.move(to: pt(24, 50))
    arm.addCurve(to: pt(-40, 76), control1: pt(0, 34), control2: pt(-40, 44))
    let head = rounded(CGRect(x: r.minX - 62, y: r.minY + 68, width: 44, height: 104), 16)
    var shape = Shape(bodyRect: r, bodyPath: p, wheels: [], arms: [arm, mirrored(arm)], heads: [head, mirrored(head)])
    shape.armWidth = 18
    return shape
}

func konstalFace(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: r.minX + x, y: r.minY + y, width: w, height: h)
    }
    let w = r.width
    ctx.setFillColor(c.yellow); ctx.fill(rect(-20, -60, w + 40, 600))
    // The route box's display, and the grey roof edge.
    ctx.setFillColor(c.trim); ctx.addPath(rounded(rect(126, -28, 148, 30), 7)); ctx.fillPath()
    ctx.setFillColor(c.led)
    for (x, bw) in [(140.0, 28.0), (178.0, 52.0), (240.0, 22.0)] as [(CGFloat, CGFloat)] {
        ctx.addPath(rounded(rect(x, -20, bw, 14), 5)); ctx.fillPath()
    }
    ctx.setFillColor(rgb(0xC9CDD3)); ctx.fill(rect(-20, 12, w + 40, 20))
    // One dark band of glass across the front: a narrow pane each side, the big windscreen
    // in the middle with its sun strip.
    ctx.setFillColor(c.trim); ctx.fill(rect(0, 32, w, 250))
    for pane in [rect(16, 44, 64, 226), rect(96, 44, 208, 226), rect(320, 44, 64, 226)] {
        let path = rounded(pane, 8)
        ctx.setFillColor(c.glass); ctx.addPath(path); ctx.fillPath()
    }
    ctx.setFillColor(rgb(0x050607)); ctx.addPath(rounded(rect(96, 44, 208, 40), 8)); ctx.fillPath()
    ctx.saveGState(); ctx.addPath(rounded(rect(96, 84, 208, 186), 8)); ctx.clip()
    let sheen = CGMutablePath()
    sheen.addLines(between: [CGPoint(x: r.minX + 214, y: r.minY + 84), CGPoint(x: r.minX + 260, y: r.minY + 84),
                             CGPoint(x: r.minX + 176, y: r.minY + 270), CGPoint(x: r.minX + 130, y: r.minY + 270)])
    sheen.closeSubpath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.addPath(sheen); ctx.fillPath()
    ctx.restoreGState()
    // Two square headlights close together in the middle, an orange indicator over each.
    for x in [w / 2 - 70, w / 2 + 70] {
        ctx.setFillColor(c.trim); ctx.addPath(rounded(rect(x - 26, 340, 52, 46), 12)); ctx.fillPath()
        ctx.setFillColor(c.lamp); ctx.fillEllipse(in: rect(x - 15, 348, 30, 30))
        ctx.setFillColor(c.led); ctx.addPath(rounded(rect(x - 18, 314, 36, 12), 5)); ctx.fillPath()
    }
    // Red corners at the base, the big black bumper between them.
    ctx.setFillColor(c.red); ctx.fill(rect(0, 428, w, 72))
    ctx.setFillColor(c.trim); ctx.addPath(rounded(rect(64, 406, w - 128, 94), 14)); ctx.fillPath()
}

func numberTag(_ ctx: CGContext, _ text: String) {
    ctx.saveGState()
    ctx.translateBy(x: 700, y: 822)
    ctx.rotate(by: 5 * .pi / 180)
    let tag = CGRect(x: -118, y: -52, width: 236, height: 104)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: rgb(0x000000, 0.5))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.addPath(rounded(tag, 26)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // A real fleet number in the app's mono face.
    let font = CTFontCreateWithName("IBMPlexMono-Bold" as CFString, 74, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: rgb(0x0B0C0E))!,
    ]))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.scaleBy(x: 1, y: -1) // text draws bottom-up
    ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func write(_ img: CGImage, _ path: URL, size: Int? = nil, opaque: Bool = false) {
    var img = img
    // App Store Connect rejects a main icon with an alpha channel, even a fully opaque one.
    if opaque {
        let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        img = c.makeImage()!
    }
    if let size {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        img = c.makeImage()!
    }
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: path)
}

func iconSet(_ name: String, on backdrop: Backdrop = .black, vehicle: Vehicle = .yutong) {
    let dir = assets.appendingPathComponent("\(name).appiconset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let light = render(.normal, on: backdrop, vehicle: vehicle)
    write(light, dir.appendingPathComponent("\(name).png"), opaque: true)
    // The dark icon is meant to be transparent: iOS puts it on its own dark backdrop.
    write(render(.dark, vehicle: vehicle), dir.appendingPathComponent("\(name)-Dark.png"))
    write(render(.tinted, vehicle: vehicle), dir.appendingPathComponent("\(name)-Tinted.png"), opaque: true)
    try! iconContents(name).write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    // Alternate icons can't be loaded as images, so Settings shows a small copy of each.
    imageSet("\(name)-Preview", light, size: 180)
}

func iconContents(_ name: String) -> String {
    """
    {
      "images" : [
        { "filename" : "\(name).png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "filename" : "\(name)-Dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
          "filename" : "\(name)-Tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
}

CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Tabor/Resources/Fonts/IBMPlexMono-Bold.ttf") as CFURL, .process, nil)

/// The same sticker on a transparent background, for the first onboarding page.
func imageSet(_ name: String, _ img: CGImage, size: Int? = nil) {
    let dir = assets.appendingPathComponent("\(name).imageset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    write(img, dir.appendingPathComponent("\(name).png"), size: size)
    let contents = #"{"images":[{"filename":"\#(name).png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
    try! contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

// --preview <dir>: draws every vehicle there, leaving the asset catalog alone.
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    for (name, v) in [("yutong", Vehicle.yutong), ("urbino", .urbino), ("rotem", .rotem), ("konstal", .konstal)] {
        write(render(.normal, vehicle: v), dir.appendingPathComponent("\(name).png"), size: 512)
        write(render(.dark, vehicle: v), dir.appendingPathComponent("\(name)-dark.png"), size: 512)
        write(render(.tinted, vehicle: v), dir.appendingPathComponent("\(name)-tinted.png"), size: 512)
    }
    print("wrote previews to \(dir.path)")
    exit(0)
}

iconSet("AppIcon")
iconSet("AppIcon-White", on: .white)
iconSet("AppIcon-Blue", on: .blue)
// The tip jar's thank-you icons.
iconSet("AppIcon-Urbino", vehicle: .urbino)
iconSet("AppIcon-Rotem", vehicle: .rotem)
iconSet("AppIcon-Konstal", vehicle: .konstal)
imageSet("WelcomeSticker", render(.dark))
print("wrote icons to \(assets.path)")
