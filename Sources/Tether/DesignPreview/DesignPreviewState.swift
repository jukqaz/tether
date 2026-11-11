import Foundation
import SwiftUI
import TetherCore

/// The dedicated preview uses the shipping views and an isolated render controller.
/// It never creates a second UI-only policy, persistent defaults or OS assertions.
@MainActor
final class DesignPreviewState: ObservableObject {
    enum Scenario: String, CaseIterable, Identifiable {
        case ac, automatic, manual, dual, battery, paused, protection, desktop
        var id: Self { self }
        var title: String {
            switch self {
            case .ac: L("AC automatic + manual", "AC 자동 + 수동")
            case .automatic: L("Automatic keep-awake", "자동 유지")
            case .manual: L("Manual keep-awake", "수동 유지")
            case .dual: L("Automatic + manual", "자동 + 수동")
            case .battery: L("Battery manual", "배터리 수동")
            case .paused: L("Paused", "사용자 중지")
            case .protection: L("Protection", "보호 중지")
            case .desktop: L("Desktop Mac", "데스크톱 Mac")
            }
        }
    }
    @Published var scenario: Scenario {
        didSet {
            guard scenario != oldValue else { return }
            let restart = isObserving
            close()
            model = Self.makeModel(scenario)
            if restart { startObserving() }
        }
    }
    @Published private(set) var model: AppModel
    private(set) var isObserving = false
    private var observationPump: NativeUITestObservationPump?
    private var observationTimer: Timer?

    init(scenario: Scenario = .ac) {
        self.scenario = scenario
        model = Self.makeModel(scenario)
    }

    /// Only the interactive preview starts a timer. The factory above always
    /// supplies memory-only executors, preferences, helper and sensor facts.
    func startObserving() {
        guard !isObserving, model.userCommandsArePreview,
              let controller = model.userSession else { return }
        observationPump = NativeUITestObservationPump(controller: controller,
            power: scenario == .battery ? .battery : .ac,
            thermal: scenario == .protection ? 2 : 0, batteryPercent: 80)
        isObserving = true
        refreshObservations()
        let timer = Timer(timeInterval: NativeUITestObservationPump.interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refreshObservations()
            }
        }
        timer.tolerance = 0.1
        observationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshObservations() {
        guard isObserving, model.userCommandsArePreview else { return }
        observationPump?.refresh()
        model.refresh()
    }

    func close() {
        observationTimer?.invalidate(); observationTimer = nil
        observationPump?.stop(); observationPump = nil
        isObserving = false
        _ = model.userSession?.end()
        model.finishSessionFeatures()
    }

    deinit { observationTimer?.invalidate() }

    private static func makeModel(_ scenario: Scenario) -> AppModel {
        var arguments = ["--sample", "--display-on"]
        if scenario != .desktop { arguments.append("--prepared-lid") }
        switch scenario {
        case .automatic: break
        case .manual: arguments += ["--manual", "--timed"]
        case .battery: arguments += ["--manual", "--timed", "--battery"]
        case .ac, .dual, .paused, .protection, .desktop:
            arguments += ["--manual", "--timed", "--dual"]
        }
        if scenario == .desktop { arguments.append("--desktop") }
        if scenario == .paused { arguments.append("--paused") }
        if scenario == .protection { arguments.append("--protection") }
        return PreviewRenderer.sampleModel(arguments: arguments)
    }
}
