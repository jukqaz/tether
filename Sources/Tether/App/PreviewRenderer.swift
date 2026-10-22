import AppKit
import SwiftUI
import TetherCore

/// Screenshots for checking the design and for the README, drawn offscreen without clicking
/// through the menu bar. Liquid Glass does not render offscreen, so pass `-liquidGlass NO`.
///
///     Tether --render-preview out.png [dark] [--sample] [--hold]
///     Tether --render-settings out.png general|safety|system [dark] [--sample] [--narrow] [--english]
///     Tether --render-settings out.png general dark --desktop|--hardware-unavailable
///     Tether --render-welcome out.png [dark] [--desktop] [--english]
///     Tether --render-menubar out.png [--1x]
///     Tether --render-manual-controls out.png dark [--manual] [--timed] [--battery]
///
/// `--sample` uses simulated state; no real power request is made.
@MainActor
enum PreviewRenderer {
    /// Renders what the arguments ask for; false when they ask for nothing, to run the app.
    static func handle(_ args: [String]) -> Bool {
        func path(after flag: String, extra: Int = 0) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 + extra < args.count else { return nil }
            return args[i + 1]
        }
        let dark = args.contains("dark"), sample = args.contains("--sample")
        let manualSample: ManualSessionStatus? = args.contains("--manual") || args.contains("--manual-ready")
            ? ManualSessionStatus(active: args.contains("--manual"), holding: args.contains("--manual"),
                until: args.contains("--timed") ? Date().addingTimeInterval(30 * 60).timeIntervalSince1970 : nil,
                batteryRemaining: ManualSessionPolicy.batteryMaximum, endReason: nil) : nil
        if args.contains("--english") { Localization.current = .english }
        if let flag = ["--render-rehearsal", "--render-history", "--render-rules", "--render-update-wait"].first(where: args.contains),
           let out = path(after: flag) {
            let model = sampleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            switch flag {
            case "--render-rehearsal": render(V4RehearsalView(model: model), to: out, dark: dark)
            case "--render-history": render(V4SettingsHistoryView(model: model), to: out, dark: dark)
            case "--render-rules": render(V4AutomaticRulesView(model: model), to: out, dark: dark)
            default: render(V4UpdateAfterWorkView(model: model).padding(20).frame(width: 560), to: out, dark: dark)
            }
        } else if let out = path(after: "--render-displays", extra: 1),
           let i = args.firstIndex(of: "--render-displays"),
           let data = FileManager.default.contents(atPath: args[i + 2]),
           let report = try? JSONDecoder().decode(DisplayReport.self, from: data) {
            render(VStack(alignment: .leading, spacing: 14) {
                Text(L("Observed display connections", "실제 시스템 화면 관측")).font(.title2.bold())
                Text(Texts.time(Date(timeIntervalSince1970: report.checkedAt))).font(.caption).foregroundStyle(Color.tetherSecondary)
                DisplayFindingsView(report: report)
            }.padding(24).frame(width: 744).background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-updates") {
            render(UpdateSettingsCard(model: idleModel(arguments: args))
                .padding(20).frame(width: args.contains("--narrow") ? 400 : 640)
                .background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-diagnostics") {
            render(VStack(alignment: .leading, spacing: 16) {
                Text(L("Diagnostics & reports", "진단과 보고서")).font(.system(size: 19, weight: .semibold))
                DiagnosticControls(model: idleModel(arguments: args))
            }.padding(20).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-manual-controls") {
            let defaults = RenderSessionDefaults()
            let work = UserSessionController(defaults: defaults, backend: RenderSessionBackend(), displayBackend: RenderSessionBackend(),
                guiProbe: nil, environmentProbe: nil, boot: "render-only")
            let power: PowerSource = args.contains("--battery") ? .battery : .ac
            work.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: work, previewWorkService: { _ in throw ServiceFailure("renderOnly") }, previewDefaults: defaults)
            if args.contains("--manual") {
                work.setAutomatic(true)
                _ = work.start(duration: args.contains("--timed") || power == .battery ? 1800 : nil)
            }
            defer { _ = work.end() }
            render(ManualSessionControls(model: model, clock: model.clock, compact: true)
                .padding(18).frame(width: 368).background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-recent") {
            let defaults = RenderSessionDefaults()
            let work = UserSessionController(defaults: defaults, backend: RenderSessionBackend(), displayBackend: RenderSessionBackend(),
                guiProbe: nil, environmentProbe: nil, boot: "render-only")
            work.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            work.setAutomatic(true)
            _ = work.start(duration: 180)
            work.stopCurrent()
            work.update(power: .battery, thermal: 2, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let model = AppModel(preview: true, previewSession: work,
                previewWorkService: { _ in throw ServiceFailure("renderOnly") }, previewDefaults: defaults)
            defer { _ = work.end() }
            render(RecentActivityView(model: model, initiallyExpanded: true)
                .padding(20).frame(width: 640, height: 500, alignment: .top), to: out, dark: dark)
        } else if let out = path(after: "--render-influences") {
            render(SleepInfluenceView(model: idleModel(arguments: args), inspector: PowerActivityInspector(simulated: true))
                .padding(20).frame(width: args.contains("--narrow") ? 400 : 704)
                .background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-activity") {
            render(ActivityReviewView(model: idleModel(arguments: args), sample: true), to: out, dark: dark)
        } else if let out = path(after: "--render-menubar") {
            renderMenuBar(to: out, scale: args.contains("--1x") ? 1 : 2)
        } else if let out = path(after: "--render-settings", extra: 1),
                  let page = SettingsPage(rawValue: args[args.firstIndex(of: "--render-settings")! + 2]) {
            // Both ordinary and hardware previews stay in memory. Even a missing
            // capability cannot fall back to a live helper snapshot.
            let model = sample ? sampleModel(arguments: args) : idleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            if args.contains("--recording"), model.userCommandsArePreview, model.usesUserSession {
                // Capture the active-recording surface using only the render controller.
                model.setDebugLogging(true, minutes: 15)
            }
            model.settingsPage = page
            let minimum = WorkSessionMetrics.settingsMinimum
            render(SettingsView(model: model, screenshot: true, expandedDetails: args.contains("--expanded"))
                .environment(\.tetherSettingsScrollToEnd, args.contains("--scroll-end"))
                .frame(width: args.contains("--wide") ? 1240 : args.contains("--narrow") ? minimum.width : 920,
                       height: args.contains("--narrow") ? minimum.height : 700), to: out, dark: dark)

        } else if let out = path(after: "--render-welcome") {
            let hardware: MacCapabilities = args.contains("--desktop")
                ? .init(supportedPlatform: true, internalBattery: false, lid: false)
                : .init(supportedPlatform: true, internalBattery: true, lid: true)
            let model = idleModel(arguments: args, capabilities: hardware)
            defer { _ = model.userSession?.end() }
            render(WelcomePreview(model: model), to: out, dark: dark)
        } else if let out = path(after: "--render-preview") {
            let model = sample || args.contains("--hold") || manualSample != nil
                ? sampleModel(arguments: args)
                : idleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            render(TetherPanel(model: model).background(.regularMaterial), to: out, dark: dark)
        } else {
            return false
        }
        return true
    }

    /// Titles, switches and timers share the real controller's simulated state.
    /// Never combine a live helper snapshot with fresh, unrelated default switches.
    static func sampleModel(arguments: [String]) -> AppModel {
        makeModel(arguments: arguments, sample: true, idle: false)
    }

    private static func idleModel(arguments: [String], capabilities: MacCapabilities? = nil) -> AppModel {
        makeModel(arguments: arguments, sample: false, idle: true, capabilities: capabilities)
    }

    private static func makeModel(arguments: [String], sample: Bool, idle: Bool,
                                  capabilities: MacCapabilities? = nil) -> AppModel {
        let defaults = RenderSessionDefaults()
        let work = UserSessionController(defaults: defaults, backend: RenderSessionBackend(),
            displayBackend: RenderSessionBackend(), guiProbe: nil, environmentProbe: nil, boot: "render-only")
        let battery = arguments.contains("--hold") || arguments.contains("--battery")
        let manual = arguments.contains("--manual")
        let manualReady = arguments.contains("--manual-ready")
        work.update(power: battery ? .battery : .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        if !idle && ((!manual && !manualReady) || arguments.contains("--dual")) {
            work.setAutomatic(!battery)
        }
        if !idle && (manual || (battery && !manualReady)) {
            _ = work.start(duration: arguments.contains("--timed") || battery ? 1800 : nil)
        }
        let hardware = capabilities ?? (arguments.contains("--hardware-unavailable")
            ? MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
            : MacCapabilities(supportedPlatform: true, internalBattery: !arguments.contains("--desktop"), lid: !arguments.contains("--desktop")))
        return AppModel(preview: true, sample: sample, compactSample: arguments.contains("--compact"),
            capabilities: hardware,
            previewSession: work, previewWorkService: { _ in throw ServiceFailure("renderOnly") },
            previewDefaults: defaults)
    }

    /// Visual samples only: neither power requests nor preference files are created.
    private final class RenderSessionBackend: IdleAssertionBackend {
        func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { (0, 1) }
        func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
        func level(id: UInt32) -> Int? { 255 }
        func release(id: UInt32) -> Int32 { 0 }
    }
    private final class RenderSessionDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        private var registered: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
        override func string(forKey key: String) -> String? { object(forKey: key) as? String }
        override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
        override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
        override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
        override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
        override func persistentDomain(forName name: String) -> [String: Any]? { values }
        override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
        override func removePersistentDomain(forName name: String) { values.removeAll() }
        override func synchronize() -> Bool { true }
    }

    /// Ordered states: automatic, off, manual, protection, error, pending, macOS-managed.
    /// Every sample has the same 18x20pt canvas, on light and dark bars.
    private static func renderMenuBar(to path: String, scale: CGFloat) {
        let items: [AppModel.MenuBarItem] = [
            .init(icon: .mark(.on)),
            .init(icon: .mark(.off)),
            .init(icon: .mark(.held), ring: 0.45, countdown: MenuBarCountdown(remaining: 3909)),
            .init(icon: .symbol("shield.lefthalf.filled")),
            .init(icon: .symbol("exclamationmark.triangle")),
            .init(icon: .symbol("hourglass")),
            .init(icon: .symbol("display")),
        ]
        let images = items.map(MenuBarIcon.image)
        let gap: CGFloat = 18, barHeight: CGFloat = 26
        let width = images.reduce(gap) { $0 + $1.size.width + gap }
        let size = NSSize(width: width, height: barHeight * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
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
        let contrast = CommandLine.arguments.contains("--high-contrast")
        app.appearance = NSAppearance(named: contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        // A normal window supplies its backdrop. The borderless offscreen host must supply
        // the same base explicitly, otherwise transparent root panes export as black.
        let host = NSHostingView(rootView: view
            .environment(\.controlActiveState, .active)
            .background(Color(nsColor: .windowBackgroundColor)))
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
