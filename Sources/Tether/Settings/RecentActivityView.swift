import SwiftUI
import TetherCore

/// Reads only while opened or explicitly refreshed, never starts a polling timer.
struct RecentActivityView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    @State private var busy = false
    @State private var events: [ActivityEvent] = []
    private struct Row: Identifiable {
        let id: String
        let date: Date
        let title: String
        let symbol: String
        let detail: String?
    }
    private var rows: [Row] {
        if model.usesUserSession {
            return model.commonActivity.prefix(20).map {
                Row(id: "common-\($0.id)", date: $0.date, title: presentationTitle($0),
                    symbol: $0.kind == .marker ? "flag" : "circle.dotted", detail: $0.detail)
            }
        }
        return events.prefix(20).map { Row(id: "helper-\($0.id)", date: $0.date, title: $0.kind.title, symbol: $0.kind.symbol, detail: nil) }
    }
    private func presentationTitle(_ event: UserSessionActivity.Entry) -> String {
        // Keep a protection-specific title supplied by the evidence layer.
        guard event.title == event.kind.title else { return event.title }
        switch event.kind {
        case .decision: return L("Work settings or conditions changed", "작업 유지 설정·조건 변경")
        case .applied: return L("Keep-awake request verified", "작업 유지 요청 적용 확인")
        case .released: return L("Keep-awake request released or unconfirmed", "작업 유지 요청 해제 또는 미확인")
        case .detail: return L("Work observations recorded", "작업 유지 관측값 기록")
        default: return event.title
        }
    }

    init(model: AppModel, initiallyExpanded: Bool = false) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        SettingsDisclosure(title: L("Recent activity", "최근 동작"),
            isExpanded: $expanded, groupsSection: false) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                HStack {
                    Note(model.usesUserSession
                         ? L("Latest 20 retained work events", "보관된 최근 작업 동작 20개")
                         : L("Latest 20 retained log events", "보관된 로그의 최근 동작 20개"))
                    Spacer(minLength: 8)
                    Button(L("Refresh", "새로고침")) { Task { await refresh() } }.disabled(busy)
                }
                if let issue = model.v4DecisionHistoryIssue {
                    Note(issue).accessibilityIdentifier("recent-activity-storage-note")
                }
                if model.developmentService { PreviewNotice() }
                if busy { ProgressView().controlSize(.small) }
                else if rows.isEmpty { Note(L("No readable events yet. Check Logs and reports for available evidence.", "읽을 수 있는 동작 기록이 없습니다. 로그와 보고서에서 확인할 수 있습니다.")) }
                else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: event.symbol).frame(width: 18).foregroundStyle(Color.tetherSecondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(event.title).font(TetherTypography.settingsBody)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                            .font(TetherTypography.settingsSecondary).foregroundStyle(Color.tetherSecondary)
                                            .monospacedDigit().fixedSize()
                                    }
                                    if let detail = event.detail {
                                        Text(detail).font(TetherTypography.settingsSecondary).foregroundStyle(Color.tetherSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.accessibilityElement(children: .combine)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("recent-activity-\(event.id)")
                        }
                    }.padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recent-activity-list")
                }
                Note(L("Sleep requests and transition notices do not prove physical sleep. Log rotation can leave gaps.", "잠자기 요청·전환 알림은 실제 절전 완료의 증거가 아닙니다. 로그 순환 보관으로 일부 기록이 없을 수 있습니다."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recent-activity-disclosure")
        .task(id: expanded) { if expanded { await refresh() } }
    }
    private func refresh() async {
        guard !busy else { return }
        guard !model.usesUserSession else { events = []; return }
        busy = true
        let path = model.activityLogPath
        let result = await Task.detached(priority: .utility) { RecentActivity.read(path: path) }.value
        guard !Task.isCancelled, !model.usesUserSession, path == model.activityLogPath else { busy = false; return }
        events = result; busy = false
    }
}
