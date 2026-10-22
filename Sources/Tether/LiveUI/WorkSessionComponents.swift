import SwiftUI
import TetherCore

enum WorkSessionMetrics {
    static let panelWidth: CGFloat = 300
    static let panelMaximumHeight: CGFloat = 606
    static let panelInset: CGFloat = 15
    static let modulePadding: CGFloat = 10
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 8
    static let settingsMinimum = CGSize(width: 560, height: 480)
    static let pageInset: CGFloat = 20
    static func panelHeightLimit(visibleHeight: CGFloat) -> CGFloat {
        min(panelMaximumHeight, max(202, visibleHeight - 32))
    }
}

/// Optional rendering injection for safe snapshots. Live windows read macOS accessibility values.
private struct WorkSessionReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
private struct WorkSessionContrastKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}
extension EnvironmentValues {
    var tetherReduceTransparencyOverride: Bool? {
        get { self[WorkSessionReduceTransparencyKey.self] }
        set { self[WorkSessionReduceTransparencyKey.self] = newValue }
    }
    var tetherContrastOverride: ColorSchemeContrast? {
        get { self[WorkSessionContrastKey.self] }
        set { self[WorkSessionContrastKey.self] = newValue }
    }
}

struct WorkSessionNote: View {
    let title: String
    var detail: String? = nil
    var symbol = "info.circle"
    var color: Color = .secondary
    var detailLineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TetherTypography.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail).font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
                        .lineLimit(detailLineLimit)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct WorkSessionRow: View {
    let title: String
    let value: String
    var symbol: String?

    var body: some View {
        LabeledContent {
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            if let symbol {
                Label(title, systemImage: symbol).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(title).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(TetherTypography.body).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct WorkSessionStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock
    var compact = false

    var body: some View {
        WorkSessionHeading(model: model, clock: clock, compact: compact)
    }
}

struct WorkSessionHeading: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .top : .center, spacing: compact ? 6 : 10) {
            if compact {
                Circle().fill(model.presentation.color)
                    .frame(width: 6, height: 6)
                    .frame(width: 10, height: 18)
                    .accessibilityHidden(true)
            } else {
                StateIcon(icon: model.presentation.icon, size: 17)
                    .foregroundStyle(model.presentation.color).frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                Text(model.presentation.title).font(compact ? TetherTypography.status : TetherTypography.page)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        .lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                        .help(detail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.presentation.title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(.isHeader)
    }

    private var detail: String? {
        if compact, model.workSessionHolding, model.problem == nil, model.workProtectionReason == nil {
            // The header explains the reason; each session's own row owns its countdown.
            if model.automaticWorkReasonActive, model.manualSessionActive {
                return L("Automatic and manual sessions", "자동·수동 유지")
            }
            if model.automaticWorkReasonActive {
                return nil
            }
            if model.manualSessionActive {
                return L("Manually started session", "직접 시작한 수동 유지")
            }
        }
        if model.workSessionHolding, model.manualSessionActive, !model.automaticWorkReasonActive,
           model.problem == nil, model.workProtectionReason == nil { return nil }
        return model.activeWorkReasonSummary(at: clock.now, includesManualCountdown: false) ?? model.presentation.subtitle
    }
}

struct WorkSessionStopButton: View {
    @ObservedObject var model: AppModel
    var fullWidth = false
    var compact = false
    private var resumesWork: Bool { model.workPaused }

    var body: some View {
        Button {
            model.setEnabled(resumesWork)
        } label: {
            Label(resumesWork ? L("Resume automatic rules", "자동 조건 재개")
                    : L("Stop all", "모두 중지"),
                systemImage: resumesWork ? "play.fill" : "pause.fill")
                .font(TetherTypography.body.weight(.medium))
                .foregroundStyle(Color.tetherPrimary)
                .padding(.vertical, compact ? 0 : 1)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .actionButton()
        .controlSize(compact ? .small : .regular)
        .accessibilityIdentifier("panel-pause-all")
        .foregroundStyle(.primary)
        .help(actionHint)
        .accessibilityHint(actionHint)
        .disabled(!model.sessionAvailable || model.commandPending || (resumesWork && !model.canResumeWork))
    }

    private var actionHint: String {
        return model.workPaused
            ? L("Allow work again. Enabled automatic rules can resume; ended manual sessions do not restart.", "작업을 다시 허용합니다. 켜 둔 자동 조건은 다시 적용하며, 끝난 수동 유지는 다시 시작하지 않습니다.")
            : L("End manual work and pause automatic triggers until you resume.", "수동 유지를 끝내고, 다시 시작할 때까지 자동 유지도 멈춥니다.")
    }
}
