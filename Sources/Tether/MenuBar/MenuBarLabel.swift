import SwiftUI

/// The status item; redrawn every second only while a battery hold counts down.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock

    var body: some View {
        Image(nsImage: MenuBarIcon.image(model.menuBarItem(at: clock.now)))
            .accessibilityLabel("Tether: " + model.presentation.title)
    }
}
