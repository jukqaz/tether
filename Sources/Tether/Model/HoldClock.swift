import Foundation

/// A one-second tick that runs only while a battery hold counts down, kept apart from
/// `AppModel` so the tick redraws the countdown and the menu bar, not every view.
@MainActor
final class HoldClock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?
    private var deadline: Date?

    func run(until deadline: Date?) {
        guard let deadline, deadline > Date() else {
            stop()
            return
        }
        guard deadline != self.deadline else { return }
        stop()
        self.deadline = deadline
        now = Date()
        // Fire just after each whole second before the deadline, when the countdown changes.
        let offset = deadline.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        let next = (Date().timeIntervalSinceReferenceDate - offset).rounded(.up) + offset + 0.02
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }
}
