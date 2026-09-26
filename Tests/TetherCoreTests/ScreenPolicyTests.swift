import XCTest
@testable import TetherCore

final class ScreenPolicyTests: XCTestCase {
    private func action(active: Bool, lid: Bool, ext: Bool = false, dimmed: Bool) -> ScreenAction {
        ScreenPolicy.action(clamshellActive: active, lidClosed: lid, externalDisplay: ext, dimmed: dimmed)
    }

    func testClosingLidInClamshellDims() {
        XCTAssertEqual(action(active: true, lid: true, dimmed: false), .dim)
    }

    func testAlreadyDimmedStaysDimmed() {
        XCTAssertEqual(action(active: true, lid: true, dimmed: true), .none)
    }

    func testOpeningLidRestores() {
        XCTAssertEqual(action(active: true, lid: false, dimmed: true), .restore)
    }

    // The brightness bug: restoring at unplug with the lid shut raced macOS's battery dimming.
    func testUnplugWithLidClosedWaitsForTheLidToOpen() {
        XCTAssertEqual(action(active: false, lid: true, dimmed: true), .none)
    }

    func testWakingOnBatteryWithLidOpenRestores() {
        XCTAssertEqual(action(active: false, lid: false, dimmed: true), .restore)
    }

    func testExternalDisplayLeavesBuiltInPanelToMacOS() {
        XCTAssertEqual(action(active: true, lid: true, ext: true, dimmed: false), .none)
        XCTAssertEqual(action(active: true, lid: true, ext: true, dimmed: true), .restore)
    }

    func testNothingToDoWhenNotDimmed() {
        XCTAssertEqual(action(active: false, lid: false, dimmed: false), .none)
        XCTAssertEqual(action(active: true, lid: false, dimmed: false), .none)
    }

    func testBlankWithLidOpenDimsAndInputRestores() {
        XCTAssertEqual(ScreenPolicy.action(clamshellActive: true, lidClosed: false, externalDisplay: false,
                                           dimmed: false, blank: true), .dim)
        XCTAssertEqual(ScreenPolicy.action(clamshellActive: true, lidClosed: false, externalDisplay: true,
                                           dimmed: true, blank: true), .none)
        XCTAssertEqual(ScreenPolicy.action(clamshellActive: true, lidClosed: false, externalDisplay: false,
                                           dimmed: true, blank: false), .restore)
    }

    private func idleBlank(active: Bool = true, lid: Bool = false, ext: Bool = false, idle: Double,
                           minutes: Int = 10) -> Bool {
        ScreenPolicy.isIdleBlank(clamshellActive: active, lidClosed: lid, externalDisplay: ext,
                                 idleSeconds: idle, thresholdMinutes: minutes)
    }

    func testIdleBlankOnlyInClamshellWithAScreenInView() {
        XCTAssertTrue(idleBlank(idle: 600))
        XCTAssertFalse(idleBlank(idle: 599))
        XCTAssertFalse(idleBlank(active: false, idle: 9999))
        XCTAssertFalse(idleBlank(idle: 9999, minutes: 0))
        // Lid closed: only when an external display is in view (desk clamshell).
        XCTAssertFalse(idleBlank(lid: true, idle: 9999))
        XCTAssertTrue(idleBlank(lid: true, ext: true, idle: 9999))
    }

    func testDarkLevelsAreNotSaved() {
        XCTAssertFalse(ScreenPolicy.worthSaving(0))
        XCTAssertFalse(ScreenPolicy.worthSaving(0.03))
        XCTAssertTrue(ScreenPolicy.worthSaving(0.5))
    }
}
