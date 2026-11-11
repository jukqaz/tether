import SwiftUI
import TetherCore

/// Shared wording for the app-wide gates, separate from a future request's defaults.
enum WorkPermissionText {
    static var displayTitle: String { L("Allow display keep-awake", "화면 켜두기 허용") }
    static var lidTitle: String { L("Allow closed-lid use", "덮개 닫고 사용 허용") }
    static var scopeDetail: String {
        L("Saved immediately. Applies to basic automatic work; advanced automatic and manual work use their selected features. Allowing a feature does not start keep-awake.",
          "즉시 저장됩니다. 기본 자동 유지에 적용하며, 고급 자동·수동 유지는 선택한 기능에만 적용합니다. 허용만으로 유지를 시작하지 않습니다.")
    }
    static var displayHelp: String {
        L("Saved immediately. Applies to basic automatic work and sessions with display keep-awake selected. Locking follows macOS settings.",
          "즉시 저장됩니다. 기본 자동 유지와 화면 켜두기를 선택한 유지에 적용하며, 잠금은 macOS 설정을 따릅니다.")
    }
    static var lidHelp: String {
        L("Saved immediately. Applies to basic automatic work and sessions with closed-lid use selected; it does not start keep-awake.",
          "즉시 저장됩니다. 기본 자동 유지와 덮개 닫고 사용을 선택한 유지에 적용하며, 유지를 시작하지는 않습니다.")
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
    var canEdit = true
    var openHelperSetup: () -> Void = {}

    var controlsDisabled: Bool { !canEdit || !model.acceptingUserCommands || model.commandPending }
    var lidAvailability: LidOptionAvailability { LidOptionAvailability(model: model) }
    var lidControlDisabled: Bool { !canEdit || lidAvailability.isDisabled }

    var displayBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.keepDisplayAwake }, set: { value in
            guard !controlsDisabled else { return }
            model.setKeepDisplayAwake(value)
        })
    }

    var lidBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.allowClosedLid }, set: { value in
            guard canEdit && lidAvailability.permits(value) else { return }
            model.setAllowClosedLid(value)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showsLidOptions {
                VStack(alignment: .leading, spacing: 4) {
                    option(WorkPermissionText.lidTitle, selection: lidBinding,
                           identifier: "panel-allow-closed-lid")
                        .disabled(lidControlDisabled)
                        .help(WorkPermissionText.lidHelp)
                    permissionDetail(lidStatusDetail)
                        .accessibilityIdentifier("panel-lid-status")
                    if canEdit && !model.helperSetupConfirmed {
                        Button(L("Set up…", "도우미 설정…"), action: openHelperSetup)
                            .buttonStyle(.link)
                            .font(TetherTypography.secondary)
                            .padding(.leading, 22)
                            .accessibilityIdentifier("panel-prepare-lid-helper")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                option(WorkPermissionText.displayTitle, selection: displayBinding,
                       identifier: "panel-keep-display-awake")
                    .disabled(controlsDisabled)
                    .help(WorkPermissionText.displayHelp)
                permissionDetail(displayStatusDetail)
                    .accessibilityIdentifier("panel-display-status")
            }
        }
        .font(TetherTypography.body)
        .toggleStyle(.checkbox).tint(.tetherAction).controlSize(.regular)
    }

    private func permissionDetail(_ text: String) -> some View {
        Text(text)
            .font(TetherTypography.secondary)
            .foregroundStyle(Color.tetherSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 22)
    }

    private func option(_ title: String, selection: Binding<Bool>, identifier: String) -> some View {
        Toggle(isOn: selection) {
            Text(title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
    }

    var lidStatusDetail: String {
        model.lidUsageStatusText
    }

    var displayStatusDetail: String {
        model.displayUsageStatusText
    }
}
