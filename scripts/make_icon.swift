// Renders TABOR's app icon: the front of a Warsaw Yutong U12 as a chunky, cute white
// die-cut sticker on the app's dark background — ram-horn mirrors, big round-shouldered
// windscreen, the chrome bar with upturned ends, LED-ringed pill headlights, a green
// electric plate. Tagged 1971.
// Usage: swift scripts/make_icon.swift   (writes the icon, and the onboarding sticker, into
// Tabor/Resources/Assets.xcassets)
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
    let armWidth: CGFloat = 24
}

func shape() -> Shape {
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

func render(_ variant: Variant) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to top-left origin so the geometry reads like the screen.
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

    // Background: near-black with a warm glow behind the sticker.
    if variant != .dark {
        ctx.setFillColor(rgb(0x0B0C0E)); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFCE00, 0.30), rgb(0xFFCE00, 0)] as CFArray, locations: [0, 1])!
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

    let sh = shape()
    let c = Palette(variant)

    // 1. Die-cut white border + shadow: every shape, fattened.
    let border: CGFloat = 60
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: rgb(0x000000, 0.65))
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
    yutong(ctx, sh.bodyRect, c)
    ctx.restoreGState()

    ctx.restoreGState()

    // 4. The little white number tag, stuck over the corner like a second sticker.
    numberTag(ctx, "1971")
    return ctx.makeImage()!
}

/// Windscreen with the amber destination display along its top and a glassy sheen.
func windscreen(_ ctx: CGContext, _ glass: CGPath, display: CGRect, _ c: Palette) {
    ctx.setFillColor(c.glass); ctx.addPath(glass); ctx.fillPath()
    // LED "route": a chunky line number, then the destination as bars.
    ctx.setFillColor(c.led)
    let y = display.midY - 15
    var x = display.minX + 22
    for w in [52.0, 120.0, 92.0] as [CGFloat] {
        ctx.addPath(rounded(CGRect(x: x, y: y, width: w, height: 30), 9)); ctx.fillPath()
        x += w + (w == 52 ? 24 : 16)
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

func yutong(_ ctx: CGContext, _ r: CGRect, _ c: Palette) {
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

func write(_ img: CGImage, _ path: URL, size: Int? = nil) {
    var img = img
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

func iconSet(_ name: String) {
    let dir = assets.appendingPathComponent("\(name).appiconset")
    write(render(.normal), dir.appendingPathComponent("\(name).png"))
    write(render(.dark), dir.appendingPathComponent("\(name)-Dark.png"))
    write(render(.tinted), dir.appendingPathComponent("\(name)-Tinted.png"))
}

CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Tabor/Resources/Fonts/IBMPlexMono-Bold.ttf") as CFURL, .process, nil)

/// The same sticker on a transparent background, for the first onboarding page.
func imageSet(_ name: String, _ img: CGImage) {
    let dir = assets.appendingPathComponent("\(name).imageset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    write(img, dir.appendingPathComponent("\(name).png"))
    let contents = #"{"images":[{"filename":"\#(name).png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
    try! contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

iconSet("AppIcon")
imageSet("WelcomeSticker", render(.dark))
print("wrote icons to \(assets.path)")
