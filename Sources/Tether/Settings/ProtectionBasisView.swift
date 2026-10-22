import SwiftUI
import TetherCore

/// Evidence is available at the point of the decision, without crowding the main controls.
struct ProtectionBasisView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        SettingsCard(title: L("Thermal response", "발열에 대응하는 방식"), symbol: "thermometer.medium") {
            DisclosureGroup(L("Protection limits and sources", "보호 기준과 출처 보기"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Note(L("Tether stops only its own keep-awake session. It does not change the system's energy or fan controls.", "Tether가 유지하던 잠자기 방지만 중단합니다. 시스템 전원 모드나 팬 설정은 바꾸지 않습니다."))
                    basis(L("macOS thermal state", "macOS 시스템 발열"),
                          L("Apple recommends reducing work at serious pressure and minimizing it at critical. Tether stops its hold at either level, at the next observation, and requires explicit resume.",
                            "Apple은 심각 상태에서 작업량을 줄이고 위험 상태에서 최소화하도록 안내합니다. Tether는 다음 관측에서 자체 유지를 중지하며, 다시 사용하려면 직접 켜야 합니다."))
                    if model.hasInternalBattery {
                        basis(L("Optional battery sensor", "참고용 배터리 온도"),
                              L("Available sensor readings appear in diagnostics. Missing or model-specific Celsius readings do not set the protection cutoff.",
                                "읽을 수 있는 센서값은 진단에 남깁니다. 기기별 배터리 온도 수치나 센서 지원 여부를 보호 기준으로 사용하지 않습니다."))
                    }
                    basis(L("Cooling before resuming", "재개 전 확인"), model.protectionResumeDetail)
                    Note(model.hasInternalBattery
                        ? L("Apple's 10–35°C range describes ambient temperature. The battery sensor is not ambient or enclosure temperature and cannot diagnose hardware health.",
                            "Apple의 10~35°C는 주변 환경 온도입니다. 배터리 센서값은 주변·외장 표면 온도가 아니며, 하드웨어 상태를 진단하는 기준으로 사용할 수 없습니다.")
                        : L("Apple's 10–35°C range describes ambient temperature. macOS thermal pressure is not an ambient or enclosure temperature measurement.",
                            "Apple의 10~35°C는 주변 환경 온도입니다. macOS 열 상태는 주변·외장 표면 온도를 측정한 값이 아닙니다."))
                    HStack(spacing: 16) {
                        Link(L("Apple: temperatures", "Apple 온도 안내"), destination: URL(string: "https://support.apple.com/en-us/102336")!)
                        Link(L("Apple: thermal state", "Apple 발열 상태 지침"), destination: URL(string: "https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum")!)
                    }.font(.callout)
                }.padding(.top, 12)
            }.font(.callout.weight(.medium))
        }
    }

    private func basis(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(Color.tetherSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
