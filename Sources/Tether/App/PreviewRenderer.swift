import AppKit
import SwiftUI
import TetherCore

/// Screenshots for checking the design and for the README, drawn offscreen without clicking
/// through the menu bar. Liquid Glass does not render offscreen, so pass `-liquidGlass NO`.
///
///     Tether --render-preview out.png [dark] [--sample] [--hold]
///     Tether --render-settings out.png general|lid|safety|history|notifications|automation|system [dark] [--sample] [--auto]
///     Tether --render-welcome out.png [dark]
///     Tether --render-menubar out.png
///
/// `--sample` adds made-up usage (a recent lid session, a week of bars); `--hold` a running
/// battery hold; `--auto` turns auto-adjust on (with `--sample`).
@MainActor
enum PreviewRenderer {
    /// Renders what the arguments ask for; false when they ask for nothing, to run the app.
    static func handle(_ args: [String]) -> Bool {
        func path(after flag: String, extra: Int = 0) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 + extra < args.count else { return nil }
            return args[i + 1]
        }
        let dark = args.contains("dark"), sample = args.contains("--sample")
        if let out = path(after: "--render-menubar") {
            renderMenuBar(to: out)
        } else if let out = path(after: "--render-settings", extra: 1),
                  let page = SettingsPage(rawValue: args[args.firstIndex(of: "--render-settings")! + 2]) {
            let model = AppModel(preview: true, sample: sample, autoSample: args.contains("--auto"))
            model.settingsPage = page
            render(SettingsView(model: model, screenshot: true), to: out, dark: dark)

        } else if let out = path(after: "--render-welcome") {
            render(WelcomePreview(model: AppModel(preview: true)), to: out, dark: dark)
        } else if let out = path(after: "--render-preview") {
            let model = AppModel(preview: true, sample: sample, holdSample: args.contains("--hold"))
            render(TetherPanel(model: model).background(.regularMaterial), to: out, dark: dark)
        } else {
            return false
        }
        return true
    }

    /// The status item in each state, black on a light bar and white on a dark one, 2x.
    private static func renderMenuBar(to path: String) {
        let items: [AppModel.MenuBarItem] = [
            .init(icon: .mark(.on)),
            .init(icon: .mark(.held), text: "29:41", ring: 0.99),
            .init(icon: .mark(.held), text: "1:05:09", ring: 0.45),
            .init(icon: .mark(.on), text: "41°"),
            .init(icon: .mark(.off)),
            .init(icon: .mark(.disabled)),
            .init(icon: .symbol("exclamationmark.triangle")),
        ]
        let images = items.map(MenuBarIcon.image)
        let gap: CGFloat = 18, barHeight: CGFloat = 26
        let width = images.reduce(gap) { $0 + $1.size.width + gap }
        let size = NSSize(width: width, height: barHeight * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, (background, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black),
                                          (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            let y = CGFloat(1 - row) * barHeight
            background.setFill()
            NSRect(x: 0, y: y, width: width, height: barHeight).fill()
            var x = gap
            for image in images {
                // Template images are black; tint them the way the menu bar does.
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: y + (barHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height))
                x += image.size.width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// Hosts the panel in an offscreen window and caches its display, so real AppKit controls
    /// (switches, progress bars, menus) are drawn, unlike ImageRenderer.
    private static func render<V: View>(_ view: V, to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))  // let SwiftUI settle
        // Always 2x, so README screenshots stay sharp whichever screen is attached.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("render failed")
            return
        }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
}
