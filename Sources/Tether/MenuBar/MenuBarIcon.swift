import AppKit
import TetherCore

/// State changes the silhouette, never the status item's size or text.
@MainActor
enum MenuBarIcon {
    private static var cache: [AppModel.Icon: NSImage] = [:]

    static func image(_ item: AppModel.MenuBarItem) -> NSImage {
        let icon: AppModel.Icon
        switch item.icon {
        case .mark(.off), .mark(.disabled): icon = .mark(.disabled)
        case .mark: icon = item.icon
        case .symbol(let name):
            // Only known work states enter the menu bar; remote badges and
            // retired payload detail fields cannot change or widen it.
            let names = ["shield.lefthalf.filled", "exclamationmark.triangle", "hourglass", "display"]
            icon = names.contains(name) ? item.icon : .symbol("exclamationmark.triangle")
        }
        if let cached = cache[icon] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 20), flipped: true) { _ in
            switch icon {
            case .mark(let style):
                TetherGlyph.draw(style, in: NSRect(x: 0, y: 1, width: 18, height: 18))
            case .symbol(let name):
                let indicator: TetherGlyph.Indicator
                switch name {
                case "shield.lefthalf.filled": indicator = .protection
                case "hourglass": indicator = .pending
                case "display": indicator = .display
                default: indicator = .review
                }
                TetherGlyph.draw(.on, in: NSRect(x: 0, y: 1, width: 18, height: 18), indicator: indicator)
            }
            return true
        }
        image.isTemplate = true
        cache[icon] = image
        return image
    }
}
