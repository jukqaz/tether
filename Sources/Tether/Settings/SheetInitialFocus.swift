import AppKit
import SwiftUI

/// Capture the invocation before sheet presentation changes the current event.
/// Programmatic and unclassified events must never be treated as pointer input.
enum SheetPresentationOrigin: Equatable {
    case pointer, keyboard, unknown

    init(eventType: NSEvent.EventType?) {
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            self = .pointer
        case .keyDown, .keyUp:
            self = .keyboard
        default:
            self = .unknown
        }
    }
}

/// Shared by the sheet's view and its bridge so representable recreation does
/// not clear a keyboard target after the initial presentation.
@MainActor
final class SheetInitialFocusState: ObservableObject {
    let origin: SheetPresentationOrigin
    private(set) var handled = false
    private var keyboardInteraction = false

    init(origin: SheetPresentationOrigin) { self.origin = origin }

    func noteKeyboardInteraction() { keyboardInteraction = true }

    func consumeInitialFocus(currentEventType: NSEvent.EventType?) -> Bool {
        guard !handled else { return false }
        handled = true
        return origin == .pointer && !keyboardInteraction
            && SheetPresentationOrigin(eventType: currentEventType) != .keyboard
    }
}

/// Only responder focus crosses the AppKit boundary. Window chrome, geometry,
/// key handling and the application's activation policy remain native.
struct SheetInitialFocus: NSViewRepresentable {
    let state: SheetInitialFocusState

    func makeNSView(context: Context) -> Watcher { Watcher(state: state) }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        private let state: SheetInitialFocusState
        private var keyObserver: NSObjectProtocol?
        private var keyboardMonitor: Any?

        init(state: SheetInitialFocusState) {
            self.state = state
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservation()
            guard let window, !state.handled else { return }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleInitialFocus() }
                }
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = self.window,
                       event.window == nil || event.window === window || event.window === window.sheetParent {
                        self.state.noteKeyboardInteraction()
                    }
                }
                return event
            }
            scheduleInitialFocus()
        }

        private func scheduleInitialFocus() {
            guard let window, window.sheetParent != nil, window.isKeyWindow, !state.handled else { return }
            // The native host assigns its initial responder during presentation.
            // Reconcile once on the next turn, after that assignment.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      window.sheetParent != nil, window.isKeyWindow else { return }
                self.applyInitialFocus(to: window, currentEventType: NSApp.currentEvent?.type)
                self.removeObservation()
            }
        }

        func applyInitialFocus(to window: NSWindow, currentEventType: NSEvent.EventType?) {
            if state.consumeInitialFocus(currentEventType: currentEventType) {
                window.makeFirstResponder(nil)
            }
        }

        private func removeObservation() {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
            keyboardMonitor = nil
        }

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        }
    }
}
