import Foundation
import TetherCore

enum OptionDestination: String, Identifiable {
    case duration, manualDefaults, rules, currentWork, keep, power, app, notifications, lifecycle
    var id: String { rawValue }
    var actionTitle: String {
        switch self {
        case .duration: L("Choose a duration…", "시간 선택…")
        case .manualDefaults: L("Edit next-work defaults…", "다음 작업 기본값…")
        case .rules: L("Edit automatic rules…", "자동 규칙 설정…")
        case .currentWork: L("Open menu controls…", "메뉴 조작 열기…")
        case .keep: L("Keep-awake settings…", "유지 설정…")
        case .power: L("Power settings…", "전원 설정…")
        case .app: L("App settings…", "앱 설정…")
        case .notifications: L("Notification settings…", "알림 설정…")
        case .lifecycle: L("Configure event actions…", "이벤트 실행 설정…")
        }
    }
}
enum OptionReadiness { case connected, partial, notImplemented }

/// This inventory describes executable paths, not a collection of pretend switches.
struct OptionCatalogEntry: Identifiable {
    let id: String
    let title: String
    let summary: String
    let supportDetail: String?
    let readiness: OptionReadiness
    let destination: OptionDestination?
    let keywords: String
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { token in
            (id + " " + title + " " + summary + " " + (supportDetail ?? "") + " " + keywords)
                .localizedStandardContains(String(token))
        }
    }
}

enum OptionCatalog {
    static var entries: [OptionCatalogEntry] {
        func e(_ id: String, _ en: String, _ ko: String, _ detailEN: String, _ detailKO: String,
               _ ready: OptionReadiness, _ destination: OptionDestination?, _ keywords: String = "",
               support: (en: String, ko: String)? = nil) -> OptionCatalogEntry {
            .init(id: id, title: L(en, ko), summary: L(detailEN, detailKO),
                  supportDetail: support.map { L($0.en, $0.ko) },
                  readiness: ready, destination: destination, keywords: keywords)
        }
        return [
            e("O01", "Duration and end time", "시간과 끝날 시각", "Start with a preset, custom minutes or an end time.", "기본 시간·직접 입력·끝날 시각으로 시작합니다.", .partial, .duration, "timer 타이머", support: ("Presets, custom minutes and end time. Active-time counting is not connected.", "기본 시간·직접 입력·특정 시각으로 시작합니다. 활성 시간 계산은 아직 연결되지 않았습니다.")),
            e("O02", "Until work ends", "작업이 끝날 때까지", "Keep work awake until a linked command or process ends.", "연결한 명령이나 프로세스가 끝날 때까지 유지합니다.", .partial, .rules, "process app 다운로드 프로세스", support: ("CLI command/PID and explicit work events. Automatic download detection is unavailable.", "CLI 명령·PID·명시적 작업 이벤트를 지원합니다. 다운로드 자동 감지는 미지원입니다.")),
            e("O03", "Current timer controls", "현재 타이머 조작", "Add time, end a timer or pause automatic work in the menu.", "메뉴에서 시간 추가·타이머 종료·자동 쉬기를 조작합니다.", .partial, .currentWork, support: ("Add time, end timer or pause automatic. Replacing the active deadline is not connected.", "시간 추가·타이머 종료·자동 쉬기를 제공합니다. 실행 중 마감 교체는 아직 연결되지 않았습니다.")),
            e("O04", "End conditions", "종료 조건", "Choose what happens when power is disconnected.", "전원을 분리했을 때의 동작을 선택합니다.", .partial, .power, support: ("Time, power, battery and protection apply to the original request.", "시간·전원·배터리·보호에 따라 원래 요청을 종료합니다.")),
            e("O05", "After work ends", "작업이 끝나면", "Choose whether to request sleep after closed-lid work ends.", "닫힌 상태에서 유지가 끝나면 잠자기를 요청할지 정합니다.", .partial, .power, support: ("Let macOS decide or request sleep after closed-lid release. Other end actions are unavailable.", "macOS에 맡기거나 닫힌 상태 해제 후 잠자기를 요청합니다. 다른 종료 행동은 아직 미지원입니다.")),
            e("O06", "Device and schedule conditions", "장비·네트워크·일정 조건", "Add app, schedule, network or device conditions.", "앱·시간표·네트워크·장비를 자동 조건에 추가합니다.", .partial, .rules, "wifi usb bluetooth calendar 와이파이 달력", support: ("Apps, schedules, network and selected devices; each provider has its own permission and support.", "앱·시간표·네트워크·장비를 선택합니다. 제공자별 지원·권한을 따로 확인합니다.")),
            e("O07", "Activity conditions", "활동 조건", "Try CPU or network activity as an advanced condition.", "고급 조건으로 CPU·전송량을 시험할 수 있습니다.", .partial, .rules, support: ("CPU/network conditions are experimental. Camera, microphone and playback detection are unavailable.", "CPU·전송량은 실험 조건입니다. 카메라·마이크·재생 감지는 아직 미지원입니다.")),
            e("O08", "AI and remote work", "AI·원격 작업 연결", "Connect a tool that reports when work starts and ends.", "작업의 시작·종료를 알려주는 외부 도구를 연결합니다.", .partial, .rules, support: ("Explicit bounded work events are supported; remote presence and AI activity are not inferred.", "기한이 있는 명시 작업 이벤트를 지원합니다. 원격 연결·AI 활동을 자동 추정하지 않습니다.")),
            e("O09", "Rules and presets", "규칙과 프리셋", "Group automatic conditions and save reusable presets.", "자동 조건을 묶고 프리셋으로 저장합니다.", .connected, .rules, "AND OR trigger 트리거"),
            e("O10", "Closed-lid work", "덮개를 닫아도 계속 사용", "Choose closed-lid work and built-in display behavior.", "덮개를 닫아도 사용할지, 내장 화면을 어떻게 처리할지 정합니다.", .partial, .keep, "clamshell 클램쉘", support: ("Applies to valid work only. Helper preparation and actual application are checked separately.", "유효한 작업에만 적용합니다. 도우미 준비와 실제 적용은 별도로 확인합니다.")),
            e("O11", "Display and idle", "화면과 유휴", "Choose display, closed-lid and inactivity defaults for new manual work.", "다음 수동 작업의 화면·덮개·입력 대기 기본값을 정합니다.", .partial, .manualDefaults, support: ("Separate display/lid defaults and idle release apply to the next manual request only.", "화면·덮개 기본값과 유휴 화면 해제를 다음 수동 요청에만 적용합니다.")),
            e("O12", "Lock actions", "잠금 동작", "Automatic lock actions are not implemented. macOS password requirements still apply.", "자동 잠금 동작은 아직 구현되지 않았습니다. macOS 암호 요구는 계속 적용됩니다.", .notImplemented, nil),
            e("O13", "Keep activity status", "활동 상태 유지", "Synthetic keys, mouse movement and activity generation are not implemented.", "가짜 키·마우스 이동·활동 생성은 아직 구현되지 않았습니다.", .notImplemented, nil),
            e("O14", "Closed-lid environment", "덮개 중 환경 설정", "Speaker muting and changing Low Power Mode are not implemented.", "스피커 음소거·저전력 모드 변경은 아직 구현되지 않았습니다.", .notImplemented, nil),
            e("O15", "Protection", "기기 보호", "Set battery, thermal and Low Power Mode protection.", "배터리·열 상태·저전력 모드의 보호 기준을 정합니다.", .partial, .keep, support: ("Battery/time limits, OS thermal state and Low Power Mode stop. Fan/sensor controls are unavailable.", "배터리·시간 한도, OS 열 상태·저전력 중지를 제공합니다. 팬·센서 제어는 미지원입니다.")),
            e("O16", "Recovery", "보호 후 복구", "Choose manual or automatic resume after protection.", "보호 중지 후 직접 또는 자동으로 다시 시작할지 정합니다.", .connected, .keep),
            e("O17", "External controls", "외부 도구 제어", "Use commands, links or Shortcuts to control work.", "명령·링크·단축어로 유지를 조작합니다.", .partial, .app, "Shortcuts 단축어", support: ("CLI, URLs and App Intents share the common policy. AppleScript and MCP servers are unavailable.", "CLI·URL·App Intents는 공통 정책을 사용합니다. AppleScript·MCP 서버는 미지원입니다.")),
            e("O18", "Run on events", "이 일이 생기면 실행", "Send a webhook when a selected work event occurs.", "선택한 작업 이벤트가 생기면 Webhook을 보냅니다.", .partial, .lifecycle, "hook shell webhook", support: ("Bounded HTTPS webhooks are connected. Shell/Shortcut supervision is not implemented.", "시간 제한이 있는 HTTPS Webhook을 연결합니다. shell·Shortcut 감시자는 아직 미구현입니다.")),
            e("O19", "Wake schedules", "예약 깨우기", "Creating OS wake schedules is not implemented. Responding to Wake is a separate feature.", "OS 깨우기 일정 생성은 아직 구현되지 않았습니다. 깨어남 대응과 별개입니다.", .notImplemented, nil),
            e("O20", "Disk keep-awake", "디스크 유지", "The isolated driver is under test; native cleanup is not confirmed and activation is unavailable.", "격리 실행기를 검증 중입니다. 실제 정리를 확인하지 못해 아직 활성화할 수 없습니다.", .notImplemented, nil),
            e("O21", "Notifications and sound", "알림과 소리", "Choose timer and task notifications, warning time and sound.", "타이머·작업 알림과 만료 예고 시점·소리를 정합니다.", .partial, .notifications, support: ("Separate timer/task completion and expiry warning time/sound. Repeating reminders are unavailable.", "타이머·작업 종료 알림, 만료 예고 시점·소리를 구분합니다. 반복 알림은 아직 미지원입니다.")),
            e("O22", "Menu and controls", "메뉴와 조작", "Show the icon alone or include the time remaining.", "메뉴바에 아이콘만 또는 남은 시간도 표시합니다.", .partial, .app, support: ("Icon or remaining time. Custom menu layouts, global shortcuts and click actions are unavailable.", "아이콘·남은 시간 표시를 선택합니다. 자유 배치·전역 단축키·클릭 동작은 아직 미지원입니다.")),
            e("O23", "History and diagnostics", "통계와 진단", "Review usage, recent events, other app requests and reports.", "사용 통계·최근 동작·다른 앱 요청·보고서를 확인합니다.", .connected, .app),
            e("O24", "General and transfer", "일반·설정 이동", "Set language and startup, or import and export settings.", "언어·시작 동작을 정하고 설정을 가져오거나 내보냅니다.", .connected, .app),
            e("O25", "Updates and helper", "업데이트와 도우미", "Check updates, choose a channel and prepare the lid helper.", "업데이트·배포 채널·덮개 도우미를 관리합니다.", .partial, .app, support: ("Channels, explicit install and helper preparation. Widgets/Control Center are not implemented.", "채널·명시 설치·도우미 준비를 제공합니다. 위젯·제어 센터는 아직 미지원입니다.")),
            e("O26", "Additional tools", "추가 도구 후보", "Keyboard cleaning, fan/network/game controls and virtual displays require separate implementations.", "키보드 청소·팬/네트워크/게임 제어·가상 화면은 별도 구현이 필요한 후보입니다.", .notImplemented, nil)
        ]
    }
}
