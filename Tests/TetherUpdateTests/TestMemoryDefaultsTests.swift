import Foundation
import XCTest
import TetherCore
@testable import Tether

final class TestMemoryDefaultsTests: XCTestCase {
    func testCurrentAndLegacyDomainsStaySeparateDuringMigrationAndRemoval() {
        let defaults = TestMemoryDefaults(domain: "current")
        defaults.register(defaults: ["registered": true, "choice": "fallback"])
        defaults.setPersistentDomain(["choice": "current"], forName: "current")
        defaults.setPersistentDomain(["choice": "legacy"], forName: "legacy")
        XCTAssertEqual(defaults.string(forKey: "choice"), "current")
        XCTAssertTrue(defaults.bool(forKey: "registered"))
        XCTAssertNil(defaults.persistentDomain(forName: "current")?["registered"])
        XCTAssertEqual(defaults.persistentDomain(forName: "legacy")?["choice"] as? String, "legacy")

        defaults.removePersistentDomain(forName: "legacy")
        XCTAssertEqual(defaults.string(forKey: "choice"), "current")
        XCTAssertNil(defaults.persistentDomain(forName: "legacy"))
        defaults.removePersistentDomain(forName: "current")
        XCTAssertNil(defaults.persistentDomain(forName: "current"))
        XCTAssertEqual(defaults.string(forKey: "choice"), "fallback")
    }

    func testTypedWritesAndRemovalUseOnlyTheFixtureDictionary() {
        let defaults = TestMemoryDefaults(domain: "fixture")
        let data = Data([1, 2, 3])
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "int")
        defaults.set(Float(0.5), forKey: "float")
        defaults.set(2.5, forKey: "double")
        defaults.set(data, forKey: "data")
        defaults.set("text", forKey: "string")
        XCTAssertTrue(defaults.bool(forKey: "bool"))
        XCTAssertEqual(defaults.integer(forKey: "int"), 42)
        XCTAssertEqual(defaults.float(forKey: "float"), 0.5)
        XCTAssertEqual(defaults.double(forKey: "double"), 2.5)
        XCTAssertEqual(defaults.float(forKey: "double"), 2.5)
        XCTAssertEqual(defaults.double(forKey: "int"), 42)
        XCTAssertEqual(defaults.data(forKey: "data"), data)
        XCTAssertEqual(defaults.string(forKey: "string"), "text")
        defaults.set(nil, forKey: "data")
        defaults.removeObject(forKey: "string")
        XCTAssertNil(defaults.data(forKey: "data"))
        XCTAssertNil(defaults.object(forKey: "string"))
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), ["bool", "int", "float", "double"])
        XCTAssertTrue(defaults.synchronize())
    }

    @MainActor
    func testControllerEndAndLateFixtureWriteDoNotCreatePreferencesFiles() async {
        final class Backend: IdleAssertionBackend {
            func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { (0, 31) }
            func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
            func level(id: UInt32) -> Int? { 255 }
            func release(id: UInt32) -> Int32 { 0 }
        }
        let domain = "TetherMemoryDefaultsTests." + UUID().uuidString
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let defaults = TestMemoryDefaults(domain: domain)
        let controller = UserSessionController(defaults: defaults, backend: Backend(),
            guiProbe: nil, environmentProbe: nil, boot: "memory-defaults-test")
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        controller.setAutomatic(true)
        XCTAssertNotNil(defaults.data(forKey: UserSessionController.preferenceKey))
        XCTAssertTrue(controller.end())
        defaults.removePersistentDomain(forName: domain)
        XCTAssertNil(defaults.persistentDomain(forName: domain))
        await Task.yield()
        // A callback retaining the fixture after teardown must still be memory-only.
        defaults.set(true, forKey: "lateFixtureWrite")
        XCTAssertTrue(defaults.bool(forKey: "lateFixtureWrite"))
        XCTAssertTrue(defaults.synchronize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
