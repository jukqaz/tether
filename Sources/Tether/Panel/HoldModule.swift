import SwiftUI
import TetherCore

/// Keep clamshell on battery for a while: durations in a menu, then a countdown to the second.
struct HoldModule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let until = model.batteryHoldUntil {
                let left = Texts.countdown(until.timeIntervalSince(clock.now))
                HStack(spacing: 5) {
                    Image(systemName: "bag.fill")
                    Text(model.holdingOnBattery ? L("On battery", "배터리로 유지") : L("Armed", "유지 예약됨"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.cancelBatteryHold() } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(3)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(L("End the battery hold", "배터리 유지 끄기"))
                    .accessibilityLabel(L("End battery hold", "배터리 유지 끄기"))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                Text(left)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.25), value: left)
                    .accessibilityLabel(L("\(left) left", "\(left) 남음"))
                HoldBar(fraction: model.holdRemainingFraction(at: clock.now))
                HStack(spacing: 4) {
                    Text(untilLine(until))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(limitLine)
                    Spacer(minLength: 0)
                    if model.canExtendHold(minutes: 30) {
                        Button(L("+30m", "+30분")) { model.extendBatteryHold(minutes: 30) }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: .capsule)
                            .help(L("Stay awake 30 minutes longer, up to 4 hours from the start",
                                    "30분 더 유지해요. 시작부터 최대 4시간까지"))
                    }
                }
            } else {
                Label(L("Battery hold", "배터리 유지"), systemImage: "bag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(L("Safe in a bag", "가방에 넣어도 돼요"))
                    .font(.callout.weight(.semibold))
                if model.canStartHold {
                    Text(L("\(model.batteryFloor)% · sleeps if hot", "\(model.batteryFloor)% · 뜨거우면 잠들어요"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Menu(L("Start", "켜기")) {
                        ForEach(model.holdChoices, id: \.self) { minutes in
                            Button(Texts.duration(TimeInterval(minutes * 60))) {
                                model.startBatteryHold(minutes: minutes)
                            }
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)
                } else {
                    Text(L("Ready once charged above \(model.batteryFloor)%", "\(model.batteryFloor)% 넘게 충전되면 쓸 수 있어요"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(tint: .orange, strength: model.batteryHoldUntil == nil ? 0.12 : 0.30, radius: Metrics.radius)
        .help(L("Stays awake on battery with the lid closed, even in a bag. Sleeps first if a safety limit is reached.",
                "덮개를 닫고 가방에 넣어도 배터리로 깨어 있어요. 안전 기준에 걸리면 먼저 잠들어요."))
    }

    /// "until 21:02", plus who armed it when it wasn't this panel.
    private func untilLine(_ until: Date) -> String {
        let time = Texts.time(until)
        return [L("until \(time)", "\(time)까지"), model.holdSourceText].compactMap { $0 }.joined(separator: " · ")
    }

    private var limitLine: String {
        let limits = model.safetyLimits(lidClosed: model.snapshot.lidClosed)
        return L("Sleeps sooner at \(Int(limits.hardTemperature))°C or \(model.batteryFloor)%",
                 "\(Int(limits.hardTemperature))°C나 \(model.batteryFloor)%가 되면 먼저 잠들어요")
    }
}

/// How much of the hold is left, as a thin bar.
struct HoldBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.orange.opacity(0.22))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(.orange).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.9), value: fraction)
    }
}

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
            Image(systemName: "bag.fill")
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
        Button { model.cancelBatteryHold() } label: {
            HStack(spacing: 6) {
                ProgressRing(fraction: model.holdRemainingFraction(at: clock.now))
                Text(left)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .modifier(Capsuled(color: .orange))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(L("Battery hold: \(left) left", "배터리 유지 \(left) 남음")
              + (model.holdSourceText.map { " · \($0)" } ?? "") + L(" · click to end", " · 누르면 끄기"))
        .accessibilityLabel(L("End battery hold, \(left) left", "배터리 유지 끄기, \(left) 남음"))
    }
}
