import AppKit
import SwiftUI
import TetherCore

@main
enum Launcher {
    static func main() {
        let rendered = MainActor.assumeIsolated { PreviewRenderer.handle(CommandLine.arguments) }
        guard !rendered else { return }
        // One copy at a time: two would each hold the screen awake and fight over dimming.
        if let id = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0 != NSRunningApplication.current }) {
            running.activate()
            return
        }
        TetherApp.main()
    }
}

struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            TetherPanel(model: model)
        } label: {
            MenuBarLabel(model: model, clock: model.clock)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(replacing: .help) { HelpCommand(model: model) }
        }
    }
}

/// Help › Tether Help, in the menu bar while the settings window is open: the Help page,
/// instead of macOS's "Help isn't available".
private struct HelpCommand: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L("Tether Help", "Tether 도움말")) {
            model.settingsPage = .help
            openSettings()
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}

/// Receives `tether://` URLs (Shortcuts, scripts) and shows the first-run window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if model.needsOnboarding { WelcomeWindow.show(model: model) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handle(url: url) }
    }
}
