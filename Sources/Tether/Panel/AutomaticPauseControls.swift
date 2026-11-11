import SwiftUI
import TetherCore

/// Both surfaces edit the same automatic-only gate. No timer or global stop is resumed here.
struct AutomaticPauseControls: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        if model.automaticEnabled {
            if model.automaticPauseActive {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pauseSummary).font(TetherTypography.secondary)
                        .foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("automatic-pause-summary")
                    Button { _ = model.resumeAutomatic() } label: {
                        Label(L("Resume automatic", "자동 재개"), systemImage: "play")
                    }
                        .buttonStyle(.link).font(TetherTypography.body)
                        .frame(minHeight: 30, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("automatic-pause-resume")
                        .help(L("Recheck automatic conditions. Stop all and protection are not cleared.",
                                "자동 조건을 다시 확인합니다. 모두 중지나 보호 차단은 해제하지 않습니다."))
                        .disabled(controlsDisabled || model.workPaused || model.workProtectionReason != nil)
                }
            } else {
                HStack(spacing: 8) {
                    if !compact {
                        Text(L("Pause automatic only", "자동만 일시 중지"))
                            .font(TetherTypography.body)
                        Spacer(minLength: 8)
                    }
                    Menu {
                        Button(L("For 30 minutes", "30분 동안")) { _ = model.pauseAutomatic(for: 1800) }
                        Button(L("For 1 hour", "1시간 동안")) { _ = model.pauseAutomatic(for: 3600) }
                        Divider()
                        Button(L("Until I resume", "직접 재개할 때까지")) { _ = model.pauseAutomatic(for: nil) }
                    } label: {
                        if compact {
                            Label(L("Pause automatic only…", "자동만 일시 중지…"), systemImage: "pause")
                        } else {
                            Text(L("Choose…", "시간 선택…"))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(TetherTypography.body)
                    .controlSize(.regular)
                    .frame(minHeight: 30, alignment: .leading)
                    .accessibilityIdentifier("automatic-pause-menu")
                    .accessibilityHint(L("Manual keep-awake keeps its original end time. Saved automatic rules stay enabled.",
                                         "수동 유지의 종료 시각과 저장된 자동 시작 설정은 바뀌지 않습니다."))
                    .disabled(controlsDisabled || model.workPaused || model.workProtectionReason != nil)
                    if compact { Spacer(minLength: 0) }
                }
            }
        }
    }

    var pauseSummary: String {
        if let until = model.automaticPauseUntil {
            return L("Automatic starts paused until \(Texts.time(until))", "\(Texts.time(until))까지 자동 시작만 일시 중지합니다")
        }
        return L("Automatic starts paused until you resume", "직접 재개할 때까지 자동 시작만 일시 중지합니다")
    }

    private var controlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
}
