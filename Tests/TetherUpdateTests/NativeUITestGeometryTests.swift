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

    func testResponderProbeUsesPublicViewAncestryWithoutExportingControlTextOrChangingFocus() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            let sidebar = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 160, height: 440))
            sidebar.setAccessibilityIdentifier("settings-sidebar")
            let field = NSTextField(string: "private-control-text-must-not-be-exported")
            root.addSubview(sidebar)
            window.contentView = root
            sidebar.addSubview(field)
            // NSOutlineView may change its bounds origin while attaching to a
            // window. Position the probe within its actual final coordinate area,
            // rather than assuming its visible document always starts at (0, 0).
            let sidebarBounds = sidebar.bounds
            XCTAssertGreaterThan(sidebarBounds.width, 0)
            XCTAssertGreaterThan(sidebarBounds.height, 0)
            // An empty native outline can fit itself to 20×15. This tests
            // geometry observation, not the production sidebar's layout size.
            field.frame = sidebarBounds.insetBy(dx: sidebarBounds.width / 4,
                                                dy: sidebarBounds.height / 4)
            XCTAssertTrue(sidebar.bounds.contains(field.frame),
                          "The inside-geometry fixture must actually place the control inside native bounds")
            let previousResponder = window.firstResponder
            let result = NativeUITestResponderGeometry.inspect(field, in: window)
            XCTAssertEqual(result["hasPublicOutlineViewAncestor"] as? Bool, true)
            XCTAssertEqual(result["focusViewIsDescendantOfSidebar"] as? Bool, true)
            XCTAssertEqual(result["sidebarContainsFocusViewFrame"] as? Bool, true,
                           "Inside fixture geometry: \(result)")
            XCTAssertEqual(result["sidebarIntersectsFocusViewFrame"] as? Bool, true,
                           "Inside fixture geometry: \(result)")
            let nodes = try XCTUnwrap(result["superviewChain"] as? [[String: Any]])
            XCTAssertGreaterThanOrEqual(nodes.count, 3)
            XCTAssertLessThanOrEqual(nodes.count, NativeUITestResponderGeometry.maximumChainLength)
            for node in nodes {
                XCTAssertEqual(Set(node.keys), ["class", "identifier", "frameInWindow"],
                               "Responder nodes may expose only class, identifier and window-coordinate geometry")
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8))
                .contains("private-control-text-must-not-be-exported"))
            XCTAssertTrue(window.firstResponder === previousResponder,
                          "Read-only observation must not move the actual keyboard target")

            // View ancestry alone does not prove visibility. An actual child
            // outside the outline's bounds must still report disjoint geometry.
            field.frame.origin.y = sidebar.bounds.maxY + 20
            XCTAssertFalse(sidebar.bounds.intersects(field.frame))
            let outside = NativeUITestResponderGeometry.inspect(field, in: window)
            XCTAssertEqual(outside["focusViewIsDescendantOfSidebar"] as? Bool, true)
            XCTAssertEqual(outside["sidebarContainsFocusViewFrame"] as? Bool, false)
            XCTAssertEqual(outside["sidebarIntersectsFocusViewFrame"] as? Bool, false)
            XCTAssertTrue(window.firstResponder === previousResponder)
        }
    }

    func testResponderProbeBoundsChainsAndLeavesNonViewOwnershipUnknown() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let responders = (0..<20).map { _ in NSResponder() }
            for index in 0..<(responders.count - 1) { responders[index].nextResponder = responders[index + 1] }
            let result = NativeUITestResponderGeometry.inspect(responders[0], in: window)
            let nodes = try XCTUnwrap(result["nextResponderChain"] as? [[String: Any]])
            XCTAssertEqual(nodes.count, 12)
            XCTAssertEqual(result["nextResponderChainTruncated"] as? Bool, true)
            XCTAssertTrue(result["superviewChain"] is NSNull)
            XCTAssertTrue(result["hasPublicOutlineViewAncestor"] is NSNull)
            XCTAssertTrue(result["focusViewFrameInWindow"] is NSNull)
            XCTAssertTrue(result["focusViewIsDescendantOfSidebar"] is NSNull)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: result))
            let absent = NativeUITestResponderGeometry.inspect(nil, in: window)
            XCTAssertTrue(absent["nextResponderChain"] is NSNull)
            XCTAssertTrue(absent["superviewChain"] is NSNull)
            XCTAssertTrue(absent["sidebarContainsFocusViewFrame"] is NSNull)
        }
    }

}
