import AppKit
import SwiftUI
import TetherCore

/// This entry point runs before production startup. Every operation is presentation-only.
@MainActor
enum DesignPreview {
    private static var windows: [NSWindow] = []
    private static let delegate = PreviewDelegate()

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
        let state = DesignPreviewState(scenario: value("--scenario").flatMap(DesignPreviewState.Scenario.init(rawValue:)) ?? .ac)
        let page = value("--page").flatMap(DesignPreviewSettings.Page.init(rawValue:)) ?? .sessions
        let dark = !args.contains("--light")
        let narrow = args.contains("--narrow")
        if interactive { open(state, page: page, narrow: narrow, dark: dark); return true }
        guard let flag = flags.first(where: args.contains), let output = value(flag), output.hasPrefix("/") else {
            print("Design render requires an absolute output path."); exit(2)
        }
        if flag == "--render-design-panel" {
            render(DesignPreviewPanel(state: state), to: output, dark: dark)
        } else if flag == "--render-design-settings" {
            render(DesignPreviewSettings(state: state, page: page, snapshot: true)
                .frame(width: 560, height: 448), to: output, dark: dark)
        } else {
            render(VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Tether").font(.system(size: 22, weight: .semibold))
                    Text(L("v4 native UI preview", "v4 native UI 미리보기")).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Example data · No system changes", "예시 데이터 · 시스템 변경 없음"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 20) {
                    DesignPreviewSettings(state: state, page: page, snapshot: true).frame(width: 560, height: 448)
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("Menu bar panel", "메뉴바 패널")).font(.system(size: 12)).foregroundStyle(.secondary)
                        DesignPreviewPanel(state: state).background(.regularMaterial, in: .rect(cornerRadius: 16))
                        Text(L("Remote connections do not change the icon width.\nManual and automatic actions have separate scopes.", "원격 연결에 따라 아이콘 폭을 바꾸지 않습니다.\n수동 종료와 전체 중지의 범위를 구분합니다."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(width: DesignPreviewMetrics.panelWidth)
                }
            }.padding(24), to: output, dark: dark)
        }
        return true
    }

    private static func open(_ state: DesignPreviewState, page: DesignPreviewSettings.Page, narrow: Bool, dark: Bool) {
        let app = NSApplication.shared
        app.delegate = delegate; app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Tether Design", "Tether 디자인 종료"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
        let settings = makeWindow(title: L("Tether · Preview", "Tether · 미리보기"),
            size: NSSize(width: 560, height: 448), dark: dark,
            view: DesignPreviewSettings(state: state, page: page, showPreviewControls: true))
        let panel = makeWindow(title: L("Tether · Menu preview", "Tether · 메뉴 미리보기"), size: NSSize(width: 280, height: 540), dark: dark,
            view: DesignPreviewPanel(state: state, openSettings: { settings.makeKeyAndOrderFront(nil) }))
        settings.contentMinSize = NSSize(width: 560, height: 448)
        panel.setContentSize(panel.contentView!.fittingSize)
        settings.center()
        let visible = (settings.screen ?? NSScreen.main)?.visibleFrame ?? settings.frame
        let right = settings.frame.maxX + 16
        let x = right + panel.frame.width <= visible.maxX ? right
            : max(visible.minX + 16, settings.frame.minX - panel.frame.width - 16)
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 16, settings.frame.maxY - panel.frame.height)))
        windows = [settings, panel]
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        app.activate(); app.run()
    }

    private static func makeWindow<V: View>(title: String, size: NSSize, dark: Bool, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.setContentSize(size)
        return window
    }

    private static func render<V: View>(_ view: V, to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Only exported snapshots need an opaque backing; live native panes stay untouched.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = app.appearance; window.contentView = host
        host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(3) }
        bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
        do {
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("wrote \(path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
        } catch { print("Design render failed: \(error.localizedDescription)"); exit(3) }
    }

    private final class PreviewDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
