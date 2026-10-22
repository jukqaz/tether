import SwiftUI
import TetherCore

/// Fixed native tabs and a single reading viewport keep compact settings clear.
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                navigation
                    // Honor actual safe area only. The old split-view-specific
                    // 28pt fallback left an extra empty header above these tabs.
                    .padding(.top, screenshot ? 0 : geometry.safeAreaInsets.top)
                Divider().overlay(Color.tetherDivider)
                detail
            }
        }
        .font(TetherTypography.body).controlSize(.small)
        .tint(.tetherAccent)
        .frame(minWidth: WorkSessionMetrics.settingsMinimum.width,
               minHeight: WorkSessionMetrics.settingsMinimum.height)
        .background { if !screenshot { SettingsWindowBridge() } }
        .sheet(isPresented: $model.showActivityReview, onDismiss: {
            if !model.showActivityReview { model.activityReviewPresentationOrigin = .unknown }
        }) {
            ActivityReviewView(model: model, sample: model.userCommandsArePreview || model.developmentService,
                presentationOrigin: model.activityReviewPresentationOrigin)
        }
    }

    private var navigation: some View {
        ZStack {
            SettingsNavigation(selection: $model.settingsPage, snapshot: screenshot)
                .frame(maxWidth: 340)
            if model.userCommandsArePreview {
                HStack {
                    Spacer(minLength: 0)
                    PreviewIndicator()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SettingsMetrics.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var detail: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                PageHeading(title: model.settingsPage.title, subtitle: model.settingsPage.subtitle, compact: true)
                    .accessibilityIdentifier("settings-page-heading")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.scrollContentInset(in: geometry.size.width))
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Color.tetherBackground)
                model.settingsPage.page(model: model, disclosures: $disclosures)
                    .id(model.settingsPage)
                    .accessibilityIdentifier("settings-page-\(model.settingsPage.rawValue)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tetherBackground)
        }
    }

}

struct SettingsNavigation: View {
    @Binding var selection: SettingsPage
    var snapshot = false

    var body: some View {
        Picker(L("Settings pages", "설정 페이지"), selection: Binding(
            get: { selection }, set: { value in
                guard selection != value else { return }
                // Commit the native segment selection before replacing the page.
                DispatchQueue.main.async {
                    if selection != value { selection = value }
                }
            })) {
            ForEach(SettingsPage.allCases) { page in
                Label(page.shortTitle, systemImage: page.symbol)
                    .font(TetherTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .tag(page)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(page.title)
                    .accessibilityIdentifier("settings-tab-\(page.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(L("Settings pages", "설정 페이지"))
        .accessibilityIdentifier("settings-navigation")
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
    init(expanded: Bool = false) {
        workRules = expanded; protectionAlerts = expanded; protectionRules = expanded
        diagnostics = expanded; updates = expanded; helper = expanded
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, safety, system
    var id: Self { self }
    var title: String {
        switch self {
        case .general: L("Work sessions", "작업 유지")
        case .safety: L("Protection", "기기 보호")
        case .system: L("App settings", "앱 설정")
        }
    }
    /// Navigation stays compact in the three native tabs. The heading and
    /// accessibility label retain the full page name.
    var shortTitle: String {
        switch self {
        case .general: L("Work", "작업 유지")
        case .safety, .system: title
        }
    }
    var subtitle: String {
        switch self {
        case .general: L("AC timing and permission for closed-lid work are independent.", "AC 자동의 시작 조건과 유지 중 덮개 허용을 각각 정합니다.")
        case .safety: L("Protect work with battery and thermal limits.", "배터리와 열 상태에 따라 안전하게 유지합니다.")
        case .system: L("Startup, helper, diagnostics and updates.", "시작 동작과 도우미, 진단, 업데이트를 관리합니다.")
        }
    }
    var symbol: String {
        switch self { case .general: "power"; case .safety: "shield.lefthalf.filled"; case .system: "gearshape" }
    }
    var color: Color {
        switch self { case .general: .tetherAccent; case .safety: .tetherWarning; case .system: .tetherSecondary }
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
                    // The Settings host restores its automatic toolbar each
                    // time a retained window opens. Apply the same layout after
                    // that native presentation, not just on first attachment.
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
                // key-window callback, without becoming key again. Reconcile
                // only this window's changed chrome after a native update.
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
            guard window.toolbar?.isVisible == true || window.titlebarAppearsTransparent
                || window.titleVisibility != .visible || window.styleMask.contains(.fullSizeContentView)
                || (allowsResizing && !window.styleMask.contains(.resizable))
                || buttons.contains(where: { window.standardWindowButton($0)?.isHidden == true }) else { return }
            // Navigation lives in the fixed tab strip; there are no commands in
            // Settings' automatic icon toolbar. Keep the native title and close
            // affordance rather than hiding the whole window toolbar in SwiftUI.
            window.toolbar?.isVisible = false
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
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
