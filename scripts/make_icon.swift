// Renders TABOR's app icon: the front of a Warsaw bus as a white die-cut sticker
// on the app's dark background. Usage: swift scripts/make_icon.swift <out-dir>
import AppKit
import CoreText

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

enum Variant { case normal, dark, tinted }

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

    // Keep the sticker inside the icon's safe area.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.95, y: 0.95)
    ctx.translateBy(x: -512, y: -540)

    ctx.saveGState()
    ctx.translateBy(x: 512, y: 520)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.translateBy(x: -512, y: -520)

    // --- Bus front geometry (top-left origin) ---
    let body = CGRect(x: 262, y: 214, width: 500, height: 600)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 86, cornerHeight: 86, transform: nil)
    // Tyres peeking out under the body.
    let wheels = [CGRect(x: 300, y: 770, width: 104, height: 96), CGRect(x: 620, y: 770, width: 104, height: 96)]

    // 1. Die-cut white border + shadow: every shape, fattened.
    let border: CGFloat = 64
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: rgb(0x000000, 0.65))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(variant == .tinted ? rgb(0xFFFFFF) : rgb(0xFFFFFF))
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.addPath(bodyPath); ctx.setLineWidth(border * 2); ctx.drawPath(using: .fillStroke)
    for r in wheels {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setLineWidth(border * 2); ctx.drawPath(using: .fillStroke)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Palette per variant (tinted icons are rendered in greyscale by the system).
    let yellow = variant == .tinted ? rgb(0xD8D8D8) : rgb(0xFFCE00)
    let red = variant == .tinted ? rgb(0x6A6A6A) : rgb(0xE4002B)
    let glass = rgb(0x121417)
    let led = variant == .tinted ? rgb(0xFFFFFF) : rgb(0xFF9A1F)

    // 2. Tyres.
    ctx.setFillColor(rgb(0x1C1E22))
    for r in wheels { ctx.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.fillPath() }

    // 3. Body: yellow with the red skirt.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.setFillColor(yellow); ctx.fill(body)
    ctx.setFillColor(red); ctx.fill(CGRect(x: body.minX, y: 640, width: body.width, height: body.maxY - 640))
    // Destination display.
    ctx.setFillColor(glass)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 262, width: 388, height: 70), cornerWidth: 16, cornerHeight: 16, transform: nil)); ctx.fillPath()
    // LED "route" — chunky orange bars that read as text at any size.
    ctx.setFillColor(led)
    for (x, w) in [(340.0, 58.0), (414.0, 150.0), (578.0, 106.0)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 284, width: w, height: 26), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
    }
    // Windscreen with a glassy sheen.
    let windscreen = CGPath(roundedRect: CGRect(x: 300, y: 352, width: 424, height: 250), cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.setFillColor(glass); ctx.addPath(windscreen); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(windscreen); ctx.clip()
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: 470, y: 352)); sheen.addLine(to: CGPoint(x: 560, y: 352))
    sheen.addLine(to: CGPoint(x: 430, y: 602)); sheen.addLine(to: CGPoint(x: 340, y: 602)); sheen.closeSubpath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.13)); ctx.addPath(sheen); ctx.fillPath()
    let sheen2 = CGMutablePath()
    sheen2.move(to: CGPoint(x: 590, y: 352)); sheen2.addLine(to: CGPoint(x: 618, y: 352))
    sheen2.addLine(to: CGPoint(x: 488, y: 602)); sheen2.addLine(to: CGPoint(x: 460, y: 602)); sheen2.closeSubpath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.08)); ctx.addPath(sheen2); ctx.fillPath()
    ctx.restoreGState()
    // Headlights.
    ctx.setFillColor(rgb(0xFFF6D6))
    for x in [300.0, 634.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 676, width: 90, height: 40), cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.restoreGState()

    // 4. The little white number tag, stuck over the corner like a second sticker.
    ctx.saveGState()
    ctx.translateBy(x: 690, y: 808)
    ctx.rotate(by: 5 * .pi / 180)
    let tag = CGRect(x: -118, y: -52, width: 236, height: 104)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: rgb(0x000000, 0.5))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // A real fleet number in the app's mono face.
    let font = CTFontCreateWithName("IBMPlexMono-Bold" as CFString, 74, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "1971", attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: rgb(0x0B0C0E))!,
    ]))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.scaleBy(x: 1, y: -1) // text draws bottom-up
    ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

let fontURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("../Tabor/Resources/Fonts/IBMPlexMono-Bold.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

write(render(.normal), "AppIcon.png")
write(render(.dark), "AppIcon-Dark.png")
write(render(.tinted), "AppIcon-Tinted.png")
print("wrote icons to \(out)")
