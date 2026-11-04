import SwiftUI
import TetherCore

/// macOS owns sidebar selection, toolbar material and scroll-edge treatment.
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
            // The window bridge owns the content minimum. A second minimum on
            // NavigationSplitView adds native toolbar/footer heights to it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if !screenshot { SettingsWindowBridge() } }
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
    @State private var columns: NavigationSplitViewVisibility = .all

    private var selection: Binding<SettingsPage?> {
        Binding(get: { model.settingsPage }, set: { if let page = $0 { model.settingsPage = page } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(SettingsPage.allCases, selection: selection) { page in
                Label {
                    Text(page.shortTitle)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .tag(page)
                .accessibilityLabel(page.title)
                .accessibilityIdentifier("settings-tab-\(page.rawValue)")
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 148, ideal: 160, max: 190)
            .accessibilityIdentifier("settings-sidebar")
        } detail: {
            model.settingsPage.page(model: model, disclosures: $disclosures)
                .accessibilityIdentifier("settings-page-\(model.settingsPage.rawValue)")
                .navigationTitle(model.settingsPage.title)
                // An opaque toolbar prevents scrolled text ghosting behind the title.
                .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if model.userCommandsArePreview {
                ToolbarItem(placement: .primaryAction) { PreviewIndicator() }
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    columns = columns == .detailOnly ? .all : .detailOnly
                } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).controlSize(.small)
                .help(L("Show sidebar", "사이드바 보기"))
                .accessibilityIdentifier("settings-toggle-sidebar")
            }.sharedBackgroundVisibility(.hidden)
        }
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
    // Retain raw identities used by saved routes and external callers.
    case safety, general, protection, system
    var id: Self { self }
    var title: String {
        switch self {
        case .safety: L("Power & Lid", "전원·덮개")
        case .general: L("Manual", "직접 유지")
        case .protection: L("Protection & Diagnostics", "보호·진단")
        case .system: L("General", "일반")
        }
    }
    var shortTitle: String { self == .protection ? L("Protection", "보호·진단") : title }
    var subtitle: String {
        switch self {
        case .safety: L("Power connection, disconnection and closed-lid work.", "전원 연결·분리와 덮개 동작을 정합니다.")
        case .general: L("Defaults for the next manual start.", "다음에 직접 시작할 작업의 기본값입니다.")
        case .protection: L("Device protection, activity and diagnostics.", "기기 보호와 사용 기록·진단을 확인합니다.")
        case .system: L("Startup, language, notifications and updates.", "시작·언어·알림·업데이트를 관리합니다.")
        }
    }
    var symbol: String {
        switch self {
        case .safety: "powerplug"
        case .general: "timer"
        case .protection: "shield.lefthalf.filled"
        case .system: "gearshape"
        }
    }
    var color: Color { .tetherSecondary }
    @MainActor @ViewBuilder
    func page(model: AppModel, disclosures: Binding<SettingsDisclosureState>? = nil) -> some View {
        switch self {
        case .safety: SafetyPage(model: model, disclosures: disclosures)
        case .general: GeneralPage(model: model, disclosures: disclosures)
        case .protection: ProtectionPage(model: model, disclosures: disclosures)
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
            let contentMinimum = minimumSize
            let center = NotificationCenter.default
            // SwiftUI may reuse the window after it closes, so opening again is seen as "became key".
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    // Keep only the window affordances that Settings may reset.
                    // SwiftUI retains ownership of its native tabs and toolbar.
                    DispatchQueue.main.async { [weak window] in
                        guard let window else { return }
                        Self.configureChrome(window, allowsResizing: resize, minimumSize: contentMinimum)
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
                        Self.configureChrome(window, allowsResizing: true, minimumSize: contentMinimum)
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
                Self.configureChrome(window, allowsResizing: resize, minimumSize: contentMinimum)
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

        private static func configureChrome(_ window: NSWindow, allowsResizing: Bool, minimumSize: CGSize) {
            // The automatic Settings host recomputes this after page changes.
            // Reconcile only a changed constraint; do not resize the user's window.
            if window.contentMinSize != minimumSize { window.contentMinSize = minimumSize }
            // Settings can ignore the Scene toolbar style when presenting its
            // own host. Reconcile the same native compact style, without custom chrome.
            if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
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
