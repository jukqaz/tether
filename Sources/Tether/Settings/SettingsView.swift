import SwiftUI
import TetherCore

/// macOS owns tab placement, toolbar material and the scroll-edge treatment.
/// Page and disclosure selections remain presentation state of this window.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var screenshot = false
    @State private var disclosures: SettingsDisclosureState

    init(model: AppModel, screenshot: Bool = false, expandedDetails: Bool = false) {
        self.model = model
        self.screenshot = screenshot
        _disclosures = State(initialValue: SettingsDisclosureState(expanded: expandedDetails))
    }

    var body: some View {
        SettingsNavigation(model: model, disclosures: $disclosures)
            .tint(.tetherAccent)
            .frame(minWidth: WorkSessionMetrics.settingsMinimum.width,
                   minHeight: WorkSessionMetrics.settingsMinimum.height)
            .background { if !screenshot { SettingsWindowBridge() } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.userCommandsArePreview {
                    HStack {
                        Spacer()
                        PreviewIndicator()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .sheet(isPresented: $model.showActivityReview, onDismiss: {
                if !model.showActivityReview { model.activityReviewPresentationOrigin = .unknown }
            }) {
                ActivityReviewView(model: model, sample: model.userCommandsArePreview || model.developmentService,
                    presentationOrigin: model.activityReviewPresentationOrigin)
            }
    }
}

struct SettingsNavigation: View {
    @ObservedObject var model: AppModel
    @Binding var disclosures: SettingsDisclosureState

    var body: some View {
        TabView(selection: $model.settingsPage) {
            ForEach(SettingsPage.allCases) { page in
                page.page(model: model, disclosures: $disclosures)
                    .tag(page)
                    .tabItem {
                        Label(page.shortTitle, systemImage: page.symbol)
                            .accessibilityLabel(page.title)
                            .accessibilityIdentifier("settings-tab-\(page.rawValue)")
                    }
                    .accessibilityIdentifier("settings-page-\(page.rawValue)")
            }
        }
        .tabViewStyle(.automatic)
        .accessibilityLabel(L("Settings pages", "설정 페이지"))
    }
}

/// Presentation state belongs to the settings window, not power preferences.
/// Standalone page renderers can continue using their local State fallback.
struct SettingsDisclosureState {
    var manualBattery = false
    var workRules = false
    var protectionAlerts = false
    var protectionRules = false
    var diagnostics = false
    var updates = false
    var helper = false
    var automaticConnections = false
    var closedLidDisplay = false
    var usageStatistics = false
    var otherAppRequests = false
    init(expanded: Bool = false) {
        manualBattery = expanded; workRules = expanded; protectionAlerts = expanded; protectionRules = expanded
        diagnostics = expanded; updates = expanded; helper = expanded
        automaticConnections = expanded; closedLidDisplay = expanded
        usageStatistics = expanded; otherAppRequests = expanded
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, safety, system
    var id: Self { self }
    var title: String {
        switch self {
        case .general: L("Keep awake", "잠자기 방지")
        case .safety: L("Power & automation", "전원·자동화")
        case .system: L("App settings", "앱 설정")
        }
    }
    /// Native preference tabs retain a short visible title and the full accessible name.
    var shortTitle: String {
        switch self {
        case .general: L("Keep awake", "유지")
        case .safety: L("Power & automation", "전원·자동화")
        case .system: L("App", "앱")
        }
    }
    var subtitle: String {
        switch self {
        case .general: L("Display, closed-lid work and protection.", "화면·덮개 사용과 보호 기준을 정합니다.")
        case .safety: L("Power connection, disconnection and optional rules.", "전원 연결·분리 동작과 선택적 자동 규칙을 정합니다.")
        case .system: L("Startup, helper, diagnostics and updates.", "시작 동작과 도우미, 진단, 업데이트를 관리합니다.")
        }
    }
    var symbol: String {
        switch self { case .general: "laptopcomputer"; case .safety: "powerplug"; case .system: "slider.horizontal.3" }
    }
    var color: Color {
        switch self { case .general, .safety: .tetherAccent; case .system: .tetherSecondary }
    }
    @MainActor @ViewBuilder
    func page(model: AppModel, disclosures: Binding<SettingsDisclosureState>? = nil) -> some View {
        switch self {
        case .general: GeneralPage(model: model, disclosures: disclosures)
        case .safety: SafetyPage(model: model, disclosures: disclosures)
        case .system: SystemPage(model: model, disclosures: disclosures)
        }
    }
}

/// Keeps the settings window reachable. Tether has no Dock icon, and the window of such an
/// accessory app was taken off screen as soon as another app came forward (a System Settings
/// link, say), with no ⌘-Tab entry to get back. While the window is open Tether is a regular
/// app instead: Dock icon, ⌘-Tab, window stays put. Closing it returns Tether to the menu bar.
struct SettingsWindowBridge: NSViewRepresentable {
    var minimumSize = WorkSessionMetrics.settingsMinimum
    var allowsResizing = true

    func makeNSView(context: Context) -> NSView {
        WindowWatcher(minimumSize: minimumSize, allowsResizing: allowsResizing)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowWatcher: NSView {
        private var observers: [NSObjectProtocol] = []
        private weak var initialFocusWindow: NSWindow?
        private let minimumSize: CGSize
        private let allowsResizing: Bool

        init(minimumSize: CGSize, allowsResizing: Bool) {
            self.minimumSize = minimumSize
            self.allowsResizing = allowsResizing
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.hidesOnDeactivate = false
            window.contentMinSize = minimumSize
            let resize = allowsResizing
            let center = NotificationCenter.default
            // SwiftUI may reuse the window after it closes, so opening again is seen as "became key".
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    // Keep only the window affordances that Settings may reset.
                    // SwiftUI retains ownership of its native tabs and toolbar.
                    DispatchQueue.main.async { [weak window] in
                        guard let window else { return }
                        Self.configureChrome(window, allowsResizing: resize)
                        Self.migrateCompactGeometry(window, allowsResizing: resize)
                    }
                    Self.showInDock(true)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                queue: .main) { _ in
                MainActor.assumeIsolated { Self.showInDock(false) }
            })
            if resize {
                // The Settings host can restore its fixed style after the first
                // key-window callback. Reconcile resizing without replacing the
                // toolbar, titlebar or system material.
                observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window,
                                                    queue: .main) { [weak window] _ in
                    DispatchQueue.main.async { [weak window] in
                        guard let window, window.isVisible else { return }
                        Self.configureChrome(window, allowsResizing: true)
                        Self.migrateCompactGeometry(window, allowsResizing: true)
                    }
                })
            }
            Self.showInDock(true)
            let clearInitialFocus = initialFocusWindow !== window && NSApp.currentEvent?.type != .keyDown
            initialFocusWindow = window
            // Settings' native host applies its fixed-size style after attaching
            // the view, even with Scene.contentMinSize. Keep SwiftUI's measured
            // content/chrome constraints and enable only the resize affordance.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                Self.configureChrome(window, allowsResizing: resize)
                Self.migrateCompactGeometry(window, allowsResizing: resize)
                // Native hosting may focus its first switch before any keyboard
                // input. Clear only the initial mouse/startup selection; later
                // Tab navigation, page changes and reactivation keep their focus.
                if clearInitialFocus, NSApp.currentEvent?.type != .keyDown { window.makeFirstResponder(nil) }
            }
        }

        static func enableResizing(_ window: NSWindow) {
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        }

        private static func migrateCompactGeometry(_ window: NSWindow, allowsResizing: Bool) {
            // Settings can restore the previous design's frame instead of the
            // Scene default. Migrate that presentation once; a later resize or
            // reopen, including subsequent compact builds, belongs to the user.
            // Fixtures, Preview and unmarked source bundles never write it.
            guard allowsResizing, window.isVisible,
                  Bundle.main.bundleIdentifier == "io.github.jukqaz.tether",
                  let design = Bundle.main.object(forInfoDictionaryKey: "TetherDesignRevision") as? String,
                  design.hasPrefix("2026-10-13-compact-approved")
                    || design.hasPrefix("2026-10-14-compact")
                    || design.hasPrefix("2026-10-15-v4-compact-approved") else { return }
            let key = "settingsWindowGeometryRevision"
            let revision = "2026-10-15-v4-compact-tabs-560x448"
            let defaults = UserDefaults.standard
            guard defaults.string(forKey: key) != revision else { return }
            window.setContentSize(WorkSessionMetrics.settingsMinimum)
            defaults.set(revision, forKey: key)
        }

        private static func configureChrome(_ window: NSWindow, allowsResizing: Bool) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            guard (allowsResizing && !window.styleMask.contains(.resizable))
                || buttons.contains(where: { window.standardWindowButton($0)?.isHidden == true }) else { return }
            if allowsResizing { enableResizing(window) }
            for button in buttons {
                window.standardWindowButton(button)?.isHidden = false
            }
        }

        static func showInDock(_ on: Bool) {
            let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
            guard NSApp.activationPolicy() != policy else { return }
            NSApp.setActivationPolicy(policy)
            if on { NSApp.activate() }
        }
    }
}
