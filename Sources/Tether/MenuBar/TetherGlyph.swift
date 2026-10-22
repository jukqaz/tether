import AppKit
import SwiftUI

/// A folded plane matching the chosen Icon Composer artwork.
/// State indicators share the mark and a padded grid; the menu bar keeps a fixed canvas.
enum TetherGlyph {
    enum Style: Hashable {
        case on
        case held
        case off
        case disabled
    }

    enum Indicator {
        case timer
        case protection
        case review
        case pending
        case display
    }

    private static var cache: [String: NSImage] = [:]

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

    /// An 18pt grid with clear space on every edge, including at 1x menu bar resolution.
    static func draw(_ style: Style, in rect: CGRect, indicator: Indicator? = nil) {
        let u = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.black.set()
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * u, y: rect.minY + y * u, width: width * u, height: height * u)
        }
        func stroke(_ path: NSBezierPath, width: CGFloat) {
            path.lineWidth = width * u
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        let inactive = style == .off || style == .disabled
        func plane(_ vertices: [(CGFloat, CGFloat)], outlineWidth: CGFloat) {
            let path = NSBezierPath()
            path.move(to: point(vertices[0].0, vertices[0].1))
            for vertex in vertices.dropFirst() { path.line(to: point(vertex.0, vertex.1)) }
            path.close()
            if inactive { stroke(path, width: outlineWidth) } else { path.fill() }
        }
        // Fill means a confirmed keep-awake request; an outline means no active request.
        // The hinge gap distinguishes the folded planes without colour or extra width.
        plane([(9, 2.2), (13.7, 6.9), (6.9, 13.7), (2.2, 9)], outlineWidth: 1.15)
        plane([(14.6, 7.8), (15.8, 9), (12.2, 12.6), (10.1, 10.6)], outlineWidth: 1)
        plane([(7.8, 14.6), (9, 15.8), (11.2, 13.6), (9.2, 11.5)], outlineWidth: 1)

        guard let indicator = indicator ?? (style == .held ? .timer : nil) else { return }
        // Reserve a small, transparent knockout so the indicator reads on either bar theme.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: box(8.8, 8.8, 8.4, 8.4)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        switch indicator {
        case .timer:
            stroke(NSBezierPath(ovalIn: box(9.9, 9.9, 6.2, 6.2)), width: 1.15)
            let detail = NSBezierPath()
            detail.move(to: point(13, 11)); detail.line(to: point(13, 13)); detail.line(to: point(14.8, 13))
            stroke(detail, width: 1.1)
        case .review:
            let warning = NSBezierPath()
            warning.move(to: point(13, 10)); warning.line(to: point(16.1, 15.7))
            warning.line(to: point(9.9, 15.7)); warning.close()
            stroke(warning, width: 1.1)
            let detail = NSBezierPath()
            detail.move(to: point(13, 12)); detail.line(to: point(13, 13.5))
            stroke(detail, width: 1.15)
            NSBezierPath(ovalIn: box(12.5, 14.25, 1, 1)).fill()
        case .protection:
            let shield = NSBezierPath()
            shield.move(to: point(10, 10.4)); shield.line(to: point(16, 10.4)); shield.line(to: point(16, 12.5))
            shield.curve(to: point(13, 16), controlPoint1: point(16, 14.2), controlPoint2: point(14.8, 15.3))
            shield.curve(to: point(10, 12.5), controlPoint1: point(11.2, 15.3), controlPoint2: point(10, 14.2))
            shield.close()
            stroke(shield, width: 1.15)
            let centre = NSBezierPath()
            centre.move(to: point(13, 11.5)); centre.line(to: point(13, 14.2))
            stroke(centre, width: 1)
        case .pending:
            for x: CGFloat in [10.4, 13, 15.6] {
                NSBezierPath(ovalIn: box(x - 0.8, 12.2, 1.6, 1.6)).fill()
            }
        case .display:
            stroke(NSBezierPath(roundedRect: box(10, 10.4, 6, 4.4),
                               xRadius: 0.6 * u, yRadius: 0.6 * u), width: 1.1)
            let stand = NSBezierPath()
            stand.move(to: point(13, 14.8)); stand.line(to: point(13, 15.8))
            stand.move(to: point(11.4, 15.8)); stand.line(to: point(14.6, 15.8))
            stroke(stand, width: 1.1)
        }
    }
}

/// Use the packaged icon in the settings rail; preserve the monochrome glyph for status.
struct TetherAppIcon: View {
    var size: CGFloat = 40
    private static let image: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                TetherMark(style: .on, size: size).foregroundStyle(Color.tetherAccent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

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
