import SwiftUI
import TetherCore

/// The current state and persistent master switch for the selected power condition.
struct StateModule: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        let p = model.presentation
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateIcon(icon: p.icon, size: compact ? 14 : 16)
                    .foregroundStyle(p.color)
                    .frame(width: 24, height: 20)
                    .accessibilityHidden(true)
                Text(p.title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if model.helperInstalled || model.usesUserSession {
                    Toggle("Tether", isOn: Binding(
                        get: { model.tetherEnabled }, set: { model.setEnabled($0) }))
                        .disabled(model.commandPending || !model.sessionAvailable)
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .tint(Color.tetherAccent)
                        .help(L("Keep work running under the selected power condition. Turning this off stays off until you turn it on again.",
                                "선택한 전원 조건에서 잠자기를 방지합니다. 끄면 다시 켤 때까지 적용하지 않습니다."))
                }
            }
            Text(p.subtitle)
                .font(.system(size: 12)).lineSpacing(2)
                .foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32)
            DisplaySleepNotice(model: model)
                .padding(.leading, 32)
            ClamshellLockNotice(model: model)
                .padding(.leading, 32)
        }
        .padding(compact ? Metrics.compactPadding : Metrics.padding)
        .surface(tint: p.color, strength: 0.12, radius: compact ? Metrics.compactRadius : Metrics.radius)
        .animation(reduceMotion ? nil : .snappy, value: p.title)
    }
}
