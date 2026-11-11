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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(setupAlreadyCompleted
                                ? L("Check setup", "준비 상태 확인")
                                : L("Choose your starting options", "기본 동작 선택"))
                                .font(TetherTypography.page)
                            Note(setupAlreadyCompleted
                                ? L("Review your saved choices.", "저장된 선택을 확인하세요.")
                                : L("You can change these choices later in Settings.", "선택은 나중에 설정에서 바꿀 수 있습니다."))
                        }
                        Spacer(minLength: 0)
                        if model.userCommandsArePreview { PreviewIndicator() }
                    }
                    if model.supportedMac {
                        SettingsToggle(title: model.v4Settings.automaticMode == .advanced
                            ? L("Allow automatic start", "자동 시작 허용")
                            : L("Start automatically on power", "전원을 연결하면 자동 유지"),
                            isOn: $automaticDraft)
                            .disabled(!choicesAvailable)
                            .accessibilityIdentifier("welcome-automatic-toggle")
                        if showsClosedLidChoice {
                            SettingsToggle(title: L("Allow closed-lid use", "덮개 닫고 사용 허용"),
                                detail: model.capabilities.lidControlAvailable
                                    ? L("Requires a helper on MacBooks.", "MacBook에서는 도우미가 필요합니다.")
                                    : L("This Mac’s lid support hasn’t been confirmed.", "이 Mac의 덮개 기능 지원 여부를 확인하지 못했습니다."),
                                isOn: $closedLidDraft)
                                .disabled(!closedLidChoiceAvailable)
                                .accessibilityIdentifier("welcome-closed-lid-toggle")
                        }
                        if closedLidDraft && model.capabilities.lidControlAvailable { helperPreparation }
                        choiceResults
                    } else {
                        PolicyNote(L("Tether requires Apple Silicon and macOS 26 or later.", "Tether는 Apple Silicon과 macOS 26 이상이 필요합니다."))
                    }
                    if let applyError { Note(applyError, color: .tetherError) }
                }.padding(.horizontal, 24).padding(.vertical, 18)
            }.scrollEdgeEffectHidden(true, for: .top)
            Divider()
            HStack(spacing: 12) {
                Label(L("Locking follows macOS settings.", "잠금은 macOS 설정을 따릅니다."), systemImage: "lock")
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(setupAlreadyCompleted ? L("Finish preparation check", "준비 확인 완료") : L("Save and Finish", "저장하고 완료")) {
                    if model.finishOnboarding(automaticEnabled: automaticDraft,
                                              allowClosedLid: closedLidDraft) {
                        done()
                    } else {
                        applyError = L("Could not apply the choices. Review setup and try again.", "선택을 적용하지 못했습니다. 준비 상태를 확인한 뒤 다시 시도하세요.")
                    }
                }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(!canConfirmChoices || model.commandPending || model.helperInstallInFlight)
                    .accessibilityIdentifier("welcome-confirm-choices")
            }.padding(.horizontal, 24).padding(.vertical, 12).background(Color.tetherBackground)
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
    private var showsClosedLidChoice: Bool { model.showsLidOptions || closedLidDraft }
    private var closedLidChoiceAvailable: Bool {
        if !setupAlreadyCompleted {
            return choicesAvailable && (model.capabilities.lidControlAvailable || closedLidDraft)
        }
        // An existing lid user may explicitly opt out without enabling any new
        // permission. Automatic choices stay read-only during preparation.
        return model.supportedMac && model.v3Settings.allowClosedLid
            && !model.helperInstallInFlight && !model.commandPending
    }
    private var choiceResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Start or end manual keep-awake from the menu bar.", "메뉴바에서 수동 유지를 시작·종료할 수 있습니다."))
                .font(TetherTypography.secondary.weight(.medium))
            choiceResult(L("Automatic", "자동 유지"), automaticResult)
                .accessibilityIdentifier("welcome-automatic-result")
            if showsClosedLidChoice {
                choiceResult(L("Lid closed", "덮개 닫힘"), closedLidResult)
                    .accessibilityIdentifier("welcome-closed-lid-result")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-choice-result")
    }

    private func choiceResult(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(TetherTypography.secondary.weight(.medium))
                .frame(width: 80, alignment: .leading)
            Note(detail)
        }
        .accessibilityElement(children: .combine)
    }

    private var automaticResult: String {
        if setupAlreadyCompleted {
            return L("Your automatic settings stay as saved.", "저장한 자동 설정을 유지합니다.")
        }
        guard automaticDraft else {
            return L("Keep-awake won’t start automatically.", "자동으로 유지를 시작하지 않습니다.")
        }
        return model.v4Settings.automaticMode == .advanced
            ? L("Starts when the saved conditions and protection checks allow.", "저장한 조건과 보호 기준을 충족하면 시작합니다.")
            : L("Starts on power when this Mac is awake and protection allows.", "깨어 있는 Mac에서 전원이 연결되고 보호 중이 아니면 시작합니다.")
    }

    private var closedLidResult: String {
        guard closedLidDraft else {
            return L("Lid behavior follows macOS.", "덮개 닫힘은 macOS에 맡깁니다.")
        }
        guard model.capabilities.lidControlAvailable else {
            return L("Turn off closed-lid use to finish without it.", "이 기능 없이 완료하려면 덮개 사용 허용을 끄세요.")
        }
        guard model.helperSetupConfirmed else {
            return L("Prepare the helper before saving this choice.", "이 선택을 저장하려면 먼저 도우미를 준비하세요.")
        }
        return L("Allows closed-lid use during eligible keep-awake sessions.", "조건을 충족하는 유지에서 덮개를 닫고 사용할 수 있습니다.")
    }
    private var helperPreparation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Closed-lid helper", "덮개 사용 도우미"))
                Spacer(minLength: 8)
                if model.helperSetupConfirmed {
                    Text(L("Ready", "준비됨")).foregroundStyle(Color.tetherSecondary)
                } else {
                    Button(model.helperInstallInFlight ? L("Waiting…", "인증 대기…") : L("Prepare…", "준비…")) { model.installHelper() }
                        .actionButton(prominent: true)
                        .disabled(model.helperInstallInFlight || model.userCommandsArePreview || model.developmentService || model.isTranslocated)
                }
            }.frame(minHeight: 30)
            if !model.helperSetupConfirmed {
                Note(L("Requires macOS administrator approval. Setup alone does not start keep-awake.",
                       "macOS 관리자 인증이 필요합니다. 준비만으로 유지를 시작하지 않습니다."))
            }
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
