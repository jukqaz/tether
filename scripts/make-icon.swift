// Renders Resources/Tether.iconset: the Tether mark (a crescent moon holding the power stroke:
// sleep, governed by power) glowing mint on a deep night squircle.
// Usage: swift scripts/make-icon.swift && iconutil -c icns Resources/Tether.iconset -o Resources/Tether.icns
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Same geometry as `TetherGlyph` in the app, in a unit square with y up.
enum Mark {
    static let center = NSPoint(x: 0.5, y: 0.45), radius: CGFloat = 0.36
    static let cut = NSPoint(x: 0.5 + 0.36 * 0.34, y: 0.45 + 0.36 * 0.36), cutRadius: CGFloat = 0.36 * 0.80
    static let bar = NSRect(x: 0.585 - 0.045, y: 0.50, width: 0.09, height: 0.40)

    static func circle(_ c: NSPoint, _ r: CGFloat, in rect: NSRect) -> NSBezierPath {
        let x = rect.minX + c.x * rect.width, y = rect.minY + c.y * rect.height, rr = r * rect.width
        return NSBezierPath(ovalIn: NSRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
    }

    static func bar(in rect: NSRect) -> NSBezierPath {
        let b = NSRect(x: rect.minX + bar.minX * rect.width, y: rect.minY + bar.minY * rect.height,
                       width: bar.width * rect.width, height: bar.height * rect.height)
        return NSBezierPath(roundedRect: b, xRadius: b.width / 2, yRadius: b.width / 2)
    }
}

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // Apple's macOS icon grid: an 824-pt body centred on a 1024-pt canvas.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.32)
    drop.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    drop.shadowBlurRadius = s * 0.025
    drop.set()
    NSGradient(colors: [color(0x163A55), color(0x0A1826)])!.draw(in: shape, angle: -90)
    NSShadow().set()

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x34D1A0, 0.30), color(0x34D1A0, 0)])!
        .draw(fromCenter: NSPoint(x: body.midX, y: body.midY - body.height * 0.03), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.midY), radius: body.width * 0.50, options: [])
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.13), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.004, dy: s * 0.004),
                            xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    edge.lineWidth = s * 0.004
    NSColor.white.withAlphaComponent(0.10).setStroke()
    edge.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    let markRect = body.insetBy(dx: body.width * 0.06, dy: body.width * 0.06)
    let outer = Mark.circle(Mark.center, Mark.radius, in: markRect)
    let inner = Mark.circle(Mark.cut, Mark.cutRadius, in: markRect)
    let crescent = NSBezierPath()
    crescent.append(outer)
    crescent.append(inner)
    crescent.windingRule = .evenOdd
    // Everything but the cut, so the glow stays out of the crescent's hollow.
    let outsideCut = NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s))
    outsideCut.append(inner)
    outsideCut.windingRule = .evenOdd

    NSGraphicsContext.current?.saveGraphicsState()
    outsideCut.addClip()
    let glow = NSShadow()
    glow.shadowColor = color(0x34D1A0, 0.65)
    glow.shadowBlurRadius = s * 0.05
    glow.shadowOffset = .zero
    glow.set()
    NSGraphicsContext.current?.saveGraphicsState()
    outer.addClip()
    color(0x3FD9AA).setFill()
    crescent.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    outer.addClip()
    crescent.addClip()
    NSGradient(colors: [color(0x8AF5D6), color(0x2CC59A), color(0x1C9E7C)])!.draw(in: outer.bounds, angle: -70)
    let shine = NSPoint(x: outer.bounds.minX + outer.bounds.width * 0.28, y: outer.bounds.minY + outer.bounds.height * 0.62)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: shine, radius: 0, toCenter: shine, radius: outer.bounds.width * 0.42, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    let barGlow = NSShadow()
    barGlow.shadowColor = color(0x34D1A0, 0.75)
    barGlow.shadowBlurRadius = s * 0.04
    barGlow.shadowOffset = .zero
    barGlow.set()
    NSGradient(colors: [color(0xF4FFFB), color(0xC8F7E7)])!.draw(in: Mark.bar(in: markRect), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "Resources/Tether.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!
            .write(to: dir.appendingPathComponent(name))
    }
}
print("wrote \(dir.path)")
