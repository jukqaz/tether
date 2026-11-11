import SwiftUI
import TetherCore

/// Informational for compatible work assertions. Amber is reserved for opposing display intent.
struct PowerRequestsNotice: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: PowerRequestMonitor
    var compact = false
    var showsDetail = true
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let requests = PowerActivityPolicy.requests((monitor.blockers ?? []).filter { !monitor.systemPIDs.contains($0.pid) }, displaySleepExpected: model.expectsDisplaySleep)
        let opposing = requests.contains(where: \.opposesDisplaySleep)
        let names = requests.prefix(2).map(\.process).joined(separator: ", ")
        let more = requests.count > 2 ? L(" and \(requests.count - 2) more", " 외 \(requests.count - 2)개") : ""
        let title = monitor.blockers == nil ? L("Sleep requests unavailable", "앱 요청을 확인하지 못함")
            : opposing ? L("An app may prevent display sleep", "화면 끄기를 방해할 수 있는 앱")
            : L("Keep-awake: \(names)\(more)", "유지 요청: \(names)\(more)")
        let detail = monitor.blockers == nil ? L("Open to check again", "점검 화면에서 다시 확인하세요")
            : L("Review requests and app settings", "앱별 요청과 설정 방법 보기")
        if !requests.isEmpty || (monitor.checkedAt != nil && monitor.blockers == nil) {
            Button {
                let origin = SheetPresentationOrigin(eventType: NSApp.currentEvent?.type)
                if compact {
                    if !model.developmentService { NSApp.activate(); openSettings() }
                    dismiss()
                }
                model.presentActivityReview(origin: origin)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: opposing ? "exclamationmark.circle" : "moon.zzz")
                        .foregroundStyle(opposing ? Color.tetherWarning : Color.tetherSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if !compact && showsDetail {
                            Text(detail)
                                .font(.caption).foregroundStyle(Color.tetherSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L("Review other app sleep requests", "다른 앱의 잠자기 방지 요청 확인"))
            .accessibilityLabel(title)
            .accessibilityHint(L("Open the app and display review", "앱·화면 점검 창을 엽니다"))
        }
    }
}
