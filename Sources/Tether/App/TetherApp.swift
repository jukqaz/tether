import AppKit
import Combine
import SwiftUI
import TetherCore

@main
enum Launcher {
    static func main() {
        // Native surfaces follow macOS appearance; static renders choose their own scheme.
        // Only a separately identified, explicitly marked test bundle may use this path.
        if Bundle.main.bundleIdentifier?.hasPrefix(NativeUIAutomation.bundleID) == true {
            if NativeUIAutomation.isRequested(bundleID: Bundle.main.bundleIdentifier,
                fixture: Bundle.main.object(forInfoDictionaryKey: "TetherUIAutomationFixture") as? Bool,
                environment: ProcessInfo.processInfo.environment) {
                NativeUIAutomationApp.main()
            }
            // A misconfigured private test bundle must never fall through to live control.
            return
        }
        // The v3 design preview never constructs AppModel or starts a power executor.
        if MainActor.assumeIsolated({ DesignPreview.handle(CommandLine.arguments) }) { return }
        if Bundle.main.bundleIdentifier == "io.github.jukqaz.tether.preview" {
            MainActor.assumeIsolated { Workbench.launchPreview() }
            return
        }
        if CommandLine.arguments.contains("--workbench"), TetherPaths.serviceSocket != TetherPaths.productionSocket {
            MainActor.assumeIsolated { Workbench.open() }
            return
        }
        let rendered = MainActor.assumeIsolated { PreviewRenderer.handle(CommandLine.arguments) }
        guard !rendered else { return }
        // Keep one menu bar instance for consistent settings and notifications.
        if let id = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0 != NSRunningApplication.current }) {
            running.activate()
            return
        }
        // The kernel lease resolves concurrent launches before settings migration or
        // either power executor starts. A failed command endpoint is also fatal here.
        let ready = MainActor.assumeIsolated {
            guard let failure = AppModel.shared.coordinatorStartFailure else { return true }
            let alert = NSAlert()
            alert.messageText = L("Tether could not start", "Tether를 시작하지 못했습니다")
            alert.informativeText = failure
            alert.runModal()
            return false
        }
        guard ready else { return }
        TetherApp.main()
    }
}

/// Interactive development UI attached only to an explicitly selected dry-run helper. No
/// login item, screen guard, helper install or production power settings are touched.
@MainActor
private enum Workbench {
    static var window: NSWindow?
    static var model: AppModel?
    static var helper: Process?
    static var directory: URL?
    static var session: WorkbenchSession?
    static var menuPreview: WorkbenchMenuPreview?
    static let delegate = WorkbenchDelegate()

    static func launchPreview() {
        // A startup failure must be visible and accessible even before app.run().
        // Complete only this development bundle's AppKit launch before a modal alert.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        do {
            var template = Array("/tmp/tether-preview-XXXXXX".utf8CString)
            guard mkdtemp(&template) != nil else { throw ServiceFailure("writeFailed") }
            let folder = URL(fileURLWithPath: String(cString: template)); directory = folder
            let control = folder.appendingPathComponent("control.json")
            let fake = folder.appendingPathComponent("fake.json")
            let settings = Control()
            guard JSONFile.write(settings, to: control.path, permissions: 0o600) else { throw ServiceFailure("writeFailed") }
            try Data("{\"power\":\"ac\",\"lid\":\"open\",\"sleepDisabled\":false,\"fullWake\":true,\"external\":false,\"displaySleeping\":false,\"temperature\":30,\"thermal\":0,\"battery\":80}".utf8).write(to: fake)
            guard let executable = Bundle.main.url(forResource: "tether-helper", withExtension: nil) else { throw ServiceFailure("unavailable") }
            let process = Process(); process.executableURL = executable
            process.arguments = ["--dry-run", "--control", control.path, "--status", folder.appendingPathComponent("status.json").path, "--fake", fake.path]
            let log = folder.appendingPathComponent("helper.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log); process.standardOutput = output; process.standardError = output
            try process.run(); try? output.close(); helper = process
            let socket = folder.appendingPathComponent("service.sock").path
            setenv("TETHER_SERVICE_SOCKET", socket, 1)
            for _ in 0..<80 {
                if !process.isRunning { throw ServiceFailure("unavailable") }
                // Listening begins before the helper's first coalesced evaluation.
                // A successful socket reply without status is still startup in progress.
                if let reply = try? ServiceClient().perform(ServiceRequest(.snapshot)),
                   reply.protection?.dryRun == true, reply.status != nil {
                    // Exercise the same preparation/finite-lid-lease handshake as the
                    // shipping app, with an in-memory idle backend and private settings.
                    session = try WorkbenchSession(folder: folder, initial: reply)
                    open(); return
                }
                usleep(50_000)
            }
            throw ServiceFailure("unavailable")
        } catch {
            cleanup()
            app.activate()
            let alert = NSAlert(); alert.messageText = L("Preview could not start", "미리보기를 시작하지 못했습니다")
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    static func cleanup() {
        menuPreview?.remove(); menuPreview = nil
        session?.cleanup(); session = nil
        if let helper, helper.isRunning { helper.terminate(); helper.waitUntilExit() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    static func open() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Tether Preview")
        let quit = NSMenuItem(title: L("Quit Tether Preview", "Tether 미리보기 종료"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem)
        app.mainMenu = menu
        let model = session?.model ?? AppModel(preview: true)
        guard session != nil || model.protection?.dryRun == true else { print("Workbench requires a dry-run helper"); return }
        self.model = model
        model.settingsPage = .general
        let narrow = CommandLine.arguments.contains("--narrow")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: narrow ? 640 : 680, height: narrow ? 480 : 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // Match the shipping Settings viewport. The shared toolbar indicator
        // identifies simulation once, instead of repeating it in the title.
        window.title = "Tether"
        window.isReleasedWhenClosed = false
        // Keep SwiftUI navigation within an AppKit view-controller lifecycle.
        window.contentViewController = NSHostingController(rootView: WorkbenchView(model: model))
        window.contentMinSize = WorkSessionMetrics.settingsMinimum
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        model.startWorkbench()
        if session != nil {
            let preview = WorkbenchMenuPreview(model: model); menuPreview = preview
            // Also reachable through the native application menu for keyboard/AX testing.
            let command = NSMenuItem(title: L("Open menu panel", "메뉴 패널 열기"),
                action: #selector(WorkbenchMenuPreview.toggle), keyEquivalent: "m")
            command.keyEquivalentModifierMask = [.command, .shift]; command.target = preview
            appMenu.insertItem(command, at: 0)
            let compact = NSMenuItem(title: L("Preview small-screen height", "작은 화면 높이 미리보기"),
                action: #selector(WorkbenchMenuPreview.toggleCompactHeight), keyEquivalent: "p")
            compact.keyEquivalentModifierMask = [.command, .shift]; compact.target = preview
            appMenu.insertItem(compact, at: 1)
        }
        app.activate()
        app.run()
    }
}

/// Settings and the temporary menu item share the same isolated preview model.
private struct WorkbenchView: View {
    @ObservedObject var model: AppModel
    var body: some View { SettingsView(model: model) }
}

/// Native placement checks for the shipping views, backed only by Workbench's dry-run session.
/// This is an NSPopover harness; production continues to use SwiftUI's MenuBarExtra window.
@MainActor
private final class WorkbenchMenuPreview: NSObject, ObservableObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var modelObservation: AnyCancellable?
    @Published var maximumHeight: CGFloat? = nil

    init(model: AppModel) {
        super.init()
        item.button?.image = MenuBarIcon.image(model.menuBarItem(at: Date()))
        item.button?.imageScaling = .scaleNone
        item.button?.toolTip = L("Tether Preview · simulated state", "Tether 미리보기 · 모의 상태")
        item.button?.setAccessibilityLabel(L("Tether Preview menu", "Tether 미리보기 메뉴"))
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: WorkbenchPanel(model: model, preview: self))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        modelObservation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak model] _ in
            guard let model else { return }
            self?.item.button?.image = MenuBarIcon.image(model.menuBarItem(at: Date()))
        }
    }

    @objc func toggle() {
        if popover.isShown { popover.close() }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    @objc func toggleCompactHeight() {
        maximumHeight = maximumHeight == nil ? 360 : nil
        if !popover.isShown { toggle() }
    }

    func showSettings() {
        popover.close(); Workbench.window?.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    func remove() {
        modelObservation?.cancel(); modelObservation = nil
        popover.close()
        popover.contentViewController = nil // Break hosting view → preview → popover ownership.
        NSStatusBar.system.removeStatusItem(item)
    }
}

private struct WorkbenchPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: WorkbenchMenuPreview
    var body: some View {
        TetherPanel(model: model, maximumHeight: preview.maximumHeight, previewSettingsAction: preview.showSettings)
    }
}

@MainActor
private final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let stopped = await Workbench.model?.prepareToQuit() ?? true
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { Workbench.cleanup() }
}

struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        TetherScenes(model: model)
    }
}

/// Production and isolated native UI tests share the actual Scene host, not a bitmap renderer.
struct TetherScenes: Scene {
    @ObservedObject var model: AppModel

    var body: some Scene {
        MenuBarExtra {
            TetherPanel(model: model)
        } label: {
            MenuBarLabel(model: model, clock: model.clock)
                .background(V4SettingsOpener(model: model).frame(width: 0, height: 0))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: WorkSessionMetrics.settingsMinimum.width,
                     height: WorkSessionMetrics.settingsMinimum.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) { HelpCommand() }
        }
    }
}

/// Help › Tether Help, in the menu bar while the settings window is open: the README in the
/// app's language, instead of macOS's "Help isn't available".
private struct HelpCommand: View {
    var body: some View {
        Button(L("Tether Help", "Tether 도움말")) { NSWorkspace.shared.open(UpdateChecker.readmeURL) }
            .keyboardShortcut("?", modifiers: .command)
    }
}

/// Receives `tether://` URLs (Shortcuts, scripts) and shows the first-run window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var initialSetupObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if model.acceptingUserCommands, !model.userCommandsArePreview, !model.developmentService {
            Self.removeRetiredShortcutPreferences(from: model.defaults)
        }
        if model.needsOnboarding { WelcomeWindow.show(model: model); return }
        guard model.requiresHelperSetup, !model.helperSetupChecked else { return }
        initialSetupObservation = model.$helperSetupChecked.first(where: { $0 }).sink { [weak self] _ in
            Task { @MainActor in
                self?.initialSetupObservation = nil
                if model.needsOnboarding { WelcomeWindow.show(model: model) }
            }
        }
    }

    /// Called only by the normal app launch, never by a render or fixture.
    /// Retiring shortcuts must not reset power choices or other app preferences.
    static func removeRetiredShortcutPreferences(from defaults: UserDefaults) {
        defaults.removeObject(forKey: "v4GlobalShortcuts")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let stopped = await AppModel.shared.prepareToQuit()
            if !stopped {
                let alert = NSAlert()
                alert.messageText = L("Tether is still running", "Tether가 계속 실행 중입니다")
                alert.informativeText = AppModel.shared.errorText ?? L("Review App Settings before quitting.", "앱 설정에서 확인한 뒤 다시 종료해 주세요.")
                alert.addButton(withTitle: L("Return to Tether", "Tether로 돌아가기"))
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handle(url: url) }
    }
}

/// User-selected notification actions use the supported SwiftUI Settings action.
private struct V4SettingsOpener: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.onChange(of: model.v4SettingsPresentationID) { _, _ in
            NSApp.activate(); openSettings()
        }
    }
}
