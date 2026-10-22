import XCTest
@testable import Tether

@MainActor
final class LegacyDisplayRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() {
        super.setUp()
        domain = "io.github.jukqaz.tether.test.legacy-display." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        super.tearDown()
    }
    func testR3_036PanelOriginalSurvivesFailedReadbackAndExplicitRetry() {
        defaults.set(0.6, forKey: ScreenGuard.Key.brightness)
        var observed: Float? = nil
        var writes = 0
        let guarder = ScreenGuard(defaults: defaults, readPanel: { observed }, writePanel: { _ in writes += 1 },
            readKeyboard: { nil }, writeKeyboard: { _, _ in XCTFail("No keyboard original") })
        guarder.update(clamshellActive: false, lidClosed: false)
        XCTAssertTrue(guarder.hasRecoveryDebt)
        XCTAssertEqual(defaults.float(forKey: ScreenGuard.Key.brightness), 0.6)
        guarder.releaseAll()
        XCTAssertEqual(writes, 1)
        observed = 0.6
        guarder.retryRecovery()
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(guarder.hasRecoveryDebt)
        XCTAssertNil(guarder.recoveryError)
    }
    func testR3_036KeyboardLevelAndAutomaticModeMustBothMatch() {
        defaults.set(0.4, forKey: ScreenGuard.Key.keyboard)
        defaults.set(true, forKey: ScreenGuard.Key.keyboardAuto)
        var automatic = false
        let guarder = ScreenGuard(defaults: defaults, readPanel: { nil }, writePanel: { _ in XCTFail() },
            readKeyboard: { (0.4, automatic) }, writeKeyboard: { _, _ in })
        guarder.releaseAll()
        XCTAssertTrue(guarder.hasRecoveryDebt)
        XCTAssertNotNil(defaults.object(forKey: ScreenGuard.Key.keyboardAuto))
        automatic = true
        guarder.retryRecovery()
        XCTAssertFalse(guarder.hasRecoveryDebt)
    }
    func testR3_036CorruptOriginalIsRetainedWithoutWriting() {
        defaults.set("bad", forKey: ScreenGuard.Key.brightness)
        defaults.set(0.2, forKey: ScreenGuard.Key.keyboard)
        let guarder = ScreenGuard(defaults: defaults, readPanel: { nil }, writePanel: { _ in XCTFail() },
            readKeyboard: { nil }, writeKeyboard: { _, _ in XCTFail() })
        guarder.releaseAll()
        XCTAssertTrue(guarder.hasRecoveryDebt)
        XCTAssertEqual(defaults.string(forKey: ScreenGuard.Key.brightness), "bad")
        XCTAssertEqual(defaults.float(forKey: ScreenGuard.Key.keyboard), 0.2)
    }
    func testR3_006NewSessionsDoNotDimAndClosedLidDefersRecovery() {
        let guarder = ScreenGuard(defaults: defaults, readPanel: { XCTFail(); return nil }, writePanel: { _ in XCTFail() },
            readKeyboard: { XCTFail(); return nil }, writeKeyboard: { _, _ in XCTFail() })
        guarder.update(clamshellActive: true, lidClosed: true)
        guarder.update(clamshellActive: true, lidClosed: false)
        XCTAssertFalse(guarder.hasRecoveryDebt)
        defaults.set(0.7, forKey: ScreenGuard.Key.brightness)
        guarder.update(clamshellActive: true, lidClosed: true)
        XCTAssertTrue(guarder.hasRecoveryDebt)
    }
}
