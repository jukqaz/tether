import AppKit
import SwiftUI

/// The Tether mark: a closed laptop lid with a crescent, and its power cable while it runs on
/// power. The app icon (Resources/AppIcon.icon) uses the same shapes.
enum TetherGlyph {
    enum Style: Hashable {
        /// Clamshell mode on power: solid lid, cable attached.
        case on
        /// A battery hold keeps clamshell mode on: solid lid, no cable.
        case held
        /// Tether is on but clamshell is not (battery): outlined lid, no cable.
        case off
        /// Tether is switched off: outlined and struck through.
        case disabled
    }

    private static var cache: [String: NSImage] = [:]

    /// The mark alone, as a template image.
    @MainActor
    static func image(_ style: Style, size: CGFloat = 18) -> NSImage {
        let key = "\(style)|\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(style, in: rect)
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// Draws the mark in black into a square of a flipped (y-down) context, on an 18-unit grid.
    /// With the cable, the lid moves left to make room for it on the right, where a laptop's
    /// port is; a cable from the bottom reads as a speech bubble at menu bar size.
    static func draw(_ style: Style, in rect: CGRect) {
        let u = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        let left: CGFloat = style == .on ? 1.2 : 2.3
        let lidRect = NSRect(x: rect.minX + left * u, y: rect.minY + 3.2 * u, width: 13.4 * u, height: 9.6 * u)
        let moon = crescent(center: point(left + 6.3, 8.1), radius: 2.9 * u, cut: point(left + 7.75, 7.0), cutRadius: 2.3 * u)
        NSColor.black.set()
        switch style {
        case .on, .held:
            let lid = NSBezierPath(roundedRect: lidRect, xRadius: 2.0 * u, yRadius: 2.0 * u)
            lid.append(moon)
            lid.windingRule = .evenOdd
            lid.fill()
            if style == .on {
                let cable = NSBezierPath()
                cable.move(to: point(14.0, 9.6))
                cable.curve(to: point(17.1, 12.8), controlPoint1: point(16.3, 9.6), controlPoint2: point(17.1, 10.6))
                cable.line(to: point(17.1, 16.8))
                cable.lineWidth = 1.5 * u
                cable.lineCapStyle = .round
                cable.lineJoinStyle = .round
                cable.stroke()
            }
        case .off, .disabled:
            let outline = NSBezierPath(roundedRect: lidRect.insetBy(dx: 0.65 * u, dy: 0.65 * u),
                                       xRadius: 1.4 * u, yRadius: 1.4 * u)
            outline.lineWidth = 1.3 * u
            outline.stroke()
            moon.fill()
            if style == .disabled {
                let slash = NSBezierPath()
                slash.move(to: point(2.8, 1.8))
                slash.line(to: point(15.6, 15.6))
                slash.lineCapStyle = .round
                // Clear a gap along the slash first, as SF Symbols do.
                let context = NSGraphicsContext.current
                context?.compositingOperation = .clear
                slash.lineWidth = 3.4 * u
                slash.stroke()
                context?.compositingOperation = .sourceOver
                slash.lineWidth = 1.4 * u
                slash.stroke()
            }
        }
    }

    /// The part of one circle outside another: the arc of the first circle away from the cut,
    /// then back along the cut circle.
    private static func crescent(center a: NSPoint, radius ra: CGFloat, cut b: NSPoint, cutRadius rb: CGFloat) -> NSBezierPath {
        let dx = b.x - a.x, dy = b.y - a.y, d = hypot(dx, dy)
        let along = (ra * ra - rb * rb + d * d) / (2 * d)
        let h = sqrt(max(0, ra * ra - along * along))
        let mid = NSPoint(x: a.x + along * dx / d, y: a.y + along * dy / d)
        let i1 = NSPoint(x: mid.x - h * dy / d, y: mid.y + h * dx / d)
        let i2 = NSPoint(x: mid.x + h * dy / d, y: mid.y - h * dx / d)
        func angle(_ p: NSPoint, _ c: NSPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) * 180 / .pi }
        let path = NSBezierPath()
        path.appendArc(withCenter: a, radius: ra, startAngle: angle(i1, a), endAngle: angle(i2, a), clockwise: false)
        path.appendArc(withCenter: b, radius: rb, startAngle: angle(i2, b), endAngle: angle(i1, b), clockwise: true)
        path.close()
        return path
    }
}

/// The mark as a SwiftUI view that takes the foreground style.
struct TetherMark: View {
    let style: TetherGlyph.Style
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: TetherGlyph.image(style, size: size))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
    }
}
