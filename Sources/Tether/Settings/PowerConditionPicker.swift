import SwiftUI
import TetherCore

/// Available power rules, with the consequence beside each choice.
struct PowerConditionPicker: View {
    @Binding var selection: PowerCondition
    var choices: [PowerCondition] = PowerCondition.allCases
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if choices.count > 1 {
                Picker(L("Automatic session condition", "자동 유지 조건"), selection: $selection) {
                    ForEach(choices) { condition in Text(title(condition)).tag(condition) }
                }
                .pickerStyle(.segmented).labelsHidden()
            } else if let condition = choices.first {
                if selection == condition {
                    Label(title(condition), systemImage: "powerplug")
                        .font(.callout.weight(.medium))
                } else {
                    Text(selection.title).font(.callout.weight(.medium))
                    Button(L("Use the power-connected condition", "전원 연결 조건으로 변경")) { selection = condition }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("automatic-power-condition-recover-ac")
                }
            }
            if choices.count > 1 { Note(detail(selection)) }
        }
        .accessibilityElement(children: .contain)
    }

    private func title(_ condition: PowerCondition) -> String {
        switch condition {
        case .ac: L("Power connected", "전원 연결")
        case .battery: L("On battery", "배터리 사용")
        case .any: L("Both", "둘 다")
        }
    }
    private func detail(_ condition: PowerCondition) -> String {
        switch condition {
        case .ac: L("Automatic keep-awake starts only while connected to power. Unplugging also applies the end policy in Power & Lid.", "자동 유지는 전원에 연결했을 때만 시작합니다. 전원을 분리하면 전원·덮개에서 선택한 종료 규칙을 적용합니다.")
        case .battery: L("Automatic keep-awake ends when power is connected.", "전원을 연결하면 자동 유지는 끝납니다.")
        case .any: L("Automatic keep-awake can start on either power source. The unplug policy takes priority, and the original battery limits remain.", "두 전원에서 자동 시작할 수 있습니다. 전원 분리 시 종료 규칙은 우선 적용하며 최초 배터리 한도도 유지합니다.")
        }
    }
}
