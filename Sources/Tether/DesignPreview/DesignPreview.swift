import AppKit
import SwiftUI
import TetherCore

/// This entry point runs before production startup. Every operation is presentation-only.
@MainActor
enum DesignPreview {
    private static var windows: [NSWindow] = []
    private static var activeState: DesignPreviewState?
    private static let delegate = PreviewDelegate()

    enum ScenarioArgumentError: Error, Equatable, LocalizedError {
        case missingValue, repeatedFlag, unsupported(String)

        var errorDescription: String? {
            switch self {
            case .missingValue: "--scenario requires a supported scenario name."
            case .repeatedFlag: "Specify --scenario only once."
            case .unsupported(let value): "Unsupported design scenario: \(value)."
            }
        }
    }

    static func selectedScenario(arguments: [String]) throws -> DesignPreviewState.Scenario {
        let matches = arguments.indices.filter { arguments[$0] == "--scenario" }
        guard matches.count <= 1 else { throw ScenarioArgumentError.repeatedFlag }
        guard let index = matches.first else { return .ac }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            throw ScenarioArgumentError.missingValue
        }
        let value = arguments[index + 1]
        guard let scenario = DesignPreviewState.Scenario(rawValue: value) else {
            throw ScenarioArgumentError.unsupported(value)
        }
        return scenario
    }

    static func handle(_ args: [String]) -> Bool {
        let flags = ["--render-design", "--render-design-panel", "--render-design-settings"]
        let dedicatedBundle = Bundle.main.bundleIdentifier == "io.github.jukqaz.tether.design"
        let interactive = args.contains("--design-preview") || (dedicatedBundle && !flags.contains(where: args.contains))
        guard interactive || flags.contains(where: args.contains) else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        if args.contains("--english") { Localization.current = .english }
        let scenario: DesignPreviewState.Scenario
        do { scenario = try selectedScenario(arguments: args) }
        catch { print(error.localizedDescription); exit(2) }
        let state = DesignPreviewState(scenario: scenario)
        let page = value("--page").flatMap(DesignPreviewSettings.Page.init(rawValue:)) ?? .sessions
        let dark = !args.contains("--light")
        let narrow = args.contains("--narrow")
        if interactive { open(state, page: page, narrow: narrow, dark: dark); return true }
        defer { state.close() }
        let settingsSize = narrow ? WorkSessionMetrics.settingsMinimum : WorkSessionMetrics.settingsDefault
        guard let flag = flags.first(where: args.contains), let output = value(flag), output.hasPrefix("/") else {
            print("Design render requires an absolute output path."); exit(2)
        }
        if flag == "--render-design-panel" {
            PreviewRenderer.render(DesignPreviewPanel(state: state), to: output, dark: dark)
        } else if flag == "--render-design-settings" {
            PreviewRenderer.render(DesignPreviewSettings(state: state, page: page, snapshot: true)
                .frame(width: settingsSize.width, height: settingsSize.height), to: output, dark: dark)
        } else {
            PreviewRenderer.render(VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Tether").font(.system(size: 22, weight: .semibold))
                    Text(L("Native UI preview", "native UI 미리보기")).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Example data · No system changes", "예시 데이터 · 시스템 변경 없음"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 20) {
                    DesignPreviewSettings(state: state, page: page, snapshot: true)
                        .frame(width: settingsSize.width, height: settingsSize.height)
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("Menu bar panel", "메뉴바 패널")).font(.system(size: 12)).foregroundStyle(.secondary)
                        DesignPreviewPanel(state: state).background(Color.tetherBackground, in: .rect(cornerRadius: 16))
                        Text(L("Remote connections do not change the icon width.\nManual and automatic actions have separate scopes.", "원격 연결에 따라 아이콘 폭을 바꾸지 않습니다.\n수동 종료와 전체 중지의 범위를 구분합니다."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(width: WorkSessionMetrics.panelWidth)
                }
            }.padding(24), to: output, dark: dark)
        }
        return true
    }

    private static func open(_ state: DesignPreviewState, page: DesignPreviewSettings.Page, narrow: Bool, dark: Bool) {
        let app = NSApplication.shared
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }
        activeState?.close()
        activeState = state
        app.delegate = delegate; app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Tether Design", "Tether 디자인 종료"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
        let settings = makeWindow(title: L("Tether · Preview", "Tether · 미리보기"),
            size: narrow ? WorkSessionMetrics.settingsMinimum : WorkSessionMetrics.settingsDefault, dark: dark,
            view: DesignPreviewSettings(state: state, page: page))
        let panel = makeWindow(title: L("Tether · Menu preview", "Tether · 메뉴 미리보기"),
            size: NSSize(width: WorkSessionMetrics.panelWidth, height: WorkSessionMetrics.panelMaximumHeight), dark: dark,
            view: DesignPreviewPanel(state: state, openSettings: { settings.makeKeyAndOrderFront(nil) }))
        settings.contentMinSize = WorkSessionMetrics.settingsMinimum
        panel.setContentSize(panel.contentView!.fittingSize)
        settings.center()
        let visible = (settings.screen ?? NSScreen.main)?.visibleFrame ?? settings.frame
        let right = settings.frame.maxX + 16
        let x = right + panel.frame.width <= visible.maxX ? right
            : max(visible.minX + 16, settings.frame.minX - panel.frame.width - 16)
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 16, settings.frame.maxY - panel.frame.height)))
        windows = [settings, panel]
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        state.startObserving()
        app.activate(); app.run()
    }

    static func makeWindow<V: View>(title: String, size: NSSize, dark: Bool, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.setContentSize(size)
        return window
    }

    private final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            windows.removeAll { $0 === window }
            if windows.isEmpty { activeState?.close(); activeState = nil }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationWillTerminate(_ notification: Notification) {
            activeState?.close(); activeState = nil
        }
    }
}
