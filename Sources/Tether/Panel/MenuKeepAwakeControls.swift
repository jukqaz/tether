import SwiftUI
import TetherCore

/// Helper readiness is required to grant lid permission, never to revoke a
/// saved grant. Both settings and the menu use this presentation-only guard.
struct LidOptionAvailability {
    let showsLidOptions: Bool
    let acceptingUserCommands: Bool
    let commandPending: Bool
    let isSelected: Bool
    let helperSetupConfirmed: Bool

    private var commandsAvailable: Bool {
        showsLidOptions && acceptingUserCommands && !commandPending
    }
    var isDisabled: Bool { !commandsAvailable || (!isSelected && !helperSetupConfirmed) }
    func permits(_ selected: Bool) -> Bool {
        commandsAvailable && (!selected || helperSetupConfirmed)
    }
}

extension LidOptionAvailability {
    @MainActor
    init(model: AppModel) {
        self.init(showsLidOptions: model.showsLidOptions,
                  acceptingUserCommands: model.acceptingUserCommands,
                  commandPending: model.commandPending,
                  isSelected: model.v3Settings.allowClosedLid,
                  helperSetupConfirmed: model.helperSetupConfirmed)
    }
}

/// Quick access to the same permissions used by General Settings. Selecting a
/// permission never clears a stop/protection latch or starts a new work request.
struct MenuKeepAwakeControls: View {
    @ObservedObject var model: AppModel
    var openHelperSetup: () -> Void = {}

    var controlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    var lidAvailability: LidOptionAvailability { LidOptionAvailability(model: model) }
    var lidControlDisabled: Bool { lidAvailability.isDisabled }

    var displayBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.keepDisplayAwake }, set: { value in
            guard !controlsDisabled else { return }
            model.setKeepDisplayAwake(value)
        })
    }

    var lidBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.allowClosedLid }, set: { value in
            guard lidAvailability.permits(value) else { return }
            model.setAllowClosedLid(value)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.showsLidOptions {
                HStack(spacing: 8) {
                    Text(L("Keep awake with lid closed", "덮개를 닫아도 계속 사용"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !model.helperSetupConfirmed {
                        Button(L("Set up…", "준비…"), action: openHelperSetup)
                            .buttonStyle(.link).font(TetherTypography.secondary).fixedSize()
                            .accessibilityIdentifier("panel-prepare-lid-helper")
                    }
                    Toggle(L("Keep awake with lid closed", "덮개를 닫아도 계속 사용"), isOn: lidBinding)
                        .labelsHidden().fixedSize().disabled(lidControlDisabled)
                        .accessibilityLabel(L("Keep awake with lid closed", "덮개를 닫아도 계속 사용"))
                        .accessibilityIdentifier("panel-allow-closed-lid")
                }
                .help(L("Applies to current and future work; does not start work by itself.",
                        "현재와 다음 유지에 적용하며, 이 옵션만으로 새 유지를 시작하지 않습니다."))
            }
            option(L("Keep display awake", "덮개가 열려 있을 때 화면 켜두기"), selection: displayBinding,
                   identifier: "panel-keep-display-awake")
                .disabled(controlsDisabled)
                .help(L("Applies during work. macOS password requirements still apply; Tether never unlocks the Mac.",
                        "유지 중인 작업에 적용합니다. macOS의 암호 요구는 계속 적용하며 잠긴 Mac을 해제하지 않습니다."))
            if model.v3Settings.keepDisplayAwake {
                Text(displayStatusDetail)
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-display-status")
            }
        }
        .font(TetherTypography.body)
        .toggleStyle(.switch).tint(.tetherAction).controlSize(.small)
    }

    private func option(_ title: String, selection: Binding<Bool>, identifier: String) -> some View {
        HStack(spacing: 8) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Toggle(title, isOn: selection).labelsHidden().fixedSize()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    var displayStatusDetail: String {
        if !model.v3Settings.keepDisplayAwake {
            return L("Display sleep follows macOS", "화면 절전은 macOS에 맡김")
        }
        if model.userSessionStatus?.displayError != nil {
            return L("Display keep-awake needs review", "화면 유지 확인 필요")
        }
        if model.userSessionStatus?.displayHolding == true {
            return L("Display kept awake · macOS lock policy applies", "화면 유지 중 · 잠금은 macOS 설정")
        }
        if model.workPaused {
            return L("Choice saved · work is stopped", "선택 저장됨 · 작업은 중지 중")
        }
        if !model.workSessionHolding {
            return L("Applies when work starts", "작업이 시작되면 적용")
        }
        return model.userSessionStatus?.displayHolding == nil
            ? L("Checking display keep-awake", "화면 유지 상태 확인 중")
            : L("Enabled · not currently applied", "선택 켬 · 현재 화면 유지는 미적용")
    }
}
