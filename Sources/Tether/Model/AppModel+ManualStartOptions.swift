import Foundation
import TetherCore

@MainActor
extension AppModel {
    func manualStartSelectionDuration(_ selection: ManualStartSelection, now: Date = Date()) -> TimeInterval? {
        guard canStartManualSession else { return nil }
        return selection.duration(at: now, maximum: Double(manualMaximumMinutes) * 60)
    }
    @discardableResult
    func startManualSelection(_ selection: ManualStartSelection, now: Date = Date()) -> Bool {
        guard let seconds = manualStartSelectionDuration(selection, now: now) else { return false }
        return startManualDuration(seconds)
    }
}
