import Foundation
import TetherCore

/// The app version, read from the bundle this binary lives in (Contents/Helpers/tether).
func appVersion() -> String? {
    guard let path = Bundle.main.executablePath else { return nil }
    let contents = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
    return plist?["CFBundleShortVersionString"] as? String
}

func diagnose(_ rest: [String]) -> Never {
    var output: String?
    var record = false
    var hours = 24.0
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--record": record = true
        case "--out" where i + 1 < rest.count:
            i += 1
            output = rest[i]
        case "--hours" where i + 1 < rest.count:
            i += 1
            hours = Double(rest[i]) ?? hours
        default:
            fail(L("Usage: tether diagnose [--record] [--out <file>] [--hours <n>]", "사용법: tether diagnose [--record] [--out <파일>] [--hours <n>]"), code: 2)
        }
        i += 1
    }
    var since: Date?
    if record {
        let before = ControlStore.read().debugLog
        let started = Date()
        let logging = ControlStore.update { $0.debugLog = true }
        note(logging
            ? L("Recording with detailed logging. Reproduce the problem now, then press Return.",
                "자세히 기록하는 중입니다. 지금 문제를 재현한 뒤 Return 키를 누르세요.")
            : L("Recording (detailed logging needs the helper, which isn't installed). Reproduce the problem, then press Return.",
                "기록 중입니다 (도우미가 없어 자세한 기록은 불가). 문제를 재현한 뒤 Return 키를 누르세요."))
        _ = readLine()
        if logging { ControlStore.update { $0.debugLog = before } }
        since = started.addingTimeInterval(-60)
    }
    note(L("Collecting (a few seconds)…", "모으는 중입니다 (몇 초 걸려요)…"))
    let report = Diagnostics.report(appVersion: appVersion(), since: since, hours: hours)
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
