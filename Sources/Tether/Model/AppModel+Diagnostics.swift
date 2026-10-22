import AppKit
import UniformTypeIdentifiers
import TetherCore

/// Recording has one narrow memory-only UI-test exception. Report export,
/// preferences, markers and file actions never inherit that exception.
struct DiagnosticControlsAccess {
    let recording: Bool
    let ancillary: Bool

    init(canRecord: Bool, preview: Bool, development: Bool, nativeRecordingFixture: Bool) {
        ancillary = !preview && !development
        recording = canRecord && !development && (!preview || nativeRecordingFixture)
    }
}

/// Common-session memory/OS records, legacy helper logs and explicit report export.
extension AppModel {
    var diagnosticControlsAccess: DiagnosticControlsAccess {
        DiagnosticControlsAccess(canRecord: canRecordDiagnostics, preview: userCommandsArePreview,
            development: developmentService,
            nativeRecordingFixture: NativeUIAutomation.isInMemoryRecordingSession(userSession))
    }

    var canRecordDiagnostics: Bool {
        usesUserSession ? acceptingUserCommands && userSession != nil
            : helperResponding && !commandPending && !helperOutdated
    }
    var diagnosticRecordingActive: Bool { userSession?.activity.isRecording() ?? debugLogging }
    var diagnosticRecordingUntil: Date? {
        if let userSession { return userSession.activity.recordingUntil }
        return debugLogUntil.map { Date(timeIntervalSince1970: $0) }
    }
    var commonActivity: [UserSessionActivity.Entry] { userSession?.activity.recent() ?? [] }

    func setDebugLogging(_ on: Bool, minutes: Int = 15) {
        guard canRecordDiagnostics else { return }
        if let userSession { userSession.setActivityRecording(on, minutes: minutes); return }
        appLog.notice("detailed logging \(on ? "on" : "off", privacy: .public)")
        save { ControlStore.update {
            $0.debugLog = on ? true : nil
            $0.debugLogUntil = on ? DiagnosticRecording.deadline(minutes: minutes) : nil
        } }
    }

    var activityLogPath: String {
        developmentService
            ? URL(fileURLWithPath: TetherPaths.serviceSocket).deletingLastPathComponent().appendingPathComponent("helper.log").path
            : TetherPaths.helperLog
    }

    func revealLogs() {
        if usesUserSession { createDiagnosticReport(copy: true); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: activityLogPath)])
    }

    /// Puts the Markdown report together off the main thread (it runs `pmset` and `log`), then
    /// lets the user choose a save location, or copies it.
    func createDiagnosticReport(copy: Bool = false, hours: Double = 24, includeProcessNames: Bool = false) {
        guard !diagnosticsBusy else { return }
        diagnosticsBusy = true
        reportNote = nil
        let version = Self.appVersion
        let commonRequested = usesUserSession
        let common = commonRequested ? userCommandReply(UserSessionRequest()) : nil
        let activity = userSession?.activity
        let device = capabilities
        let sessionFeatures = sessionFeaturesDiagnosticSummary
        let remote = developmentService
            ? RemoteProviderProbe.sample(generation: 0, displayRevision: displayRevision, sessionKey: remoteInspectionSessionKey)
            : RemoteProviderProbe.capture(generation: 0, displayRevision: displayRevision, sessionKey: remoteInspectionSessionKey)
        Task.detached(priority: .userInitiated) {
            let report = Diagnostics.report(appVersion: version, hours: hours, includeProcessNames: includeProcessNames,
                userSession: common, userSessionRequested: commonRequested, capabilities: device, remoteContext: remote,
                commonActivity: activity)
            await MainActor.run { self.finishReport(report + sessionFeatures, copy: copy) }
        }
    }

    private func finishReport(_ report: String, copy: Bool) {
        if copy {
            diagnosticsBusy = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            reportNote = L("Copied", "복사했어요")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tether-diagnostics-\(formatter.string(from: Date())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.begin { result in
            self.diagnosticsBusy = false
            guard result == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                self.reportNote = L("Report saved", "보고서를 저장했어요")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.errorText = L("Couldn't save the report: \(error.localizedDescription)", "보고서를 저장하지 못했습니다: \(error.localizedDescription)")
            }
        }
    }
}
