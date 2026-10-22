import SwiftUI
import TetherCore

/// Facts and their effect first; provenance is available without filling the page with warnings.
struct DisplayFindingsView: View {
    let report: DisplayReport
    var body: some View {
        SettingsCard(title: L("Display connections & cause", "화면 연결과 동작 이유"), symbol: "display.2") {
            Text(report.summary).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Note(report.guidance)
            ForEach(report.displays) { display in
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label(display.name, systemImage: display.kind == .builtIn ? "laptopcomputer" : display.kind == .virtual ? "rectangle.on.rectangle" : "display")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(display.detail).font(.caption).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
            DisclosureGroup(L("How this was identified", "판정 근거 보기")) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(report.displays) { display in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(display.name).font(.caption.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Note(display.evidence)
                        }
                    }
                    if let issue = report.issue { Note(issue) }
                    Note(L("Read from the current macOS display list and System Information. A running remote app alone does not prove a remote session, and display IDs do not prove panel power-off.", "macOS의 현재 화면 목록과 시스템 정보를 대조했습니다. 원격 앱 실행만으로 접속 중이라고 판정하지 않으며, 화면 식별값만으로 패널 전원 차단을 단정하지 않습니다."))
                }.padding(.top, 8)
            }.font(.callout)
        }
    }
}
