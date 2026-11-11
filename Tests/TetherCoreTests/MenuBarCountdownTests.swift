import XCTest
@testable import TetherCore

final class MenuBarCountdownTests: XCTestCase {
    func testPositiveRemainingTimeNeverReadsAsZeroMinutes() {
        XCTAssertEqual(MenuBarCountdown(remaining: 0.001).minutes, 1)
        XCTAssertEqual(MenuBarCountdown(remaining: 59.999).minutes, 1)
        XCTAssertEqual(MenuBarCountdown(remaining: 60).minutes, 1)
        XCTAssertEqual(MenuBarCountdown(remaining: 60.001).minutes, 2)
        XCTAssertEqual(MenuBarCountdown(remaining: 120 * 60).minutes, 120)
    }

    func testExpiredDeadlineReadsZeroWithoutChangingTheSession() {
        XCTAssertEqual(MenuBarCountdown(remaining: 0).minutes, 0)
        XCTAssertEqual(MenuBarCountdown(remaining: -10).minutes, 0)
        XCTAssertEqual(MenuBarCountdown(remaining: -Double.greatestFiniteMagnitude).remainingSeconds, 0)
    }

    func testInvalidDeadlineNeverReadsAsCompleteOrUnlimited() {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for seconds in [Double.nan, Double.infinity, -Double.infinity,
                            ManualSessionPolicy.maximumTimedDuration.nextUp, Double.greatestFiniteMagnitude] {
                let countdown = MenuBarCountdown(remaining: seconds)
                XCTAssertNil(countdown.remainingSeconds)
                XCTAssertNil(countdown.minutes)
                XCTAssertEqual(countdown.text, "—")
                XCTAssertEqual(countdown.accessibilityValue,
                               language == .korean ? "남은 시간 확인 중" : "Remaining time unavailable")
            }
        }
    }

    func testCompactMinutesKeepActualSecondsForAccessibilityInBothLanguages() {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            let countdown = MenuBarCountdown(remaining: 182)
            XCTAssertEqual(countdown.text, language == .korean ? "4분" : "4m")
            XCTAssertEqual(countdown.accessibilityValue,
                           language == .korean ? "3:02 남음" : "3:02 remaining")
            XCTAssertEqual(MenuBarCountdown(remaining: 9.2).accessibilityValue,
                           language == .korean ? "0:10 남음" : "0:10 remaining")
            XCTAssertEqual(MenuBarCountdown.widthReference, language == .korean ? "9999분+" : "9999m+")
            XCTAssertEqual(MenuBarCountdown(remaining: ManualSessionPolicy.maximumTimedDuration).text,
                           MenuBarCountdown.widthReference)
        }
    }

    func testLongACTimersKeepTheirDeadlineAndBoundOnlyTheMenuBarLabel() {
        let before = Localization.current
        Localization.current = .english
        defer { Localization.current = before }
        XCTAssertEqual(MenuBarCountdown(remaining: 25 * 3600).text, "1500m")
        let long = MenuBarCountdown(remaining: 10_000 * 60)
        XCTAssertEqual(long.minutes, 10_000)
        XCTAssertEqual(long.text, "9999m+")
        XCTAssertEqual(long.accessibilityValue, "166:40:00 remaining")
        let maximum = MenuBarCountdown(remaining: ManualSessionPolicy.maximumTimedDuration)
        XCTAssertNotNil(maximum.remainingSeconds)
        XCTAssertFalse(maximum.accessibilityValue.contains("unavailable"))
        XCTAssertTrue(maximum.accessibilityValue.hasPrefix("2562047788015215:"))
        for invalid in [Double(Int.max), .greatestFiniteMagnitude, .nan, .infinity] {
            XCTAssertEqual(Texts.countdown(invalid), "—")
            XCTAssertEqual(Texts.duration(invalid), "—")
        }
    }
}
