import XCTest
@testable import Tether

final class PreviewDefaultsTests: XCTestCase {
    func testTypedValuesAndDomainsStayInMemory() {
        let defaults = PreviewDefaults()
        let domain = "TetherPreviewMemory." + UUID().uuidString
        defaults.register(defaults: ["fallback": "registered"])
        defaults.set(true, forKey: "flag")
        defaults.set(42, forKey: "integer")
        defaults.set(3.5, forKey: "double")
        defaults.set(Float(2.5), forKey: "float")
        defaults.set(Data([1, 2]), forKey: "data")
        XCTAssertTrue(defaults.bool(forKey: "flag"))
        XCTAssertEqual(defaults.integer(forKey: "integer"), 42)
        XCTAssertEqual(defaults.double(forKey: "double"), 3.5)
        XCTAssertEqual(defaults.float(forKey: "float"), 2.5)
        XCTAssertEqual(defaults.data(forKey: "data"), Data([1, 2]))
        defaults.setPersistentDomain(["saved": "memory"], forName: domain)
        XCTAssertEqual(defaults.string(forKey: "saved"), "memory")
        XCTAssertTrue(defaults.synchronize())
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: domain))
        defaults.removePersistentDomain(forName: domain)
        XCTAssertNil(defaults.object(forKey: "saved"))
        XCTAssertEqual(defaults.string(forKey: "fallback"), "registered")
        XCTAssertEqual(defaults.dictionaryRepresentation()["fallback"] as? String, "registered")
        XCTAssertTrue(PreviewDefaults().dictionaryRepresentation().isEmpty)
    }
}
