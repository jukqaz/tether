import XCTest
@testable import TetherCore

final class ManualStartSelectionTests: XCTestCase {
    func testTypingInvalidTextCannotStartThePreviousNumericValue() {
        XCTAssertEqual(ManualStartSelection.parseMinutes(" 45 "), .minutes(45))
        for input in ["", "abc", "4.5", "1e3", "-1", "0", "9999999999999999999999999"] {
            XCTAssertNil(ManualStartSelection.parseMinutes(input), input)
        }
    }
    func testAbsoluteTimeUsesTheFreshStartClockWithoutMinuteRounding() {
        let end = Date(timeIntervalSince1970: 4000)
        XCTAssertEqual(ManualStartSelection.until(end).duration(at: Date(timeIntervalSince1970: 1000.5), maximum: 7200), 2999.5)
        XCTAssertNil(ManualStartSelection.until(end).duration(at: end, maximum: 7200))
        XCTAssertNil(ManualStartSelection.until(end).duration(at: end.addingTimeInterval(1), maximum: 7200))
    }
    func testTheWholeDurationMustFitTheCurrentBatteryLimit() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ManualStartSelection.minutes(120).duration(at: now, maximum: 7200), 7200)
        XCTAssertNil(ManualStartSelection.minutes(121).duration(at: now, maximum: 7200))
        XCTAssertNil(ManualStartSelection.until(now.addingTimeInterval(7200.1)).duration(at: now, maximum: 7200))
        XCTAssertNil(ManualStartSelection.minutes(0).duration(at: now, maximum: 7200))
        XCTAssertNil(ManualStartSelection.minutes(-1).duration(at: now, maximum: 7200))
    }
    func testInvalidClockAndLimitsNeverCreateADraftDuration() {
        XCTAssertNil(ManualStartSelection.minutes(1).duration(at: Date(timeIntervalSince1970: .nan), maximum: 7200))
        XCTAssertNil(ManualStartSelection.minutes(1).duration(at: Date(), maximum: .infinity))
        XCTAssertNil(ManualStartSelection.minutes(1).duration(at: Date(), maximum: 0))
    }
}
