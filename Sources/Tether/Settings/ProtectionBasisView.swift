import SwiftUI
import TetherCore

/// Evidence is available at the point of the decision, without crowding the main controls.
struct ProtectionBasisView: View {
    @ObservedObject var model: AppModel
    var expansion: Binding<Bool>? = nil
    @State private var expanded = false
    @State private var showingSources = false

    var body: some View {
        SettingsDisclosure(title: L("Protection Limits & Sources", "보호 기준과 출처"),
            isExpanded: detailsExpansion, groupsSection: false,
            identifier: "settings-protection-basis-details") {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                Note(L("Protection covers current and future work even with alerts off. It releases only Tether's keep-awake; system energy and fan controls stay unchanged.",
                       "알림을 꺼도 현재·다음 유지를 보호합니다. Tether의 잠자기 방지만 해제하며 시스템 전원 모드·팬은 바꾸지 않습니다."))
                basis(L("macOS thermal state", "macOS 시스템 발열"),
                      L("Uses macOS thermal pressure, not Celsius. Critical always stops keep-awake; serious follows the setting above.",
                        "섭씨 온도 대신 macOS 열 상태를 따릅니다. 위험 단계는 항상 중지하며 심각 단계는 위 선택을 따릅니다."))
                basis(L("Cooling before resuming", "재개 전 확인"), model.protectionResumeDetail)
                Button(L("Limits and sources…", "기준과 출처 자세히…")) { showingSources = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("settings-protection-sources-open")
            }
        }.accessibilityIdentifier("settings-protection-basis-details")
        .sheet(isPresented: $showingSources) {
            V4FeatureSheet(title: L("Protection Limits & Sources", "보호 기준과 출처")) {
                if model.hasInternalBattery {
                    basis(L("Optional battery sensor", "참고용 배터리 온도"),
                          L("Available sensor readings appear in diagnostics. Sensor support and model-specific Celsius values do not set protection limits.",
                            "읽을 수 있는 배터리 센서값은 진단에 남깁니다. 센서 지원 여부와 기기별 온도 수치는 보호 기준으로 사용하지 않습니다."))
                }
                basis(L("Apple's temperature range", "Apple 온도 범위"), model.hasInternalBattery
                    ? L("Apple's 10–35°C range describes ambient temperature. The battery sensor is not ambient or enclosure temperature and cannot diagnose hardware health.",
                        "Apple의 10~35°C는 주변 환경 온도입니다. 배터리 센서값은 주변·외장 표면 온도가 아니며 하드웨어 상태를 진단하는 기준으로 사용할 수 없습니다.")
                    : L("Apple's 10–35°C range describes ambient temperature. macOS thermal pressure is not an ambient or enclosure temperature measurement.",
                        "Apple의 10~35°C는 주변 환경 온도입니다. macOS 열 상태는 주변·외장 표면 온도를 측정한 값이 아닙니다."))
                HStack(spacing: 16) {
                    Link(L("Apple: temperatures", "Apple 온도 안내"), destination: URL(string: "https://support.apple.com/en-us/102336")!)
                    Link(L("Apple: thermal state", "Apple 발열 상태 지침"), destination: URL(string: "https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum")!)
                }.font(TetherTypography.settingsSecondary)
            } actions: {
                Button(L("Close", "닫기")) { showingSources = false }
                    .actionButton().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-protection-sources-close")
                Spacer()
            }.accessibilityIdentifier("settings-protection-sources-sheet")
        }
    }

    private var detailsExpansion: Binding<Bool> { expansion ?? $expanded }

    private func basis(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(TetherTypography.settingsSecondary.weight(.semibold))
            Text(detail).font(TetherTypography.settingsSecondary).foregroundStyle(Color.tetherSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
