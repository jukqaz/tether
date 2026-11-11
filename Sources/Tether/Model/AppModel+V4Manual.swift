import Foundation
import TetherCore

@MainActor
extension AppModel {
    var manualFeaturesNeedHelper: Bool {
        let options = userSession?.v4ManualSnapshot?.options ?? v4Settings.nextManualOptions
        return capabilities.lidControlAvailable && v3Settings.allowClosedLid && options.closedLid
    }
    var manualLidFeaturesConfirmed: Bool {
        guard manualFeaturesNeedHelper else { return true }
        guard helperResponding, !helperOutdated, coordinatingLid, !lidCommandPending,
              coordinatedLidError == nil, coordinatedLidBlockReason == nil,
              snapshot.lidControlObservationAvailable, snapshot.observedFullWake == true else { return false }
        return (status?.ownsOverride == true && snapshot.observedSleepDisabled == true)
            || status?.nativeDisplayVerified == true
    }
    var canAcquireManualFeatures: Bool {
        !v4AcquisitionBlocked && (!manualFeaturesNeedHelper || (coordinatingLid && helperResponding && !helperOutdated
            && coordinatedLidError == nil && coordinatedLidBlockReason == nil
            && snapshot.lidControlObservationAvailable && snapshot.observedFullWake == true))
    }
    func canExtendManual(by minutes: Int) -> Bool {
        acceptingUserCommands && !v4ManualApprovalPending && !commandPending
            && userSession?.canExtendManual(by: minutes) == true && canAcquireManualFeatures
    }
    func extendManualSession(by minutes: Int) {
        guard canExtendManual(by: minutes) else { return }
        Task { _ = await performManualExtension(minutes: minutes) }
    }
    @discardableResult
    func performManualExtension(minutes: Int, deadline: Double? = nil) async -> Bool {
        guard canExtendManual(by: minutes), let controller = userSession else { return false }
        if !manualFeaturesNeedHelper { return extendCommonManualSession(minutes: minutes) }
        guard controller.prepareManualExtension(minutes: minutes), let id = controller.pendingManualExtensionID else { return false }
        v4ManualApprovalPending = true
        defer { v4ManualApprovalPending = false }
        let until = min(deadline ?? .infinity, ContinuousTime.now + 5)
        while ContinuousTime.now < until && !Task.isCancelled && acceptingUserCommands && controller.manualExtensionPending
            && !controller.manualExtensionPrepared && coordinatedLidError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !Task.isCancelled, controller.manualExtensionPrepared, controller.commitManualExtension(requiresHelper: true) else {
            controller.cancelManualExtension(); controller.refresh()
            errorText = L("The extension was not confirmed. Check the current deadline.", "연장을 확인하지 못했습니다. 현재 종료 시각을 확인하세요.")
            return false
        }
        while ContinuousTime.now < until && !Task.isCancelled && acceptingUserCommands && controller.manualExtensionPending
            && coordinatedLidError == nil {
            if !lidCommandPending, status?.workSession?.manualExtensionID == id,
               controller.status.holding && controller.manualDisplayConfirmed && manualLidFeaturesConfirmed {
                controller.completeManualExtension(); acceptedUserWorkIntent(); return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        controller.cancelManualExtension(); controller.refresh()
        errorText = L("The extension could not be applied to every required executor. Check the current deadline.", "필요한 모든 실행기에 연장을 적용하지 못했습니다. 현재 종료 시각을 확인하세요.")
        return false
    }
    @discardableResult
    func verifyManualStart(requestID: UUID, deadline: Double? = nil) async -> Bool {
        guard let controller = userSession else { return false }
        defer { v4ManualApprovalPending = false }
        let until = min(deadline ?? .infinity, ContinuousTime.now + 5)
        while ContinuousTime.now < until && !Task.isCancelled && acceptingUserCommands && controller.manualRequestID == requestID
            && controller.status.manualActive && controller.status.blockReason == nil {
            let commonConfirmed = controller.status.holding && controller.manualDisplayConfirmed
            if commonConfirmed && (!manualFeaturesNeedHelper || (!lidCommandPending
                && status?.workSession?.manualRequestID == requestID && coordinatedLidError == nil
                && coordinatedLidBlockReason == nil && manualLidFeaturesConfirmed)) { return true }
            if coordinatedLidError != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Never cancel an unrelated newer request or an independent automatic reason.
        if controller.manualRequestID == requestID { controller.endManual() }
        errorText = L("The requested manual features were not confirmed. This new request was ended.", "요청한 수동 기능을 확인하지 못해 새 요청을 종료했습니다.")
        return false
    }
}
