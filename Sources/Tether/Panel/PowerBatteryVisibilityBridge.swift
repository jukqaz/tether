import AppKit
import SwiftUI

/// SwiftUI can keep a MenuBarExtra's view alive after its window is hidden.
/// Collection follows actual window visibility, not construction of a layout candidate.
struct PowerBatteryVisibilityBridge: NSViewRepresentable {
    let monitor: PowerBatteryMonitor

    func makeNSView(context: Context) -> VisibilityReader {
        VisibilityReader(monitor: monitor)
    }
    func updateNSView(_ view: VisibilityReader, context: Context) { view.updateMonitor(monitor) }
    static func dismantleNSView(_ view: VisibilityReader, coordinator: ()) { view.disconnect() }

    final class VisibilityReader: NSView {
        private var monitor: PowerBatteryMonitor
        // A retiring native view must never remove its replacement's subscription.
        private let client = UUID()
        private var observers: [NSObjectProtocol] = []
        private var revision: UInt64 = 0
        init(monitor: PowerBatteryMonitor) {
            self.monitor = monitor
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        func updateMonitor(_ value: PowerBatteryMonitor) {
            if monitor !== value {
                let previous = monitor, client = client
                DispatchQueue.main.async { previous.setVisible(false, client: client) }
                monitor = value
            }
            scheduleVisibility()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name,
                        object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.scheduleVisibility() }
                        })
                }
            }
            scheduleVisibility()
        }
        override func viewDidHide() { super.viewDidHide(); scheduleVisibility() }
        override func viewDidUnhide() { super.viewDidUnhide(); scheduleVisibility() }
        func scheduleVisibility() {
            revision &+= 1
            let current = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.revision else { return }
                let visible = self.window?.isVisible == true
                    && self.window?.occlusionState.contains(.visible) == true
                    && !self.isHiddenOrHasHiddenAncestor
                self.monitor.setVisible(visible, client: self.client)
            }
        }
        func disconnect() {
            revision &+= 1
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            let monitor = monitor, client = client
            DispatchQueue.main.async { monitor.setVisible(false, client: client) }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
