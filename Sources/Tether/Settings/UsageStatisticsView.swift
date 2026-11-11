import SwiftUI
import TetherCore

struct UsageStatisticsView: View {
    @ObservedObject var model: AppModel
    @State private var scopeDetailsExpanded = false

    private var days: [DayStats] { model.localUsageStats.week(now: Date()) }
    private var hasRecords: Bool {
        days.contains { $0.lidClosedSeconds > 0 || ($0.holdSeconds ?? 0) > 0 || $0.heatGuards > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if let issue = model.usageStatisticsIssue {
                Note(issue == "stored-statistics-unreadable"
                     ? L("Saved statistics could not be read. The original record is preserved; new totals remain in memory.",
                         "저장된 통계를 읽지 못했습니다. 원본은 보존하며 새 통계는 메모리에만 기록합니다.")
                     : L("Statistics could not be saved. Work and stop controls remain available.",
                         "통계를 저장하지 못했습니다. 작업 유지·종료 조작은 계속 사용할 수 있습니다."))
                    .accessibilityIdentifier("usage-statistics-storage-issue")
            }
            if hasRecords {
                HStack(alignment: .top, spacing: 12) {
                    summary(L("Lid closed", "덮개를 닫고 유지"),
                            value: Texts.duration(days.reduce(0) { $0 + $1.lidClosedSeconds }))
                    summary(L("On battery", "배터리에서 유지"),
                            value: Texts.duration(days.reduce(0) { $0 + ($1.holdSeconds ?? 0) }))
                    summary(L("Heat stops", "고온 보호 중지"),
                            value: String(days.reduce(0) { $0 + $1.heatGuards }))
                }
                Divider().padding(.vertical, 2)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        Text(L("Date", "날짜"))
                        Text(L("Lid closed", "덮개 닫힘"))
                        Text(L("On battery", "배터리 유지"))
                    }.foregroundStyle(Color.tetherSecondary)
                    ForEach(days.reversed(), id: \.day) { day in
                        GridRow {
                            Text(String(day.day.suffix(5)))
                            Text(Texts.duration(day.lidClosedSeconds))
                            Text(Texts.duration(day.holdSeconds ?? 0))
                        }.monospacedDigit()
                    }
                }.font(TetherTypography.secondary)
            } else {
                Note(L("No duration recorded yet. Statistics start after Tether confirms keep-awake.",
                       "기록된 유지 시간이 없습니다. Tether의 유지가 확인되면 통계를 남깁니다."))
            }
            SettingsDisclosure(title: L("Recording scope", "기록 범위"),
                isExpanded: $scopeDetailsExpanded, groupsSection: false) {
                Note(L("Local observations for 7 days; sleep, missing readings and unconfirmed work are not estimated.",
                       "7일간의 로컬 관측값이며 잠자기·관측 공백·미확인 유지는 추정하지 않습니다."))
            }.accessibilityIdentifier("usage-statistics-scope-details")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-statistics-content")
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(TetherTypography.section).monospacedDigit()
            Text(title).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
