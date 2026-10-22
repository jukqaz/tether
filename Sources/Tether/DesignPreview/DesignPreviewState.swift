import SwiftUI
import TetherCore

/// The dedicated preview uses the shipping views and an isolated render controller.
/// It never creates a second UI-only policy, persistent defaults or OS assertions.
@MainActor
final class DesignPreviewState: ObservableObject {
    enum Scenario: String, CaseIterable, Identifiable {
        case ac, battery, paused, protection, helper, lock, desktop, recovery
        var id: Self { self }
        var title: String {
            switch self {
            case .ac: L("AC automatic + manual", "AC 자동 + 수동")
            case .battery: L("Battery manual", "배터리 수동")
            case .paused: L("Paused", "사용자 중지")
            case .protection: L("Protection", "보호 중지")
            case .helper: L("Helper preparation", "도우미 준비")
            case .lock: L("Lock limitations", "잠금 제한")
            case .desktop: L("Desktop Mac", "데스크톱 Mac")
            case .recovery: L("Recovery review", "원복 확인")
            }
        }
    }
    @Published var scenario: Scenario {
        didSet { model = Self.makeModel(scenario) }
    }
    @Published private(set) var model: AppModel

    init(scenario: Scenario = .ac) {
        self.scenario = scenario
        model = Self.makeModel(scenario)
    }

    private static func makeModel(_ scenario: Scenario) -> AppModel {
        var arguments = ["--sample", "--manual", "--timed"]
        if scenario == .battery { arguments.append("--battery") }
        else { arguments.append("--dual") }
        if scenario == .desktop { arguments.append("--desktop") }
        let model = PreviewRenderer.sampleModel(arguments: arguments)
        if scenario == .paused { model.userSession?.stopCurrent() }
        if scenario == .protection {
            model.userSession?.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                                      now: ContinuousTime.now, batteryPercent: 80)
        }
        if scenario == .helper { _ = model.userSession?.end() }
        if scenario == .recovery {
            _ = model.userSession?.end()
            model.errorText = L("Example: Tether's earlier changes need review before a new request.",
                                "예시: 새 요청 전에 Tether의 이전 변경을 확인해야 합니다.")
        }
        return model
    }
}
