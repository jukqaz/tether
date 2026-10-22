import SwiftUI
import TetherCore

/// Separate manual controls from the automatic trigger's existing battery countdown.
struct CompactControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            if model.sessionAvailable {
                ManualSessionControls(model: model, clock: model.clock, compact: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    holdControl.fixedSize()
                    Spacer(minLength: 8)
                    temperature.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    holdControl
                    temperature.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text(model.sessionConditionTitle).font(.system(size: 11)).foregroundStyle(Color.tetherSecondary)
                Spacer(minLength: 8)
                FooterButtons(model: model, openSettings: {
                    if model.developmentService { model.settingsPage = .general } else { openSettings() }
                }, dismiss: { dismiss() })
            }
        }
        .padding(.horizontal, 4)
    }

    private var temperature: some View {
        Label(model.temperatureValue, systemImage: "thermometer.medium")
            .font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(Color.tetherSecondary).help(model.thermalLabel)
    }

    @ViewBuilder
    private var holdControl: some View {
        if !model.usesUserSession, let minutes = model.pendingHoldMinutes {
            HStack(spacing: 6) {
                Label(L("Unplug · \(minutes)m", "전원 분리 대기 · \(minutes)분"), systemImage: "powerplug")
                    .font(.callout)
                Button { model.cancelBatteryHold() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 24, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Cancel battery hold reservation", "예약 취소"))
                .help(L("Cancel battery hold reservation", "예약 취소"))
            }
        } else if !model.usesUserSession && model.batteryHoldUntil != nil {
            CompactHold(model: model, clock: model.clock)
        }
    }
}
