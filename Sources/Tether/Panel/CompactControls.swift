import SwiftUI
import TetherCore

/// The compact panel's controls: the battery hold and the temperature, then size, settings and more.
struct CompactControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            holdControl
            Label(model.temperatureValue, systemImage: "thermometer.medium")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(model.thermalColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(model.thermalColor.opacity(0.14), in: .capsule)
                .help(model.thermalLabel)
            Spacer(minLength: 0)
            FooterButtons(model: model, openSettings: { openSettings() }, dismiss: { dismiss() })
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var holdControl: some View {
        if model.batteryHoldUntil != nil {
            CompactHold(model: model, clock: model.clock)
        } else if model.helperInstalled, model.helperResponding {
            Menu {
                ForEach(model.holdChoices, id: \.self) { minutes in
                    Button(L("Battery hold ", "배터리 유지 ") + Texts.duration(TimeInterval(minutes * 60))) {
                        model.startBatteryHold(minutes: minutes)
                    }
                }
            } label: {
                Image(systemName: "bag")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .modifier(Orb(color: .orange, active: false))
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.enabled)
            .opacity(model.enabled ? 1 : 0.45)
            .help(L("Battery hold", "배터리에서도 유지"))
            .accessibilityLabel(L("Battery hold", "배터리 유지"))
        }
    }
}
