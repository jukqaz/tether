import Foundation
import TetherCore

@MainActor
extension AppModel {
    func configureLifecycleOptionsIfNeeded() {
        guard lifecycleOptions == nil, let userSession else { return }
        lifecycleOptions = LifecycleOptionsRuntime(scope: userSession.v4Scope,
            defaults: userCommandsArePreview || developmentService ? nil : defaults,
            readOnly: userCommandsArePreview || developmentService)
    }
    func updateLifecycleOptions(_ state: UserSessionStatus) {
        configureLifecycleOptionsIfNeeded()
        guard let context = v4CurrentContext, let runtime = lifecycleOptions else { return }
        let now = ContinuousTime.now
        let fresh = hasCoordinatorAuthority && acceptingUserCommands && context.ownerValid && now < context.validUntil
            && state.observationLimited == false && (context.power == .ac || context.power == .battery)
        let confirmedManual = state.manualActive && state.holding && !v4ManualApprovalPending
            && (!manualFeaturesNeedHelper || manualLidFeaturesConfirmed)
        let executionConfirmed = (!state.manualActive || confirmedManual)
            && (!state.automaticActive || state.holding)
        runtime.observe(.init(scope: context.scope, manualID: state.manualActive ? state.manualRequestID : nil,
            automatic: state.automaticActive, protection: state.blockReason != nil), fresh: fresh,
            paused: context.paused, executionConfirmed: executionConfirmed, now: now)
    }
}
