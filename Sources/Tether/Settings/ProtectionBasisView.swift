import SwiftUI
import TetherCore

/// Evidence is available at the point of the decision, without crowding the main controls.
struct ProtectionBasisView: View {
    @ObservedObject var model: AppModel
    var expansion: Binding<Bool>? = nil
    @State private var expanded = false

    var body: some View {
        SettingsDisclosure(title: L("Protection Limits & Sources", "보호 기준과 출처"), isExpanded: detailsExpansion) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                Note(L("Protection settings save immediately and apply to current and future work. Turning off notifications never disables protection.",
                       "보호 설정은 즉시 저장되어 현재·다음 유지에 적용됩니다. 알림을 꺼도 보호는 계속됩니다."))
                Note(L("Tether stops only its own keep-awake session. It does not change the system's energy or fan controls.", "Tether가 유지하던 잠자기 방지만 중단합니다. 시스템 전원 모드나 팬 설정은 바꾸지 않습니다."))
                basis(L("macOS thermal state", "macOS 시스템 발열"),
                      L("Thermal state comes from macOS, not a Celsius reading. Critical thermal pressure always stops Tether keep-awake; stopping at the serious level is optional. Automatic conditions can be checked again after safe recovery if enabled.",
                        "열 상태는 macOS 기준이며 섭씨 온도가 아닙니다. 위험 단계에서는 항상 Tether 유지를 중지합니다. 심각 단계에서 중지할지도 선택할 수 있습니다. 보호 중지 후 재개 옵션을 켜면 안전해진 뒤 자동 조건을 다시 확인합니다."))
                if model.hasInternalBattery {
                    basis(L("Optional battery sensor", "참고용 배터리 온도"),
                          L("Available sensor readings appear in diagnostics. Missing or model-specific Celsius readings do not set the protection cutoff.",
                            "읽을 수 있는 센서값은 진단에 남깁니다. 기기별 배터리 온도 수치나 센서 지원 여부를 보호 기준으로 사용하지 않습니다."))
                }
                basis(L("Cooling before resuming", "재개 전 확인"), model.protectionResumeDetail)
                Note(model.v3Settings.automaticallyResumeAfterProtection
                    ? L("After 60 safe seconds, recheck automatic conditions. Ended manual work never restarts; Stop all stays in effect.",
                        "안전한 상태가 60초 이어진 뒤 자동 조건을 다시 확인합니다. 종료된 수동 유지는 다시 시작하지 않으며 모두 중지는 유지됩니다.")
                    : L("Automatic recovery is off. Ended manual work never restarts.",
                        "보호 회복 후 자동 재개는 꺼져 있습니다. 종료된 수동 유지는 다시 시작하지 않습니다."))
                Note(model.hasInternalBattery
                    ? L("Apple's 10–35°C range describes ambient temperature. The battery sensor is not ambient or enclosure temperature and cannot diagnose hardware health.",
                        "Apple의 10~35°C는 주변 환경 온도입니다. 배터리 센서값은 주변·외장 표면 온도가 아니며, 하드웨어 상태를 진단하는 기준으로 사용할 수 없습니다.")
                    : L("Apple's 10–35°C range describes ambient temperature. macOS thermal pressure is not an ambient or enclosure temperature measurement.",
                        "Apple의 10~35°C는 주변 환경 온도입니다. macOS 열 상태는 주변·외장 표면 온도를 측정한 값이 아닙니다."))
                HStack(spacing: 16) {
                    Link(L("Apple: temperatures", "Apple 온도 안내"), destination: URL(string: "https://support.apple.com/en-us/102336")!)
                    Link(L("Apple: thermal state", "Apple 발열 상태 지침"), destination: URL(string: "https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum")!)
                }.font(.callout)
            }
        }.accessibilityIdentifier("settings-protection-basis-details")
    }

    private var detailsExpansion: Binding<Bool> { expansion ?? $expanded }

    private func basis(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(Color.tetherSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
