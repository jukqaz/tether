import XCTest
@testable import TetherCore

final class MacCapabilitiesTests: XCTestCase {
    func testOnlyVerifiedBatteryAndLidRequireHelper() {
        XCTAssertEqual(MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true).helperInstallTarget, .portable)
        for battery: Bool? in [true, false, nil] {
            for lid: Bool? in [true, false, nil] where battery != true || lid != true {
                let value = MacCapabilities(supportedPlatform: true, internalBattery: battery, lid: lid)
                XCTAssertEqual(value.helperInstallTarget, battery == false && lid == false ? .desktop : .unavailable)
            }
        }
    }

    func testDesktopAndUPSUseUserSessionAssertions() {
        // The native probe only counts an internal battery, never a UPS.
        let desktop = MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false)
        XCTAssertEqual(desktop.helperInstallTarget, .desktop)
        XCTAssertTrue(desktop.generalIdleAvailable)
        XCTAssertFalse(desktop.lidControlAvailable)
    }

    func testUnsupportedPlatformCannotInstallAnyHelper() {
        for battery: Bool? in [true, false, nil] {
            for lid: Bool? in [true, false, nil] {
                let value = MacCapabilities(supportedPlatform: false, internalBattery: battery, lid: lid)
                XCTAssertEqual(value.helperInstallTarget, .unsupported)
                XCTAssertFalse(value.generalIdleAvailable)
            }
        }
    }

    func testMissingLidObservationDoesNotRemoveGeneralIdleSupport() {
        let value = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil)
        XCTAssertEqual(value.hardware, .portable)
        XCTAssertEqual(value.helperInstallTarget, .unavailable)
        XCTAssertTrue(value.generalIdleAvailable)
    }
}
