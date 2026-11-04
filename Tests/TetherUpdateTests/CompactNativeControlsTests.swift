import AppKit
import XCTest
@testable import Tether

/// Test native callbacks across SwiftUI refreshes. These callbacks must use the
/// latest command/choice gates rather than stale closures from menu creation.
final class CompactNativeControlsTests: XCTestCase {
    func testPopupUsesLatestBindingAndRejectsUnavailableOrStaleSelection() async {
        await MainActor.run {
            var first = 30
            var second = 60
            let old = CompactPopUp(title: "Duration", selection: .init(get: { first }, set: { first = $0 }),
                choices: [PopupChoice(30, "30m"), PopupChoice(60, "1h")])
            let coordinator = old.makeCoordinator()
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.addItems(withTitles: ["30m", "1h"])
            coordinator.parent = CompactPopUp(title: "Duration", selection: .init(get: { second }, set: { second = $0 }),
                choices: [PopupChoice(30, "30m"), PopupChoice(60, "1h", enabled: false)])
            button.selectItem(at: 1)
            coordinator.changed(button)
            XCTAssertEqual(second, 60, "An unavailable item cannot issue a new selection")
            button.selectItem(at: 0)
            coordinator.changed(button)
            XCTAssertEqual(second, 30)
            XCTAssertEqual(first, 30, "Callbacks must not use the previous SwiftUI binding")
            button.selectItem(at: -1)
            coordinator.changed(button)
            XCTAssertEqual(second, 30)
        }
    }

    func testActionMenuRechecksLatestAvailabilityAndClosureAtClick() async {
        await MainActor.run {
            var original = 0
            var current = 0
            let coordinator = CompactActionMenu.Coordinator()
            let item = NSMenuItem(title: "Sleep", action: nil, keyEquivalent: "")
            item.tag = 0
            coordinator.actions = [CompactMenuAction("Sleep") { original += 1 }]
            coordinator.actions = [CompactMenuAction("Sleep", enabled: false) { current += 1 }]
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 0)
            coordinator.actions = [CompactMenuAction("Sleep") { current += 1 }]
            coordinator.enabled = false
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 0)
            coordinator.enabled = true
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 1)
            XCTAssertEqual(original, 0)
            item.tag = 4
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 1)
        }
    }

    func testPushButtonUsesCurrentActionAfterRefresh() async {
        await MainActor.run {
            var original = 0
            var current = 0
            let coordinator = CompactPushButton("End") { original += 1 }.makeCoordinator()
            coordinator.parent = CompactPushButton("End") { current += 1 }
            coordinator.clicked(NSButton())
            XCTAssertEqual(original, 0)
            XCTAssertEqual(current, 1)
        }
    }
}
