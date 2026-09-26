import AppKit
import TetherCore

/// Detailed helper logging and the diagnostic report (see `Diagnostics`).
extension AppModel {
    func setDebugLogging(_ on: Bool) {
        appLog.info("detailed logging \(on ? "on" : "off", privacy: .public)")
        save { ControlStore.update { $0.debugLog = on ? true : nil } }
    }

    /// Puts the Markdown report together off the main thread (it runs `pmset` and `log`), then
    /// saves it to the Desktop and shows it in Finder, or copies it.
    func createDiagnosticReport(copy: Bool = false) {
        guard !diagnosticsBusy else { return }
        diagnosticsBusy = true
        reportNote = nil
        let version = Self.appVersion
        Task.detached(priority: .userInitiated) {
            let report = Diagnostics.report(appVersion: version)
            await MainActor.run { self.finishReport(report, copy: copy) }
        }
    }

    private func finishReport(_ report: String, copy: Bool) {
        diagnosticsBusy = false
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            reportNote = L("Copied", "복사했어요")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("Tether-diagnostics-\(formatter.string(from: Date())).md")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            reportNote = L("Saved to the Desktop", "바탕화면에 저장했어요")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorText = L("Couldn't save the report: \(error.localizedDescription)", "보고서를 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }
}
