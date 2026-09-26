import Charts
import SwiftUI
import TetherCore

struct HistoryPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let week = model.week
        let hasTemperatures = week.contains { $0.closedTemps != nil || $0.openTemps != nil }
        let sleeps = Array(model.sleepLog.recent.suffix(6).reversed())
        let sessions = Array((model.usage?.recentSessions ?? []).suffix(5).reversed())
        Page {
            Section {
                if hasTemperatures {
                    TemperatureChart(week: week, closedLimit: model.safetyLimits(lidClosed: true).hardTemperature,
                                     openLimit: model.safetyLimits(lidClosed: false).hardTemperature)
                        .padding(.vertical, 6)
                } else {
                    Text(L("Nothing yet. The helper records the battery temperature every 30 seconds.",
                           "아직 기록이 없어요. 도우미가 30초마다 배터리 온도를 기록해요."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Daily Peak Battery Temperature · Last 7 Days", "하루 최고 배터리 온도 · 최근 7일"))
            } footer: {
                Note(L("Dashed lines are your battery-hold limits. The further below them, the more headroom.",
                       "점선은 지금 설정한 배터리 유지 한계예요. 선이 한계에서 멀수록 여유가 있어요."))
            }

            Section {
                if sleeps.isEmpty {
                    Text(L("Nothing yet. Sleeps appear here after the Mac wakes.", "아직 기록이 없어요. 잠들었다 깨면 여기에 남아요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sleeps, id: \.sleptAt) { SleepRow(record: $0) }
                }
            } header: {
                HStack {
                    Text(L("Recent Sleeps", "최근 잠자기"))
                    Spacer()
                    if let average = model.sleepLog.averageDrain {
                        Text(L(String(format: "avg %.1f%%/h · %@", average, Texts.drainLevel(average)),
                               String(format: "평균 시간당 %.1f%% · %@", average, Texts.drainLevel(average))))
                            .foregroundStyle(average >= SleepLog.highDrain ? .red : .secondary)
                    }
                }
            } footer: {
                Note(L("Charge per hour is worked out for sleeps of 30 minutes or more on battery. 1–2% an hour is typical; over 3% means something keeps waking it.",
                       "배터리로 30분 넘게 잠든 경우만 시간당 사용량을 계산해요. 보통 시간당 1~2%이고, 3%를 넘으면 무언가 자꾸 깨우는 거예요."))
            }

            Section {
                if sessions.isEmpty {
                    Text(L("Nothing yet. Keeping the lid closed for 5 minutes or more records a session.",
                           "아직 기록이 없어요. 덮개를 5분 넘게 닫아 두면 여기에 남아요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.start) { SessionRow(session: $0) }
                }
            } header: {
                InfoLabel(L("Recent Lid Sessions", "최근 덮개 세션"), info: SettingsInfo.lidSessions)
            }

            Section {
                let total = week.reduce(0) { $0 + $1.lidClosedSeconds }
                LabeledContent(L("Awake with the lid closed", "덮개 닫고 깨어 있던 시간")) { Text(Texts.total(total)) }
                LabeledContent(L("Put to sleep by Tether", "Tether가 재운 횟수")) {
                    Text(L("\(week.reduce(0) { $0 + $1.forcedSleeps })×", "\(week.reduce(0) { $0 + $1.forcedSleeps })회"))
                }
                LabeledContent(L("Battery holds", "배터리 유지")) {
                    Text(L("\(week.reduce(0) { $0 + $1.batteryHolds })×", "\(week.reduce(0) { $0 + $1.batteryHolds })회"))
                }
                LabeledContent(L("Heat guard", "발열 보호")) {
                    Text(L("\(week.reduce(0) { $0 + $1.heatGuards })×", "\(week.reduce(0) { $0 + $1.heatGuards })회"))
                }
            } header: {
                Text(L("Last 7 Days", "최근 7일"))
            } footer: {
                Note(L("Records stay on this Mac: stats for 7 days, the last 20 sleeps, the last 10 lid sessions.",
                       "기록은 이 Mac에만 저장돼요. 통계는 7일, 잠자기는 최근 20번, 덮개 세션은 최근 10개까지 보관해요."))
            }
        }
    }
}

struct TemperatureChart: View {
    let week: [DayStats]
    let closedLimit: Double
    let openLimit: Double

    private struct Point: Identifiable {
        let id: String
        let day: String
        let state: String
        let value: Double
    }

    var body: some View {
        let closedName = L("lid closed", "덮개 닫힘"), openName = L("lid open", "덮개 열림")
        let labels = week.indices.map { $0 == week.count - 1 ? L("Today", "오늘") : Self.weekday(week[$0].day) }
        let points: [Point] = week.indices.flatMap { i -> [Point] in
            var out: [Point] = []
            if let peak = week[i].closedTemps?.max { out.append(Point(id: "\(i)c", day: labels[i], state: closedName, value: peak)) }
            if let peak = week[i].openTemps?.max { out.append(Point(id: "\(i)o", day: labels[i], state: openName, value: peak)) }
            return out
        }
        Chart {
            ForEach(points) { p in
                LineMark(x: .value(L("Day", "날짜"), p.day), y: .value(L("Peak", "최고 온도"), p.value), series: .value(L("State", "상태"), p.state))
                    .foregroundStyle(by: .value(L("State", "상태"), p.state))
                    .interpolationMethod(.monotone)
                PointMark(x: .value(L("Day", "날짜"), p.day), y: .value(L("Peak", "최고 온도"), p.value))
                    .foregroundStyle(by: .value(L("State", "상태"), p.state))
                    .symbolSize(26)
            }
            RuleMark(y: .value(L("Lid-closed limit", "덮개 닫힘 한계"), closedLimit))
                .foregroundStyle(Color.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .trailing) {
                    Text(L("lid-closed limit \(Int(closedLimit))°", "덮개 닫힘 한계 \(Int(closedLimit))°")).font(.caption2).foregroundStyle(.orange)
                }
            RuleMark(y: .value(L("Lid-open limit", "덮개 열림 한계"), openLimit))
                .foregroundStyle(Color.blue.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text(L("lid-open limit \(Int(openLimit))°", "덮개 열림 한계 \(Int(openLimit))°")).font(.caption2).foregroundStyle(.blue)
                }
        }
        .chartForegroundStyleScale([closedName: Color.orange, openName: Color.blue])
        .chartXScale(domain: labels)
        .chartYScale(domain: 25...48)
        .chartYAxis {
            AxisMarks(position: .leading, values: [30, 35, 40, 45]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))°") }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 180)
    }

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Localization.current == .korean ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US")
        f.dateFormat = "E"
        return f
    }()

    static func weekday(_ key: String) -> String {
        keyFormat.date(from: key).map { weekdayFormat.string(from: $0) } ?? key
    }
}

struct SleepRow: View {
    let record: SleepRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.byTether ? "moon.zzz.fill" : "moon.fill")
                .foregroundStyle(.indigo)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.when(record.sleptAt)) · \(Texts.duration(record.duration ?? 0))")
                    .font(.callout.weight(.medium))
                Text(causes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(battery)
                    .font(.callout)
                    .monospacedDigit()
                if let drain = record.drainPerHour {
                    Text(L(String(format: "%.1f%%/h", drain), String(format: "시간당 %.1f%%", drain)))
                        .font(.caption)
                        .foregroundStyle(drain >= SleepLog.highDrain ? .red : (drain >= 1.5 ? .orange : .secondary))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var causes: String {
        var text = "\(Texts.sleepCause(record)) → \(Texts.wakeCause(record))"
        if record.darkWakes > 0 { text += L(" · woke \(record.darkWakes)× in between", " · 중간에 \(record.darkWakes)번 깸") }
        return text
    }

    private var battery: String {
        guard record.onBatteryBefore, record.onBatteryAfter == true else { return L("on power", "전원 연결") }
        guard let a = record.percentBefore, let b = record.percentAfter else { return "–" }
        return "\(a)→\(b)%"
    }

    static func when(_ t: Double) -> String {
        Texts.dateTime(Date(timeIntervalSince1970: t))
    }
}

struct SessionRow: View {
    let session: LidSession

    var body: some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Texts.duration(session.duration))
                    .monospacedDigit()
                Text(SleepRow.when(session.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let t = session.maxTemperature { parts.append(L(String(format: "peak %.1f°C", t), String(format: "최고 %.1f°C", t))) }
        if let a = session.batteryStart, let b = session.batteryEnd, a != b { parts.append("\(a)→\(b)%") }
        if session.lowPower { parts.append(L("Low Power Mode", "저전력 모드")) }
        if session.onBattery { parts.append(L("battery", "배터리")) }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }
}
