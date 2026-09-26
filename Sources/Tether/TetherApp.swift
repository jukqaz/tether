import AppKit
import SwiftUI
import TetherCore

@main
enum Launcher {
    static func main() {
        // `Tether --render-preview out.png [dark] [--sample]` draws the panel with live data (plus
        // made-up usage with --sample) and exits;
        // used to check the design without clicking through the menu bar.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-menubar"), i + 2 < args.count {
            // `Tether --render-menubar out.png "1:23" [symbol|mark]`: the status item image.
            MainActor.assumeIsolated {
                let name = i + 3 < args.count ? args[i + 3] : "bag.fill"
                let icon: AppModel.Icon = name == "mark" ? .mark(.on) : .symbol(name)
                let image = MenuBarIcon.image(icon: icon, text: args[i + 2])
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("wrote \(args[i + 1]) (\(image.size.width)x\(image.size.height) pt, \(rep.pixelsWide)x\(rep.pixelsHigh) px)")
                }
            }
            return
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 2 < args.count,
           let page = SettingsPage(rawValue: args[i + 2]) {
            // `Tether --render-settings out.png general|lid|safety|history|notifications|control|system [dark] [--sample]`
            MainActor.assumeIsolated {
                render(SettingsView(model: AppModel(preview: true, sample: args.contains("--sample")), initialPage: page),
                       to: args[i + 1], dark: args.contains("dark"))
            }
            return
        }
        if let i = args.firstIndex(of: "--render-welcome"), i + 1 < args.count {
            // `Tether --render-welcome out.png [dark]`
            MainActor.assumeIsolated {
                render(WelcomePreview(model: AppModel(preview: true)), to: args[i + 1], dark: args.contains("dark"))
            }
            return
        }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated {
                render(TetherPanel(model: AppModel(preview: true, sample: args.contains("--sample")))
                           .background(.regularMaterial),
                       to: args[i + 1], dark: args.contains("dark"))
            }
            return
        }
        TetherApp.main()
    }

    /// Hosts the panel in an offscreen window and caches its display, so real AppKit controls
    /// (switches, progress bars, menus) are drawn, unlike ImageRenderer.
    @MainActor
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("render failed")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(size.width))x\(Int(size.height)))")
    }
}

struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            TetherPanel(model: model)
        } label: {
            MenuBarLabel(item: model.menuBarItem)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Receives `tether://` URLs (Shortcuts, scripts, `tether blank`) and shows the first-run window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if model.needsOnboarding { WelcomeWindow.show(model: model) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handle(url: url) }
    }
}

/// The status item. With a text (hold countdown, temperature) the icon and text are drawn into
/// one template image, so they sit together and follow the menu bar's appearance.
struct MenuBarLabel: View {
    let item: AppModel.MenuBarItem

    var body: some View {
        if let text = item.text {
            Image(nsImage: MenuBarIcon.image(icon: item.icon, text: text))
        } else {
            switch item.icon {
            case .mark(let style): Image(nsImage: TetherGlyph.image(style))
            case .symbol(let name): Image(systemName: name)
            }
        }
    }
}

@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(icon: AppModel.Icon, text: String) -> NSImage {
        let key = "\(icon)|\(text)"
        if let cached = cache[key] { return cached }
        let content = HStack(spacing: 3) {
            switch icon {
            case .mark(let style): TetherMark(style: style, size: 16)
            case .symbol(let name): Image(systemName: name).font(.system(size: 13, weight: .medium))
            }
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        if cache.count > 32 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
