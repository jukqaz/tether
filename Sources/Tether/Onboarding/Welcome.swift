import AppKit
import SwiftUI
import TetherCore

/// Mandatory notebook setup; desktops finish without installing a lid helper.
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
                        if model.requiresHelperSetup { helperPreparation }
                        else if model.capabilities.hardware == .desktop {
                            Note(L("Desktop Macs use general AC keep-awake without a separate helper.",
                                   "데스크톱 Mac은 별도 도우미 설치 없이 AC 일반 유지를 사용합니다."))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(setupAlreadyCompleted ? L("Saved choices", "저장된 선택") : L("Choose your settings", "설정 선택"))
                                .font(TetherTypography.section)
                            SettingsToggle(title: L("AC automatic", "AC 자동 유지"),
                                detail: L("When to keep working while power is connected.", "전원이 연결됐을 때 언제 유지할지 정합니다."),
                                isOn: $automaticDraft)
                                .disabled(!choicesAvailable)
                                .accessibilityIdentifier("welcome-automatic-toggle")
                            if model.showsLidOptions {
                                SettingsToggle(title: L("Allow closed-lid work", "덮개 유지 허용"),
                                    detail: L("Whether to continue when the lid closes during active work.", "유지 중일 때 덮개를 닫아도 계속할지 정합니다."),
                                    isOn: $closedLidDraft)
                                    .disabled(!choicesAvailable)
                                    .accessibilityIdentifier("welcome-closed-lid-toggle")
                            }
                            PolicyNote(selectionResult)
                                .accessibilityIdentifier("welcome-choice-result")
                            Note(model.showsLidOptions
                                ? L("These choices are independent. Closed-lid permission alone starts no work. Manual sessions remain available with AC automatic off.",
                                    "두 선택은 독립적입니다. 덮개 허용만으로 시작하지 않으며, AC 자동을 꺼도 수동 유지는 가능합니다.")
                                : L("Manual sessions remain available with AC automatic off. Completing setup alone starts no work.",
                                    "AC 자동을 꺼도 수동 유지는 가능합니다. 준비 완료만으로 유지가 시작되지 않습니다."))
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
                            ? L("Existing choices are preserved. Change them in Settings. Finishing this preparation check does not reapply automatic work or start a manual session.",
                                "기존 선택을 보존합니다. 변경은 설정에서 하세요. 준비 확인을 완료해도 자동을 다시 적용하거나 수동을 시작하지 않습니다.")
                            : L("Finish saves the selected choices. Confirming AC automatic on can start work when current conditions allow. Authentication alone starts nothing.",
                                "완료하면 선택을 저장합니다. AC 자동을 켜서 확인 적용하면 현재 조건에 따라 유지가 시작될 수 있습니다. 인증만으로 시작하지 않습니다."))
                        if model.hasInternalBattery {
                            PolicyNote(L("Unplugging always ends existing Tether sessions.", "전원을 분리하면 기존 Tether 유지는 항상 종료합니다."))
                        }
                    } else {
                        PolicyNote(L("Tether requires Apple Silicon and macOS 26 or later.", "Tether는 Apple Silicon과 macOS 26 이상이 필요합니다."))
                    }
                    if let applyError { Note(applyError, color: .tetherError) }
                }.padding(20)
            }.scrollEdgeEffectHidden(true, for: .top)
            Divider()
            HStack {
                if !model.canFinishOnboarding {
                    Text(L("Finish required setup first", "필수 준비를 먼저 완료하세요"))
                        .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                }
                Spacer(minLength: 8)
                Button(setupAlreadyCompleted ? L("Finish preparation check", "준비 확인 완료") : L("Confirm and finish", "확인하고 완료")) {
                    if model.finishOnboarding(automaticEnabled: automaticDraft,
                                              allowClosedLid: model.showsLidOptions && closedLidDraft) {
                        done()
                    } else {
                        applyError = L("Could not apply the choices. Review setup and try again.", "선택을 적용하지 못했습니다. 준비 상태를 확인한 뒤 다시 시도하세요.")
                    }
                }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(!model.canFinishOnboarding || model.commandPending)
                    .accessibilityIdentifier("welcome-confirm-choices")
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }.frame(width: 560, height: 448)
            .font(TetherTypography.body).foregroundStyle(Color.tetherPrimary)
            .background(Color.tetherBackground)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("welcome-content")
    }

    private var setupAlreadyCompleted: Bool { model.defaults.bool(forKey: "onboarded") }
    private var choicesAvailable: Bool {
        !setupAlreadyCompleted && model.supportedMac && (!model.requiresHelperSetup || model.helperSetupConfirmed)
            && !model.helperInstallInFlight && !model.commandPending
    }
    private var savedSummary: String {
        let automatic = model.v3Settings.automaticEnabled ? L("AC on", "AC 자동 켬") : L("AC off", "AC 자동 끔")
        guard model.showsLidOptions else { return automatic }
        return automatic + " · " + (model.v3Settings.allowClosedLid ? L("Lid allowed", "덮개 허용") : L("Lid off", "덮개 끔"))
    }
    private var selectionResult: String {
        guard model.showsLidOptions else {
            return automaticDraft ? L("On AC: general keep-awake", "AC에서 일반 작업 유지") : L("Wait for a manual start", "수동 시작 대기")
        }
        switch (automaticDraft, closedLidDraft) {
        case (false, false): return L("Selection: wait; no automatic work", "선택 결과: 대기 · 자동 유지 없음")
        case (true, false): return L("Selection: keep working on AC with the lid open", "선택 결과: AC에서 열린 작업 유지 · 닫힘 유지 안 함")
        case (false, true): return L("Selection: automatic waits; manual work may use the closed lid", "선택 결과: 자동 대기 · 수동 유지 시 덮개 사용 가능")
        case (true, true): return L("Selection: AC work may continue with the lid closed", "선택 결과: AC에서 닫힘 작업 유지 가능")
        }
    }
    private var helperPreparation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Required MacBook helper", "MacBook 필수 도우미"))
                Spacer(minLength: 8)
                if model.helperSetupConfirmed {
                    Text(L("Ready", "준비됨")).foregroundStyle(Color.tetherSecondary)
                } else {
                    Button(model.helperInstallInFlight ? L("Waiting…", "인증 대기…") : L("Prepare…", "준비…")) { model.installHelper() }
                        .actionButton(prominent: true)
                        .disabled(model.helperInstallInFlight || model.userCommandsArePreview || model.developmentService || model.isTranslocated)
                }
            }.frame(minHeight: 30)
            Note(L("Administrator approval is required before finishing MacBook setup. Preparing the helper enables neither choice and starts no session.",
                   "MacBook은 관리자 인증으로 도우미를 준비해야 완료할 수 있습니다. 준비만으로 두 선택이 켜지거나 유지가 시작되지 않습니다."))
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
