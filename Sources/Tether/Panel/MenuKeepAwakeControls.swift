import SwiftUI
import TetherCore

/// Shared wording for the app-wide gates, separate from a future request's defaults.
enum WorkPermissionText {
    static var displayTitle: String { L("Allow display keep-awake", "화면 켜두기 허용") }
    static var lidTitle: String { L("Allow closed-lid work", "덮개 유지 허용") }
    static var scopeDetail: String {
        L("Changes save immediately for current and future work that requests these features. Permissions do not start work.",
          "변경 즉시 저장되어 해당 기능을 요청한 현재·다음 작업에 적용됩니다. 허용만으로 작업을 시작하지는 않습니다.")
    }
    static var displayHelp: String {
        L("App-wide permission, saved immediately. Applies only when work requests display keeping. macOS lock policy still applies.",
          "앱 전체 허용이며 변경 즉시 저장됩니다. 화면 유지를 요청한 작업에만 적용하며 잠금은 macOS 설정을 따릅니다.")
    }
    static var lidHelp: String {
        L("App-wide permission, saved immediately. Applies only when work requests closed-lid use; it does not start work.",
          "앱 전체 허용이며 변경 즉시 저장됩니다. 덮개 유지를 요청한 작업에만 적용하며 새 작업을 시작하지는 않습니다.")
    }
}

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

/// Quick access to the same permissions used by Power & Lid. Selecting a
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
                    Toggle(WorkPermissionText.lidTitle, isOn: lidBinding)
                        .fixedSize(horizontal: false, vertical: true).disabled(lidControlDisabled)
                        .accessibilityIdentifier("panel-allow-closed-lid")
                    Spacer(minLength: 4)
                    if !model.helperSetupConfirmed {
                        Button(L("Set up…", "준비…"), action: openHelperSetup)
                            .buttonStyle(.link).font(TetherTypography.secondary).fixedSize()
                            .accessibilityIdentifier("panel-prepare-lid-helper")
                    }
                }
                .help(WorkPermissionText.lidHelp)
            }
            if model.showsLidOptions, model.v3Settings.allowClosedLid {
                Text(lidStatusDetail).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-lid-status")
            }
            option(WorkPermissionText.displayTitle, selection: displayBinding,
                   identifier: "panel-keep-display-awake")
                .disabled(controlsDisabled)
                .help(WorkPermissionText.displayHelp)
            if model.v3Settings.keepDisplayAwake {
                Text(displayStatusDetail)
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-display-status")
            }
        }
        .font(TetherTypography.body)
        .toggleStyle(.checkbox).tint(.tetherAction).controlSize(.small)
    }

    private func option(_ title: String, selection: Binding<Bool>, identifier: String) -> some View {
        Toggle(title, isOn: selection)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    var lidStatusDetail: String {
        if model.lidReleasePending { return model.lidSupportSummary }
        if model.workSessionHolding, model.userSession?.v4LidRequested == false {
            return L("This work does not request closed-lid use", "현재 작업은 덮개 유지를 요청하지 않음")
        }
        if !model.workSessionHolding, model.helperSetupConfirmed {
            return L("Applies when work requests closed-lid use", "작업에서 덮개 유지를 요청할 때 적용")
        }
        return model.lidSupportSummary
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
