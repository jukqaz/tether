import SwiftUI
import TetherCore

/// The settings window, laid out like System Settings: a sidebar of coloured icons, a grouped
/// form on the right. Measurements sit next to the settings they inform; the full record is in
/// "History".
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page: SettingsPage?
    /// Offscreen screenshots can't draw the system's sidebar selection (it comes out as a black
    /// bar hiding the title), so they mark the current page themselves.
    private let screenshot: Bool

    init(model: AppModel, initialPage: SettingsPage = .general, screenshot: Bool = false) {
        self.model = model
        self.screenshot = screenshot
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: screenshot ? .constant(nil) : $page) { item in
                Label {
                    Text(item.title)
                } icon: {
                    SidebarIcon(symbol: item.symbol, color: item.color)
                }
                .tag(item)
                .listRowBackground(screenshot && item == page
                                   ? RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.09)).padding(.horizontal, 10)
                                   : nil)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let current = page ?? .general
            current.page(model: model)
                .navigationTitle(current.title)
        }
        .frame(width: 800, height: 620)
        .background(SettingsWindowBridge())
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, lid, safety, history, notifications, automation, system

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L("General", "일반")
        case .lid: L("Lid & Screen", "덮개와 화면")
        case .safety: L("Safety", "배터리와 발열")
        case .history: L("History", "기록")
        case .notifications: L("Notifications", "알림")
        case .automation: L("Automation", "자동화")
        case .system: L("System", "시스템")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .lid: "laptopcomputer"
        case .safety: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .notifications: "bell.badge.fill"
        case .automation: "terminal.fill"
        case .system: "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .lid: .blue
        case .safety: .orange
        case .history: .tetherMint
        case .notifications: .red
        case .automation: .purple
        case .system: Color(white: 0.45)
        }
    }

    @MainActor @ViewBuilder
    func page(model: AppModel) -> some View {
        switch self {
        case .general: GeneralPage(model: model)
        case .lid: LidPage(model: model)
        case .safety: SafetyPage(model: model)
        case .history: HistoryPage(model: model)
        case .notifications: NotificationsPage(model: model)
        case .automation: AutomationPage(model: model)
        case .system: SystemPage(model: model)
        }
    }
}

/// Keeps the settings window reachable. Tether has no Dock icon, and the window of such an
/// accessory app was taken off screen as soon as another app came forward (a System Settings
/// link, say), with no ⌘-Tab entry to get back. While the window is open Tether is a regular
/// app instead: Dock icon, ⌘-Tab, window stays put. Closing it returns Tether to the menu bar.
struct SettingsWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowWatcher: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.hidesOnDeactivate = false
            let center = NotificationCenter.default
            // SwiftUI may reuse the window after it closes, so opening again is seen as "became key".
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { _ in
                MainActor.assumeIsolated { Self.showInDock(true) }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                queue: .main) { _ in
                MainActor.assumeIsolated { Self.showInDock(false) }
            })
            Self.showInDock(true)
        }

        static func showInDock(_ on: Bool) {
            let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
            guard NSApp.activationPolicy() != policy else { return }
            NSApp.setActivationPolicy(policy)
            if on { NSApp.activate() }
        }
    }
}
