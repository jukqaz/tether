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
        case .ac: L("The automatic session ends on battery. Manual sessions and reserved battery holds continue within their own limits.", "전원을 분리하면 자동 유지는 끝납니다. 수동 유지와 배터리 유지 예약은 별도의 한도를 따릅니다.")
        case .battery: L("The automatic session ends when power is connected.", "전원을 연결하면 자동 유지는 끝납니다.")
        case .any: L("Automatic sessions apply on power and battery, within protection limits.", "전원 연결과 배터리 사용 모두에서 보호 한도 내로 자동 유지합니다.")
        }
    }
}
