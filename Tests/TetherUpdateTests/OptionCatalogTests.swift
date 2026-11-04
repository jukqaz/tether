import XCTest
import TetherCore
@testable import Tether

final class OptionCatalogTests: XCTestCase {
    func testEveryApprovedFamilyIsRepresentedAndUnimplementedFeaturesHaveNoPretendAction() {
        let entries = OptionCatalog.entries
        XCTAssertEqual(entries.map(\.id), (1...26).map { String(format: "O%02d", $0) })
        XCTAssertEqual(Set(entries.map(\.id)).count, 26)
        for entry in entries where entry.readiness == .notImplemented {
            XCTAssertNil(entry.destination, "An unimplemented backend must not expose an activation control")
        }
    }
    func testSearchMatchesEveryWordAndFindsKoreanAndTechnicalAliases() {
        let entries = OptionCatalog.entries
        XCTAssertTrue(entries.first { $0.id == "O18" }!.matches("hook"))
        XCTAssertTrue(entries.first { $0.id == "O06" }!.matches("wifi usb"))
        XCTAssertFalse(entries.first { $0.id == "O01" }!.matches("hook"))
        XCTAssertEqual(entries.filter { $0.matches("   ") }.count, 26)
    }

    func testCurrentTimerOpensExecutableMenuControlsInsteadOfKeepAwakePreferences() throws {
        let timer = try XCTUnwrap(OptionCatalog.entries.first { $0.id == "O03" })
        XCTAssertEqual(timer.destination, .currentWork)
        XCTAssertNotEqual(timer.destination, .keep)
        let defaults = try XCTUnwrap(OptionCatalog.entries.first { $0.id == "O11" })
        XCTAssertEqual(defaults.destination, .manualDefaults)
    }

    func testPlainTaskSummariesRetainSearchableSupportDetailsAndSpecificActions() {
        let original = Localization.current; defer { Localization.current = original }
        for language in [Language.korean, .english] {
            Localization.current = language
            let entries = OptionCatalog.entries
            for entry in entries where entry.readiness == .partial {
                XCTAssertFalse(entry.supportDetail?.isEmpty ?? true, entry.id)
                XCTAssertNotEqual(entry.summary, entry.supportDetail, entry.id)
                XCTAssertNotNil(entry.destination, entry.id)
            }
            let actions = Set(entries.compactMap { $0.destination?.actionTitle })
            XCTAssertEqual(actions.count, 9)
            XCTAssertFalse(actions.contains(language == .english ? "Open options…" : "옵션 열기…"))
            XCTAssertTrue(entries.first { $0.id == "O17" }!.matches("AppleScript"),
                "Support details remain searchable after moving them out of the default list")
        }
    }
}
