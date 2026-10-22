import AppKit
import SwiftUI
import TetherCore

/// General work needs no helper. Selected notebook lid support requires preparation.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static var windowDelegate: SetupDelegate?

    @MainActor
    private final class SetupDelegate: NSObject, NSWindowDelegate {
        weak var model: AppModel?
        init(model: AppModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let model else { return false }
            // Window dismissal never applies draft choices or bypasses required setup.
            return !model.needsOnboarding
        }
        func windowWillClose(_ notification: Notification) {
            WelcomeWindow.window = nil; WelcomeWindow.windowDelegate = nil
        }
    }

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingView(rootView: WelcomeView(model: model) { close(model: model) }
            .background(SettingsWindowBridge(minimumSize: CGSize(width: 560, height: 448), allowsResizing: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 448),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = L("Welcome to Tether", "Tether 시작하기")
        window.identifier = NSUserInterfaceItemIdentifier("tether-welcome-window")
        window.contentView = host
        window.isReleasedWhenClosed = false
        let delegate = SetupDelegate(model: model)
        window.delegate = delegate
        windowDelegate = delegate
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    private static func close(model: AppModel) {
        guard !model.needsOnboarding else { return }
        window?.close()
        window = nil
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var automaticDraft: Bool
    @State private var closedLidDraft: Bool
    @State private var applyError: String?

    init(model: AppModel, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        // Existing choices are shown exactly as saved, never replaced by new defaults.
        _automaticDraft = State(initialValue: model.v3Settings.automaticEnabled)
        _closedLidDraft = State(initialValue: model.v3Settings.allowClosedLid)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Prepare Tether", "Tether 시작 준비")).font(TetherTypography.page)
                Spacer()
                if model.userCommandsArePreview { PreviewIndicator() }
            }.padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.supportedMac {
                        if closedLidDraft { helperPreparation }
                        else {
                            Note(L("General keep-awake works without installing a helper. Closed-lid work needs separate preparation only when selected.",
                                   "일반 잠자기 방지는 도우미 설치 없이 사용합니다. 덮개 유지는 선택할 때만 별도 준비가 필요합니다."))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(setupAlreadyCompleted ? L("Saved choices", "저장된 선택") : L("Choose your settings", "설정 선택"))
                                .font(TetherTypography.section)
                            SettingsToggle(title: L("Automatic keep-awake", "자동 유지"),
                                detail: L("Selected power range: ", "선택한 전원 범위: ") + model.v3Settings.condition.title,
                                isOn: $automaticDraft)
                                .disabled(!choicesAvailable)
                                .accessibilityIdentifier("welcome-automatic-toggle")
                            if model.showsLidOptions || closedLidDraft {
                                SettingsToggle(title: L("Allow closed-lid work", "덮개 유지 허용"),
                                    detail: L("Whether to continue when the lid closes during active work.", "유지 중일 때 덮개를 닫아도 계속할지 정합니다."),
                                    isOn: $closedLidDraft)
                                    .disabled(!closedLidChoiceAvailable)
                                    .accessibilityIdentifier("welcome-closed-lid-toggle")
                            }
                            PolicyNote(selectionResult)
                                .accessibilityIdentifier("welcome-choice-result")
                            Note(model.showsLidOptions
                                ? L("These choices are independent. Closed-lid permission alone starts no work. Manual sessions remain available with automatic work off.",
                                    "두 선택은 독립적입니다. 덮개 허용만으로 시작하지 않으며, 자동 유지를 꺼도 수동 유지는 가능합니다.")
                                : L("Manual sessions remain available with automatic work off. Completing setup with automatic off starts no work.",
                                    "자동 유지를 꺼도 수동 유지는 가능합니다. 자동을 끄고 준비를 완료하면 유지가 시작되지 않습니다."))
                        }
                        Divider()
                        SettingRow(title: L("Saved choices", "저장된 선택")) {
                            Text(savedSummary).foregroundStyle(Color.tetherSecondary)
                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                        }
                        SettingRow(title: L("Running now", "지금 실행")) {
                            Text(model.workSessionHolding ? L("Keeping work awake", "작업 유지 중") : L("No active work", "실행 중인 유지 없음"))
                                .foregroundStyle(Color.tetherSecondary)
                        }
                        Note(setupAlreadyCompleted
                            ? L("Existing automatic choices and work remain unchanged. You may turn closed-lid work off here to continue without preparing its helper. Authentication alone starts no work.",
                                "기존 자동 선택과 작업은 보존합니다. 여기서 덮개 유지를 끄면 도우미 준비 없이 일반 유지로 계속할 수 있습니다. 인증만으로 시작하지 않습니다.")
                            : L("Finish saves the selected choices. Confirming automatic on can start work when current conditions allow. Authentication alone starts nothing.",
                                "완료하면 선택을 저장합니다. 자동을 켜서 확인 적용하면 현재 조건에 따라 유지가 시작될 수 있습니다. 인증만으로 시작하지 않습니다."))
                        if model.hasInternalBattery {
                            PolicyNote(model.disconnectPolicyDetail)
                        }
                    } else {
                        PolicyNote(L("Tether requires Apple Silicon and macOS 26 or later.", "Tether는 Apple Silicon과 macOS 26 이상이 필요합니다."))
                    }
                    if let applyError { Note(applyError, color: .tetherError) }
                }.padding(20)
            }.scrollEdgeEffectHidden(true, for: .top)
            Divider()
            HStack {
                if !canConfirmChoices {
                    Text(L("Prepare the selected closed-lid option first", "선택한 덮개 유지 준비를 먼저 완료하세요"))
                        .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                }
                Spacer(minLength: 8)
                Button(setupAlreadyCompleted ? L("Finish preparation check", "준비 확인 완료") : L("Confirm and finish", "확인하고 완료")) {
                    if model.finishOnboarding(automaticEnabled: automaticDraft,
                                              allowClosedLid: closedLidDraft) {
                        done()
                    } else {
                        applyError = L("Could not apply the choices. Review setup and try again.", "선택을 적용하지 못했습니다. 준비 상태를 확인한 뒤 다시 시도하세요.")
                    }
                }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(!canConfirmChoices || model.commandPending || model.helperInstallInFlight)
                    .accessibilityIdentifier("welcome-confirm-choices")
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }.frame(width: 560, height: 448)
            .font(TetherTypography.body).foregroundStyle(Color.tetherPrimary)
            .background(Color.tetherBackground)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("welcome-content")
    }

    private var setupAlreadyCompleted: Bool { model.defaults.bool(forKey: "onboarded") }
    private var canConfirmChoices: Bool {
        model.canFinishOnboarding(allowClosedLid: closedLidDraft)
    }
    private var choicesAvailable: Bool {
        !setupAlreadyCompleted && model.supportedMac
            && !model.helperInstallInFlight && !model.commandPending
    }
    private var closedLidChoiceAvailable: Bool {
        if !setupAlreadyCompleted { return choicesAvailable }
        // An existing lid user may explicitly opt out without enabling any new
        // permission. Automatic choices stay read-only during preparation.
        return model.supportedMac && model.v3Settings.allowClosedLid
            && !model.helperInstallInFlight && !model.commandPending
    }
    private var savedSummary: String {
        let automatic = model.v3Settings.automaticEnabled
            ? model.v3Settings.condition.title + " · " + L("Automatic on", "자동 켬")
            : L("Automatic off", "자동 끔")
        guard model.showsLidOptions else { return automatic }
        return automatic + " · " + (model.v3Settings.allowClosedLid ? L("Lid allowed", "덮개 허용") : L("Lid off", "덮개 끔"))
    }
    private var selectionResult: String {
        guard model.showsLidOptions else {
            return automaticDraft ? model.v3Settings.condition.title + " · " + L("General keep-awake", "일반 작업 유지") : L("Wait for a manual start", "수동 시작 대기")
        }
        switch (automaticDraft, closedLidDraft) {
        case (false, false): return L("Selection: wait; no automatic work", "선택 결과: 대기 · 자동 유지 없음")
        case (true, false): return L("Selection: general automatic work; closed-lid work off", "선택 결과: 일반 자동 유지 · 닫힘 유지 안 함")
        case (false, true): return L("Selection: automatic waits; manual work may use the closed lid", "선택 결과: 자동 대기 · 수동 유지 시 덮개 사용 가능")
        case (true, true): return L("Selection: automatic work may continue with the lid closed", "선택 결과: 자동 유지 중 닫힘 작업 유지 가능")
        }
    }
    private var helperPreparation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Required for closed-lid work", "덮개 유지에 필요한 도우미"))
                Spacer(minLength: 8)
                if model.helperSetupConfirmed {
                    Text(L("Ready", "준비됨")).foregroundStyle(Color.tetherSecondary)
                } else {
                    Button(model.helperInstallInFlight ? L("Waiting…", "인증 대기…") : L("Prepare…", "준비…")) { model.installHelper() }
                        .actionButton(prominent: true)
                        .disabled(model.helperInstallInFlight || model.userCommandsArePreview || model.developmentService || model.isTranslocated)
                }
            }.frame(minHeight: 30)
            Note(L("Closed-lid work requires administrator-approved preparation. Turn this option off to use general work without it. Preparing the helper enables neither choice and starts no session.",
                   "덮개 유지를 쓰려면 관리자 인증으로 준비해야 합니다. 이 선택을 끄면 일반 유지는 도우미 없이 사용할 수 있습니다. 준비만으로 선택이 켜지거나 유지가 시작되지 않습니다."))
            if model.isTranslocated { Note(L("Move Tether to Applications and reopen it.", "Tether를 응용 프로그램으로 옮기고 다시 여세요.")) }
            if let error = model.errorText { Note(error, color: .tetherError) }
        }
    }
}

/// The welcome content without its window, for `--render-welcome`.
struct WelcomePreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        WelcomeView(model: model) {}
    }
}
