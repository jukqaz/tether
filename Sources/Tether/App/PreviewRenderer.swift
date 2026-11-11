import AppKit
import SwiftUI
import TetherCore

/// Screenshots for checking the design and for the README, drawn offscreen without clicking
/// through the menu bar. Liquid Glass does not render offscreen, so pass `-liquidGlass NO`.
///
///     Tether --render-preview out.png [dark] [--sample] [--hold]
///     Tether --render-settings out.png general|safety|system [dark] [--sample] [--narrow] [--english]
///     Tether --render-settings out.png general dark --desktop|--hardware-unavailable
///     Tether --render-welcome out.png [dark] [--desktop] [--english] [--sample] [--prepared-lid]
///     Tether --render-menubar out.png [--1x]
///     Tether --render-manual-controls out.png dark [--manual] [--timed] [--battery]
///     Tether --render-preview out.png --sample --prepared-lid --display-on [--paused|--protection]
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
        if args.contains(where: ["--render-rehearsal", "--render-history", "--render-update-wait"].contains) {
            // Retired render flags must never fall through to the normal app.
            FileHandle.standardError.write(Data("This optional feature has been removed.\n".utf8))
            return true
        }
        if let out = path(after: "--render-menubar-label") {
            let model = sampleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            render(MenuBarLabel(model: model, clock: model.clock)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color(nsColor: .windowBackgroundColor)), to: out, dark: dark)
        } else if let out = path(after: "--render-rules") {
            let model = sampleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            render(V4AutomaticRulesView(model: model,
                initialTemplate: args.contains("--rules-work-hours") ? .workHours : nil), to: out, dark: dark)
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
            let defaults = PreviewDefaults()
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
            let defaults = PreviewDefaults()
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
            let standard = WorkSessionMetrics.settingsDefault
            render(SettingsView(model: model, screenshot: true, expandedDetails: args.contains("--expanded"))
                .environment(\.tetherSettingsScrollToEnd, args.contains("--scroll-end"))
                .frame(width: args.contains("--wide") ? 1240 : args.contains("--narrow") ? minimum.width : standard.width,
                       height: args.contains("--narrow") ? minimum.height : standard.height), to: out, dark: dark)

        } else if let out = path(after: "--render-welcome") {
            let hardware: MacCapabilities = args.contains("--desktop")
                ? .init(supportedPlatform: true, internalBattery: false, lid: false)
                : .init(supportedPlatform: true, internalBattery: true, lid: true)
            let model = makeModel(arguments: args, sample: sample, idle: !sample, capabilities: hardware)
            defer { _ = model.userSession?.end() }
            render(WelcomePreview(model: model), to: out, dark: dark)
        } else if let out = path(after: "--render-preview") {
            let model = sample || args.contains("--hold") || manualSample != nil || args.contains("--prepared-lid")
                ? sampleModel(arguments: args)
                : idleModel(arguments: args)
            defer { _ = model.userSession?.end() }
            render(TetherPanel(model: model, expandedDetails: args.contains("--expanded"),
                expandedPowerDetails: args.contains("--power-expanded")).background(Color.tetherBackground), to: out, dark: dark)
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
        let defaults = PreviewDefaults()
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
        let preparedLid = arguments.contains("--prepared-lid")
        if preparedLid { work.setAllowClosedLid(true) }
        if arguments.contains("--display-on") { work.setKeepDisplayAwake(true) }
        if arguments.contains("--automatic-rest") { _ = work.pauseAutomatic(for: 1800) }
        if arguments.contains("--automatic-rest-until-resume") { _ = work.pauseAutomatic(for: nil) }
        if arguments.contains("--paused") { work.stopCurrent() }
        if arguments.contains("--protection") {
            work.update(power: battery ? .battery : .ac, thermal: 2, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
        }
        let hardware = capabilities ?? (arguments.contains("--hardware-unavailable")
            ? MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
            : MacCapabilities(supportedPlatform: true, internalBattery: !arguments.contains("--desktop"), lid: !arguments.contains("--desktop")))
        let helper = preparedLid ? RenderHelper(power: battery ? .battery : .ac,
            protected: arguments.contains("--protection")) : nil
        let model = AppModel(preview: true, sample: sample, compactSample: arguments.contains("--compact"),
            capabilities: hardware,
            previewSession: work,
            previewLegacyObservation: helper.map { value in { value.observation } },
            previewWorkService: { request in
                guard let helper else { throw ServiceFailure("renderOnly") }
                return try helper.perform(request)
            }, previewHelperReply: helper?.reply(), previewDefaults: defaults,
            previewHelperFiles: helper == nil ? nil : { [] },
            previewPowerBattery: PowerBatterySample.monitor(scenario: {
                if let index = arguments.firstIndex(of: "--power-state"), index + 1 < arguments.count {
                    return arguments[index + 1]
                }
                return battery ? "discharging" : "charging"
            }()))
        if helper != nil {
            FileHandle.standardError.write(Data("Render-only simulated helper; no installed helper, OS assertion or physical lid behavior is verified.\n".utf8))
        }
        // Pin the simulated picker as well as the labels; never import the installed choice.
        model.language = arguments.contains("--english") || Localization.current == .english ? .english : .korean
        if arguments.contains("--menu-details") { model.menuBarDetails = true }
        return model
    }

    /// In-memory screenshot scenario only. A simulated current grant is echoed
    /// consistently; this is never a connection to, or evidence from, macOS.
    private final class RenderHelper {
        let power: PowerSource
        let protected: Bool
        private let epoch = "render-only-helper"
        private var current: WorkSessionLease?
        private var preparation: WorkSessionPreparation?
        private var connected = true
        init(power: PowerSource, protected: Bool) { self.power = power; self.protected = protected }
        var observation: Snapshot {
            .init(power: power, lidClosed: false, sleepDisabled: simulatedLidActive, fullWake: true, externalDisplay: false)
        }
        private var simulatedLidActive: Bool {
            !protected && connected && current?.lidPermit != nil && current?.reasons.isEmpty == false
        }
        func perform(_ request: ServiceRequest) throws -> ServiceReply {
            switch request.action {
            case .snapshot: break
            case .prepareWorkSession:
                guard let lease = request.workSession, lease.reasons.isEmpty else { throw ServiceFailure("renderOnly") }
                preparation = WorkSessionPreparation(sessionID: lease.sessionID, epoch: epoch,
                    revision: 1, expiresAt: ContinuousTime.now + IdleSessionPolicy.healthTTL)
            case .attachWorkSession, .syncWorkSession:
                guard let lease = request.workSession else { throw ServiceFailure("renderOnly") }
                current = lease; preparation = nil; connected = true
            case .detachApp:
                current = nil; preparation = nil; connected = false
            default: throw ServiceFailure("renderOnly")
            }
            return reply(id: request.id)
        }
        func reply(id: UUID = UUID()) -> ServiceReply {
            var control = Control(); control.schemaVersion = Control.currentSchema
            control.enabled = current?.configuration.enabled ?? true
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: control.enabled, power: power, lidClosed: false, sleepDisabled: simulatedLidActive,
                lastEvent: nil, lastEventAt: nil, fullWake: true, thermal: protected ? 2 : 0, batteryPercent: 80)
            status.build = TetherPaths.build; status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
            status.lidObservationAvailable = true; status.sleepOverrideObservationAvailable = true
            status.systemPowerObservationAvailable = true; status.appConnected = connected
            status.appPID = connected ? getpid() : nil
            status.ownsOverride = simulatedLidActive; status.workSession = current
            status.displayTopology = DisplayTopology.none; status.externalDisplay = false; status.nativeDisplayVerified = false
            var protection = ProtectionState(); if protected { protection.block("thermal") }
            var value = ServiceReply(id: id, ok: true, epoch: epoch, revision: 1, control: control,
                protection: .init(reason: protected ? "thermal" : nil, error: nil, dryRun: true))
            value.status = status; value.workSessionPreparation = preparation
            value.workSessionBridge = .init(coordinated: true, automaticBudget: protection, manualBudget: nil)
            return value
        }
    }

    /// Visual samples only: neither power requests nor preference files are created.
    private final class RenderSessionBackend: IdleAssertionBackend {
        func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { (0, 1) }
        func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
        func level(id: UInt32) -> Int? { 255 }
        func release(id: UInt32) -> Int32 { 0 }
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
    static func render<V: View>(_ view: V, to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let contrast = CommandLine.arguments.contains("--high-contrast")
        app.appearance = NSAppearance(named: contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        // A normal window supplies its backdrop. The borderless offscreen host must supply
        // the same base explicitly, otherwise transparent root panes export as black.
        let host = NSHostingView(rootView: view
            .environment(\.controlActiveState, .active)
            .background(Color(nsColor: .windowBackgroundColor)))
        var size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))  // let SwiftUI settle
        // In-memory helper replies may remove a warning during the settle pass.
        // Refit the actual host/window before capture; never crop the exported
        // bitmap. Explicitly framed Settings retain their original dimensions.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            let measured = host.fittingSize
            guard measured.width.isFinite, measured.height.isFinite,
                  measured.width > 0, measured.height > 0 else { break }
            guard abs(measured.width - size.width) > 0.5
                || abs(measured.height - size.height) > 0.5 else { break }
            size = measured
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
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
