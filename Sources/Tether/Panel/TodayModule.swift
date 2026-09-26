import Charts
import SwiftUI
import TetherCore

/// Today's lid-closed time with a bar per day, and the one line worth a glance: the lid session
/// that just ended, how the last sleep went, or how warm the lid-closed battery ran. (The lid
/// session is also a notification, and History keeps them all.)
struct TodayModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let today = model.today
        let week = model.week
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(L("Today", "오늘"), systemImage: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L("Lid closed \(Texts.total(today.lidClosedSeconds))", "덮개 닫고 \(Texts.total(today.lidClosedSeconds))"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let line = detail(today) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Chart(Array(week.enumerated()), id: \.offset) { index, day in
                BarMark(x: .value(L("Day", "날짜"), index), y: .value(L("Hours", "시간"), day.lidClosedSeconds / 3600), width: 6)
                    .foregroundStyle(index == week.count - 1 ? Color.tetherMint : Color.tetherMint.opacity(0.45))
                    .clipShape(.capsule)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, (week.map(\.lidClosedSeconds).max() ?? 0) / 3600))
            .frame(width: 76, height: 32)
            .help(L("Last 7 days, today on the right", "최근 7일, 오른쪽이 오늘"))
        }
        .padding(Metrics.padding)
        .surface(radius: Metrics.radius)
    }

    private func detail(_ day: DayStats) -> String? {
        if let session = model.visibleSession {
            var parts = [L("Just closed \(Texts.duration(session.duration))", "방금 덮개 닫음 \(Texts.duration(session.duration))")]
            if let peak = session.maxTemperature { parts.append(L(String(format: "peak %.1f°", peak), String(format: "최고 %.1f°", peak))) }
            if let a = session.batteryStart, let b = session.batteryEnd, a != b { parts.append("\(a)→\(b)%") }
            return parts.joined(separator: " · ")
        }
        if let last = model.lastSleep, let drain = last.drainPerHour {
            return L(String(format: "Last sleep %@ · %.1f%%/h (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain)),
                     String(format: "지난 잠 %@ · 시간당 %.1f%% (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain)))
        }
        if let stats = day.closedTemps, let average = stats.average, let peak = stats.max {
            return L(String(format: "Lid closed: battery avg %.0f°C · peak %.1f°C", average, peak),
                     String(format: "덮개 닫힘 배터리 평균 %.0f°C · 최고 %.1f°C", average, peak))
        }
        if day.forcedSleeps > 0 { return L("put to sleep \(day.forcedSleeps)×", "잠재움 \(day.forcedSleeps)회") }
        return nil
    }
}
