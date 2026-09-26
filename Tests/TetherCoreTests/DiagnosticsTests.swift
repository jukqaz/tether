import XCTest
@testable import TetherCore

final class DiagnosticsTests: XCTestCase {
    func testRedactMasksTheUserAndTheMac() {
        let text = "/Users/jane/Applications/Tether.app by Jane Doe on janes-mbp.local (jane)"
        let masked = Diagnostics.redact(text, home: "/Users/jane", user: "jane", fullName: "Jane Doe", host: "janes-mbp.local")
        XCTAssertEqual(masked, "~/Applications/Tether.app by <name> on <host>.local (<user>)")
    }

    func testRedactLeavesShortNamesAlone() {
        // Two letters would mask parts of ordinary words.
        let masked = Diagnostics.redact("ok on power", home: "/Users/ok", user: "ok", fullName: "", host: "")
        XCTAssertEqual(masked, "ok on power")
    }

    func testLinesSinceKeepsDatedLinesAndTheirContinuations() {
        let log = """
        2026-09-26 10:00:00 started v2.0.0
        2026-09-26 11:59:59 on power: clamshell on
        2026-09-26 12:00:00 lid closed on AC
          continued detail
        2026-09-26 12:30:00 battery hold armed
        """
        let since = date("2026-09-26 12:00:00")
        let lines = Diagnostics.linesSince(log, since: since, format: "yyyy-MM-dd HH:mm:ss", width: 19)
        XCTAssertEqual(lines, ["2026-09-26 12:00:00 lid closed on AC", "  continued detail", "2026-09-26 12:30:00 battery hold armed"])
    }

    func testLinesSinceReadsTimestampsWithAnOffset() {
        let log = "2026-09-26 11:00:00 +0900 Sleep  \tEntering Sleep\n2026-09-26 13:00:00 +0900 Wake  \tWake from Normal Sleep"
        let since = ISO8601DateFormatter().date(from: "2026-09-26T03:30:00Z")!  // 12:30 at +0900
        let lines = Diagnostics.linesSince(log, since: since, format: "yyyy-MM-dd HH:mm:ss Z", width: 25)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("Wake from Normal Sleep"))
    }

    func testPowerLogKeepsSleepWakeAndTetherOnly() {
        func line(_ kind: String, _ message: String) -> String {
            "2026-09-26 17:21:04 +0900 " + kind.padding(toLength: 20, withPad: " ", startingAt: 0) + "\t" + message
        }
        XCTAssertTrue(Diagnostics.isInterestingPowerLine(line("Sleep", "Entering Sleep state due to 'Clamshell Sleep'")))
        XCTAssertTrue(Diagnostics.isInterestingPowerLine(line("DarkWake", "DarkWake from Normal Sleep")))
        XCTAssertTrue(Diagnostics.isInterestingPowerLine(line("Assertions", "PID 53650(Tether) Created PreventUserIdleDisplaySleep")))
        XCTAssertTrue(Diagnostics.isInterestingPowerLine(line("Notification", "Display is turned off")))
        XCTAssertFalse(Diagnostics.isInterestingPowerLine(line("Assertions", "PID 53650(Tether) Summary PreventUserIdleDisplaySleep")))
        XCTAssertFalse(Diagnostics.isInterestingPowerLine(line("Assertions", "PID 182(runningboardd) Created PreventUserIdleSystemSleep")))
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }
}

final class JSONWatchTests: XCTestCase {
    func testReloadsOnlyWhenTheFileChanges() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let watch = JSONWatch(Control.self, path: path)
        XCTAssertFalse(watch.reload(), "no file yet, nothing new")

        XCTAssertTrue(JSONFile.write(Control(enabled: true), to: path, permissions: 0o644))
        XCTAssertTrue(watch.reload())
        XCTAssertEqual(watch.value?.enabled, true)
        XCTAssertFalse(watch.reload(), "unchanged file")

        XCTAssertTrue(JSONFile.write(Control(enabled: true), to: path, permissions: 0o644))
        XCTAssertFalse(watch.reload(), "rewritten with the same content")

        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o644))
        XCTAssertTrue(watch.reload())
        XCTAssertEqual(watch.value?.enabled, false)

        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(watch.reload())
        XCTAssertNil(watch.value)
    }
}

final class LanguageTests: XCTestCase {
    func testChoiceMapsToALanguage() {
        XCTAssertEqual(LanguageChoice.english.language, .english)
        XCTAssertEqual(LanguageChoice.korean.language, .korean)
        XCTAssertEqual(LanguageChoice.system.language, Language.preferred)
    }

    func testStringsFollowTheCurrentLanguage() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .korean
        XCTAssertEqual(L("Sleep", "잠자기"), "잠자기")
        Localization.current = .english
        XCTAssertEqual(L("Sleep", "잠자기"), "Sleep")
    }
}

/// The helper writes as root into a folder the app can reach, so writes must never follow a link
/// or trust a predictable name, and the in-place control write must refuse anything but the file.
final class JSONFileSafetyTests: XCTestCase {
    private var folder: String!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("jsonfile-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        stat(path, &info)
        return info.st_mode & 0o7777
    }

    func testWriteReplacesALinkInsteadOfFollowingIt() throws {
        let victim = folder + "/victim"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victim))
        let path = folder + "/status.json"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: victim)
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o644))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: path))
        XCTAssertEqual(JSONFile.read(Control.self, from: path)?.enabled, false)
        XCTAssertEqual(mode(path), 0o644)
        // No temp file left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder).sorted(), ["status.json", "victim"])
    }

    func testOverwriteKeepsTheFileAndItsMode() throws {
        let path = folder + "/control.json"
        FileManager.default.createFile(atPath: path, contents: Data("{\"enabled\":true}".utf8), attributes: [.posixPermissions: 0o640])
        var before = stat()
        stat(path, &before)
        XCTAssertTrue(JSONFile.overwrite(Control(enabled: false), at: path))
        var after = stat()
        stat(path, &after)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(mode(path), 0o640)
        XCTAssertEqual(JSONFile.read(Control.self, from: path)?.enabled, false)
    }

    func testOverwriteRefusesLinksAndMissingFiles() throws {
        let victim = folder + "/victim"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victim))
        let symlink = folder + "/control.json"
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: victim)
        XCTAssertFalse(JSONFile.overwrite(Control(enabled: false), at: symlink))
        let hardlink = folder + "/other.json"
        try FileManager.default.linkItem(atPath: victim, toPath: hardlink)
        XCTAssertFalse(JSONFile.overwrite(Control(enabled: false), at: hardlink))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep")
        XCTAssertFalse(JSONFile.overwrite(Control(enabled: false), at: folder + "/missing.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/missing.json"))
    }

    func testControlStoreChangesTheFileInPlace() throws {
        let path = folder + "/control.json"
        FileManager.default.createFile(atPath: path, contents: Data("{\"enabled\":true}".utf8))
        XCTAssertTrue(ControlStore.update(path: path) { $0.enabled = false })
        XCTAssertEqual(ControlStore.read(path: path).enabled, false)
        XCTAssertFalse(ControlStore.update(path: folder + "/none.json") { $0.enabled = false })
    }

    func testOversizedFilesAreNotRead() throws {
        let path = folder + "/big.json"
        let padding = String(repeating: " ", count: JSONFile.maxSize)
        try Data("{\"enabled\":false}\(padding)".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(JSONFile.read(Control.self, from: path))
    }
}
