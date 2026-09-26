import AppKit
import SwiftUI

/// The Tether mark as a template image: a crescent moon (sleep) holding the power stroke. The app
/// icon uses the same geometry (scripts/make-icon.swift).
enum TetherGlyph {
    enum Style: Hashable {
        /// Clamshell mode is on: solid.
        case on
        /// Tether is on but clamshell is not (battery): outlined, stroke kept.
        case off
        /// Tether is switched off: outlined and struck through.
        case disabled
    }

    // Unit square, y up.
    private static let center = CGPoint(x: 0.5, y: 0.45), radius: CGFloat = 0.36
    private static let cut = CGPoint(x: 0.5 + 0.36 * 0.34, y: 0.45 + 0.36 * 0.36), cutRadius: CGFloat = 0.36 * 0.80
    private static let bar = CGRect(x: 0.585 - 0.05, y: 0.50, width: 0.10, height: 0.40)

    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ style: Style, size: CGFloat = 18) -> NSImage {
        let key = "\(style)|\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            draw(style, in: bounds.insetBy(dx: size * 0.03, dy: size * 0.03), lineWidth: max(1.2, size * 0.075))
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat, in rect: CGRect) -> NSBezierPath {
        let x = rect.minX + c.x * rect.width, y = rect.minY + c.y * rect.height, rr = r * rect.width
        return NSBezierPath(ovalIn: NSRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
    }

    private static func draw(_ style: Style, in rect: CGRect, lineWidth: CGFloat) {
        let outer = circle(center, radius, in: rect)
        let crescent = NSBezierPath()
        crescent.append(outer)
        crescent.append(circle(cut, cutRadius, in: rect))
        crescent.windingRule = .evenOdd
        let barRect = NSRect(x: rect.minX + bar.minX * rect.width, y: rect.minY + bar.minY * rect.height,
                             width: bar.width * rect.width, height: bar.height * rect.height)
        let stroke = NSBezierPath(roundedRect: barRect, xRadius: barRect.width / 2, yRadius: barRect.width / 2)
        NSColor.black.setFill()
        NSColor.black.setStroke()

        NSGraphicsContext.current?.saveGraphicsState()
        outer.addClip()
        if style == .on {
            crescent.fill()
        } else {
            // Stroking the evenodd outline inside the outer clip leaves an inset outline.
            crescent.lineWidth = lineWidth * 2
            crescent.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        switch style {
        case .on, .off:
            stroke.fill()
        case .disabled:
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.12))
            slash.line(to: NSPoint(x: rect.maxX - rect.width * 0.10, y: rect.minY + rect.height * 0.12))
            slash.lineWidth = lineWidth * 1.1
            slash.lineCapStyle = .round
            slash.stroke()
        }
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
