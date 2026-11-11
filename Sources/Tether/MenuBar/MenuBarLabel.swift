import SwiftUI
import TetherCore

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock

    static let timerTextWidth: CGFloat = 42

    var body: some View {
        let item = model.menuBarItem(at: clock.now)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(item))
                .frame(width: 18, height: 20)
            if let text = item.text {
                Text(text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit().lineLimit(1)
                    .frame(width: Self.timerTextWidth, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
            .frame(height: 20)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Tether")
            .accessibilityIdentifier("tether-status-item")
            .accessibilityValue([model.presentation.title, item.text].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(L("Open work controls and settings", "작업 유지 조작과 설정을 엽니다"))
    }
}
