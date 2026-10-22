import AppKit
import XCTest
@testable import Tether

final class SheetInitialFocusTests: XCTestCase {
    func testPresentationOriginRequiresExplicitPointerEvents() {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                     .otherMouseDown, .otherMouseUp] {
            XCTAssertEqual(SheetPresentationOrigin(eventType: type), .pointer)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            XCTAssertEqual(SheetPresentationOrigin(eventType: type), .keyboard)
        }
        for type in [NSEvent.EventType?.none, .mouseMoved, .scrollWheel, .flagsChanged, .appKitDefined] {
            XCTAssertEqual(SheetPresentationOrigin(eventType: type), .unknown,
                "An absent or unclassified current event is not evidence of pointer invocation")
        }
    }

    @MainActor
    func testOnlyCapturedPointerOriginCanClearInitialFocus() {
        for origin in [SheetPresentationOrigin.keyboard, .unknown] {
            let state = SheetInitialFocusState(origin: origin)
            XCTAssertFalse(state.consumeInitialFocus(currentEventType: .leftMouseUp))
            XCTAssertTrue(state.handled)
        }
        let pointer = SheetInitialFocusState(origin: .pointer)
        XCTAssertTrue(pointer.consumeInitialFocus(currentEventType: nil),
            "The explicit originating pointer event remains valid after the presentation event ends")
        XCTAssertFalse(pointer.consumeInitialFocus(currentEventType: .leftMouseUp),
            "A later view update must not clear a responder a second time")
    }

    @MainActor
    func testKeyboardInputDuringPresentationPreservesTheUsersFocus() {
        let trackedKeyboard = SheetInitialFocusState(origin: .pointer)
        trackedKeyboard.noteKeyboardInteraction()
        XCTAssertFalse(trackedKeyboard.consumeInitialFocus(currentEventType: nil))
        let currentKeyboard = SheetInitialFocusState(origin: .pointer)
        XCTAssertFalse(currentKeyboard.consumeInitialFocus(currentEventType: .keyDown))
    }

    @MainActor
    func testPointerCleanupIsOneShotAcrossBridgeRecreation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))

        let state = SheetInitialFocusState(origin: .pointer)
        let first = SheetInitialFocus.Watcher(state: state)
        first.applyInitialFocus(to: window, currentEventType: .leftMouseUp)
        XCTAssertTrue(window.firstResponder === window)
        XCTAssertTrue(window.makeFirstResponder(field))
        let selected = window.firstResponder

        let recreated = SheetInitialFocus.Watcher(state: state)
        recreated.applyInitialFocus(to: window, currentEventType: .leftMouseUp)
        XCTAssertTrue(window.firstResponder === selected,
            "Recreation and later reactivation must retain the user's keyboard target")
    }

    @MainActor
    func testKeyboardAndUnknownPresentationsPreserveInitialResponderAndWindowPolicy() {
        for origin in [SheetPresentationOrigin.keyboard, .unknown] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
            window.contentView?.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let selected = window.firstResponder
            let frame = window.frame, mask = window.styleMask, minimum = window.contentMinSize
            let bridge = SheetInitialFocus.Watcher(state: SheetInitialFocusState(origin: origin))
            bridge.applyInitialFocus(to: window, currentEventType: .leftMouseUp)
            XCTAssertTrue(window.firstResponder === selected)
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(window.styleMask, mask)
            XCTAssertEqual(window.contentMinSize, minimum)
            window.close()
        }
    }
}
