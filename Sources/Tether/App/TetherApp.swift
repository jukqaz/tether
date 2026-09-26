import AppKit
import SwiftUI
import TetherCore

@main
enum Launcher {
    static func main() {
        let rendered = MainActor.assumeIsolated { PreviewRenderer.handle(CommandLine.arguments) }
        if !rendered { TetherApp.main() }
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
