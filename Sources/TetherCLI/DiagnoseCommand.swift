import Foundation
import TetherCore

/// The app version, read from the bundle this binary lives in (Contents/Helpers/tether).
func appVersion() -> String? {
    guard let path = Bundle.main.executablePath else { return nil }
    let contents = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
    return plist?["CFBundleShortVersionString"] as? String
}

/// `tether doctor`: the quick checks, one line each; exits 1 when one failed.
func doctor() -> Never {
    let common = try? userSessionClient().snapshot()
    let checks = HealthChecks.run(userSession: common, userSessionRequested: true)
    for check in checks {
        let mark = switch check.result {
        case .ok: "✓"
        case .warning: "!"
        case .failed: "✗"
        }
        print("\(mark) \(check.name): \(check.detail)")
    }
    exit(checks.contains { $0.result == .failed } ? 1 : 0)
}

func diagnose(_ rest: [String]) -> Never {
    var output: String?
    var record = false
    var recordingMinutes = 15
    var includeProcessNames = false
    var hours = 24.0
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--record": record = true
        case "--include-app-names": includeProcessNames = true
        case "--record-minutes" where i + 1 < rest.count:
            i += 1
            guard let value = Int(rest[i]), (1...240).contains(value) else { fail("--record-minutes must be 1...240", code: 2) }
            recordingMinutes = value; record = true
        case "--out" where i + 1 < rest.count:
            i += 1
            output = rest[i]
        case "--hours" where i + 1 < rest.count:
            i += 1
            guard let value = Double(rest[i]), value.isFinite, value > 0, value <= 72 else { fail("--hours must be greater than 0 and at most 72", code: 2) }
            hours = value
        default:
            fail(L("Usage: tether diagnose [--record] [--record-minutes 1...240] [--out <file>] [--hours 1...72] [--include-app-names]", "사용법: tether diagnose [--record] [--record-minutes 1...240] [--out <파일>] [--hours 1...72] [--include-app-names]"), code: 2)
        }
        i += 1
    }
    var since: Date?
    if record {
        let before = try? ServiceClient().perform(ServiceRequest(.snapshot)).control
        let started = Date()
        let deadline = DiagnosticRecording.deadline(minutes: recordingMinutes, now: started)
        let logging = before != nil && ControlStore.update { $0.debugLog = true; $0.debugLogUntil = deadline }
        if logging { _ = try? ServiceClient().perform(ServiceRequest(.markDiagnostic)) }
        note(logging
            ? L("Detailed logging for up to \(recordingMinutes) minutes. Reproduce the problem, then press Return to export.",
                "최대 \(recordingMinutes)분간 자세히 기록합니다. 문제를 재현한 뒤 Return 키를 눌러 내보내세요.")
            : L("Couldn't start detailed recording. Check the helper connection/version. Press Return to export available logs.",
                "상세 기록을 켜지 못했습니다. 도우미 연결·버전을 확인하세요. Return 키를 누르면 보관된 기록을 내보냅니다."))
        _ = readLine()
        if logging { ControlStore.update {
            // Do not overwrite a newer recording choice made by the UI while we waited.
            if $0.debugLog == true, $0.debugLogUntil == deadline {
                $0.debugLog = before?.debugLog; $0.debugLogUntil = before?.debugLogUntil
            }
        } }
        since = started.addingTimeInterval(-60)
    }
    note(L("Collecting (a few seconds)…", "모으는 중입니다 (몇 초 걸려요)…"))
    let common = try? userSessionClient().snapshot()
    let report = Diagnostics.report(appVersion: appVersion(), since: since, hours: hours, includeProcessNames: includeProcessNames,
        userSession: common, userSessionRequested: true)
    guard let output else {
        print(report)
        exit(0)
    }
    do {
        try report.write(toFile: output, atomically: true, encoding: .utf8)
        print(L("Saved the report to \(output). Names of the user and the Mac are masked.",
                "보고서를 \(output)에 저장했습니다. 사용자와 Mac 이름은 가려져 있습니다."))
        exit(0)
    } catch {
        fail(L("Couldn't write \(output): \(error.localizedDescription)", "\(output)에 쓰지 못했습니다: \(error.localizedDescription)"))
    }
}
