import AppKit
import XCTest
@testable import Tether

final class NativeUITestGeometryTests: XCTestCase {
    func testUnboundedAndInvalidNativeConstraintsRemainJSONSafeAndUnknown() throws {
        let bounds = NativeUITestGeometry.size(NSSize(width: CGFloat.infinity, height: CGFloat.nan))
        XCTAssertTrue(bounds["width"] is NSNull)
        XCTAssertTrue(bounds["height"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(bounds))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: bounds))
        let rect = NativeUITestGeometry.rect(NSRect(x: -CGFloat.infinity, y: 12, width: 640, height: 480))
        XCTAssertTrue(rect["x"] is NSNull)
        XCTAssertEqual(rect["y"] as? Double, 12)
        XCTAssertEqual(rect["width"] as? Double, 640)
        XCTAssertEqual(rect["height"] as? Double, 480)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: rect))
    }
}
