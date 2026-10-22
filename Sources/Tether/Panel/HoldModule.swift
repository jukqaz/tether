import SwiftUI
import TetherCore

/// The compact panel's hold control: the ring empties as time runs out; click to end.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "timer")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.orange)
        }
        .frame(width: 16, height: 16)
    }
}

/// The running hold in the compact panel: a ring and the time left; click to end.
struct CompactHold: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock

    var body: some View {
        let left = model.batteryHoldUntil.map { Texts.countdown($0.timeIntervalSince(clock.now)) } ?? ""
        HStack(spacing: 8) {
            ProgressRing(fraction: model.holdRemainingFraction(at: clock.now))
            Text(left)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel(L("Time remaining", "남은 시간"))
                .accessibilityValue(left)
            Button { model.cancelBatteryHold() } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("End battery hold", "지금 끝내기"))
            .help(L("End battery hold", "지금 끝내기"))
        }
        .padding(.leading, 10).padding(.trailing, 3)
        .frame(height: 34)
        .modifier(Capsuled(color: .orange))
        .help(L("Battery hold: \(left) left", "배터리 사용 \(left) 남음"))
    }
}
