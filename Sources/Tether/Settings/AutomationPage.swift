import SwiftUI
import TetherCore

/// The `tether` command and `tether://` URLs, for scripts, agents and the Shortcuts app.
struct AutomationPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle(L("Install the tether command", "터미널 명령 설치"),
                       isOn: Binding(get: { model.cliInstalled }, set: { model.setCLIInstalled($0) }))
                if let location = model.cliLocation {
                    LabeledContent(L("Location", "위치")) {
                        Text(location.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                CommandRows(rows: [
                    ("tether status", L("current state · --json", "지금 상태 · --json")),
                    ("tether on | off | toggle", L("turn on · off · flip", "켜기 · 끄기 · 전환")),
                    ("tether sleep", L("sleep now", "지금 잠자기")),
                    ("tether hold 1h30m", L("stay awake on battery · hold off", "배터리에서도 유지 · hold off")),
                    ("tether run -- <cmd>", L("stay awake until the command finishes", "명령이 끝날 때까지 유지")),
                    ("tether diagnose --record", L("a troubleshooting report", "문제 해결용 보고서")),
                ])
            } header: {
                Text(L("Terminal", "터미널"))
            } footer: {
                Note(L("It links into ~/.local/bin when that folder exists, otherwise /usr/local/bin (asks for your password). Scripts and agents can use it too; it waits up to 3 seconds for the helper to apply a change.",
                       "~/.local/bin이 있으면 그곳에, 없으면 /usr/local/bin에 연결해요(관리자 암호 필요). 스크립트나 에이전트에서도 쓸 수 있고, 도우미가 적용할 때까지 최대 3초 기다려요."))
            }

            Section {
                CommandRows(rows: [
                    ("tether://sleep", L("sleep now", "지금 잠자기")),
                    ("tether://toggle", L("flip on/off (also on, off)", "켜기 · 끄기 전환 (on, off)")),
                    ("tether://hold/90m", L("battery hold · hold/off", "배터리 유지 · hold/off")),
                ])
            } header: {
                Text(L("URLs · Shortcuts App", "URL · 단축어"))
            } footer: {
                Note(L("Use them with the Shortcuts app's “Open URL” action. Opening one from a browser asks first.",
                       "단축어 앱의 'URL 열기' 동작에 넣으면 돼요. 브라우저에서 이런 링크를 열면 macOS가 먼저 물어봐요."))
            }
        }
    }
}
