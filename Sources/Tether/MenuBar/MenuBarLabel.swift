import SwiftUI
import TetherCore

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var clock: HoldClock // Scene-call compatibility; the status item has no countdown tick.

    var body: some View {
        Image(nsImage: MenuBarIcon.image(model.menuBarItem(at: Date())))
            .frame(width: 18, height: 20)
            .accessibilityLabel("Tether")
            .accessibilityIdentifier("tether-status-item")
            .accessibilityValue(model.presentation.title)
            .accessibilityHint(L("Open work controls and settings", "작업 유지 조작과 설정을 엽니다"))
    }
}
