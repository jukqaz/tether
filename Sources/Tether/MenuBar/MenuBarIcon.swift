import AppKit

/// The status item, drawn with AppKit into one template image: the mark (or an SF Symbol for a
/// problem), a ring that empties as a battery hold runs out, and a short text (the countdown or
/// the battery temperature). Cheap enough to redraw every second.
@MainActor
enum MenuBarIcon {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static var cache: [AppModel.MenuBarItem: NSImage] = [:]

    static func image(_ item: AppModel.MenuBarItem) -> NSImage {
        // Only the still images are worth keeping; a countdown changes every second.
        let still = item.text == nil && item.ring == nil
        if still, let cached = cache[item] { return cached }
        let text = item.text.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let textSize = text?.size() ?? .zero
        let side: CGFloat = item.ring == nil ? 18 : 20
        let width = side + (text == nil ? 0 : 3 + ceil(textSize.width))
        let image = NSImage(size: NSSize(width: width, height: side), flipped: true) { _ in
            let square = NSRect(x: 0, y: 0, width: side, height: side)
            if let ring = item.ring {
                drawRing(ring, in: square)
                drawIcon(item.icon, in: square.insetBy(dx: 4, dy: 4))
            } else {
                drawIcon(item.icon, in: square)
            }
            text?.draw(at: NSPoint(x: side + 3, y: (side - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        if still { cache[item] = image }
        return image
    }

    private static func drawIcon(_ icon: AppModel.Icon, in rect: NSRect) {
        switch icon {
        case .mark(let style):
            TetherGlyph.draw(style, in: rect)
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.75, weight: .medium)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
        }
    }

    /// A thin track with the remaining part drawn solid, from 12 o'clock clockwise.
    private static func drawRing(_ fraction: Double, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2 - 1
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.6
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + 360 * min(1, fraction),
                      clockwise: false)
        arc.lineWidth = 1.6
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }
}
