import Foundation
import TetherCore

/// One entry in a guide or the glossary: a name and what it means.
struct HelpItem: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

/// The words Tether uses, defined once: the Help page lists them and the README's glossary
/// matches them.
enum Glossary {
    static var terms: [HelpItem] {
        [
            HelpItem(title: L("Clamshell mode", "클램쉘 모드"),
                     text: L("Using the Mac with its lid closed. With Tether, on power it stays awake and unlocked with the lid closed; unplugged, it sleeps as usual.",
                             "덮개를 닫은 채 Mac을 쓰는 것. Tether에서는 전원이 연결돼 있으면 덮개를 닫아도 잠들지도 잠기지도 않고, 전원을 뽑으면 평소처럼 잠들어요.")),
            HelpItem(title: L("Battery hold", "배터리 유지"),
                     text: L("A timed exception, 30 minutes to 4 hours, that keeps clamshell mode on battery, say to finish a job in a bag. The safety limits end it early.",
                             "배터리로도 클램쉘 모드를 잠시(30분~4시간) 유지하는 예외. 가방 안에서 작업을 끝낼 때처럼 쓰고, 안전 기준에 닿으면 먼저 끝나요.")),
            HelpItem(title: L("Safety limits", "안전 기준"),
                     text: L("What ends a battery hold: battery temperature, heat, the battery floor and the longest hold. They can be made stricter, never looser.",
                             "배터리 유지를 끝내는 조건: 배터리 온도, 발열, 하한선, 최대 시간. 더 엄격하게만 바꿀 수 있어요.")),
            HelpItem(title: L("Battery floor", "하한선"),
                     text: L("The charge at which a battery hold ends, 20% unless you choose more. A hold can't start at or below it.",
                             "배터리 유지를 끝내는 잔량(기본 20%). 이 잔량 이하에서는 유지를 시작할 수 없어요.")),
            HelpItem(title: L("Heat", "발열 단계"),
                     text: L("How hard macOS works to stay cool: normal, fair, serious, critical. On power a closed Mac gets Low Power Mode from serious (or fair); a battery hold ends after a minute at serious, or at critical.",
                             "macOS가 열을 식히느라 애쓰는 정도: 정상, 주의, 심각, 위험. 전원 연결 중 덮개를 닫은 Mac은 '심각'(또는 '주의')부터 저전력 모드를 켜고, 배터리 유지는 '심각'이 1분 이어지거나 '위험'이 되면 끝나요.")),
            HelpItem(title: L("Heat guard", "발열 보호"),
                     text: L("On power with the lid closed, Low Power Mode comes on when the Mac runs hot and your setting comes back once it has cooled.",
                             "전원 연결 중 덮개를 닫은 Mac이 뜨거워지면 저전력 모드를 켜고, 식으면 원래 설정으로 돌려요.")),
            HelpItem(title: L("Safety net", "안전장치"),
                     text: L("Always on: a closed Mac on power with no display attached is put to sleep if it overheats or its charger can't keep up.",
                             "항상 켜져 있어요. 모니터 없이 전원에 연결된 채 덮개가 닫힌 Mac이 과열되거나 충전기 출력이 모자라면 재워요.")),
            HelpItem(title: L("Auto-adjust", "자동 조정"),
                     text: L("Sets the temperature limits and the longest hold from this Mac's own measurements, and keeps them up to date. Never looser than the defaults.",
                             "이 Mac에서 잰 값으로 온도 기준과 최대 시간을 정하고 계속 맞춰요. 기본값보다 느슨해지지 않아요.")),
            HelpItem(title: L("Low Power Mode", "저전력 모드"),
                     text: L("macOS's own setting that slows the Mac for less heat and drain. Tether switches it only where you allow, then puts yours back.",
                             "속도를 낮춰 열과 배터리 소모를 줄이는 macOS 설정. Tether는 허용한 경우에만 켜고, 끝나면 원래대로 돌려요.")),
            HelpItem(title: L("Screen off without locking", "잠금 없이 화면 끄기"),
                     text: L("After a few idle minutes the screen goes black; any key or mouse brings it straight back, no password.",
                             "입력이 없으면 몇 분 뒤 화면을 검게 끄고, 키보드나 마우스를 쓰면 암호 없이 바로 돌아와요.")),
            HelpItem(title: L("Lid session", "덮개 세션"),
                     text: L("One stretch of staying awake with the lid closed, from closing the lid to opening it or sleeping.",
                             "덮개를 닫고 깨어 있던 한 번의 기간. 덮개를 닫을 때부터 열거나 잠들 때까지예요.")),
            HelpItem(title: L("Helper", "도우미"),
                     text: L("Tether's background service, with administrator rights. It switches sleep and keeps every rule and limit, even with the app closed.",
                             "관리자 권한으로 도는 Tether의 백그라운드 서비스. 앱이 꺼져 있어도 잠자기를 바꾸고 모든 규칙과 기준을 지켜요.")),
            HelpItem(title: L("Watchdog", "감시 장치"),
                     text: L("A tiny script launchd runs every minute. Should the helper stop, it makes sure sleep isn't left off on battery.",
                             "launchd가 1분마다 실행하는 작은 스크립트. 도우미가 멈춰도 배터리에서 잠자기 금지가 남지 않게 해요.")),
            HelpItem(title: L("Prevent sleep", "잠자기 금지"),
                     text: L("The hidden macOS setting behind clamshell mode (pmset disablesleep). Tether turns it on only while power is connected or a battery hold runs.",
                             "클램쉘 모드에 쓰는 숨은 macOS 설정(pmset disablesleep). 전원이 연결돼 있거나 배터리 유지 중일 때만 켜요.")),
            HelpItem(title: L("Dark wake", "다크 웨이크"),
                     text: L("A short wake with the screen off, for Power Nap or charging. Tether leaves it alone, so a sleeping Mac goes back to sleep.",
                             "화면을 켜지 않고 잠깐 깨는 것(Power Nap, 충전 등). Tether는 건드리지 않아서 자던 Mac은 다시 잠들어요.")),
        ]
    }

    /// What Tether does in four lines, at the top of the Help page.
    static var overview: [HelpItem] {
        [
            HelpItem(title: L("On power", "전원 연결 중"),
                     text: L("Close the lid and the Mac keeps working: no sleep, no lock, the screen under the lid dark.",
                             "덮개를 닫아도 Mac이 계속 일해요. 잠들지도 잠기지도 않고, 덮개 아래 화면은 꺼 둬요.")),
            HelpItem(title: L("Unplugged", "전원을 뽑으면"),
                     text: L("It sleeps like a laptop should, even if the lid is already closed. The switch in the panel turns clamshell mode off until power is connected again.",
                             "노트북답게 잠들어요. 이미 덮개가 닫혀 있어도요. 패널의 스위치로 끄면 다음에 전원을 연결할 때까지 꺼져 있어요.")),
            HelpItem(title: L("On battery, for a while", "배터리로 잠시"),
                     text: L("A battery hold from the panel keeps a closed Mac awake on battery, within the safety limits.",
                             "패널에서 배터리 유지를 켜면 안전 기준 안에서 배터리로도 덮개를 닫은 Mac을 깨워 둬요.")),
            HelpItem(title: L("Safe on its own", "알아서 안전하게"),
                     text: L("The helper enforces every limit even with the app closed, and a closed Mac that overheats is put to sleep.",
                             "앱이 꺼져 있어도 도우미가 모든 기준을 지키고, 덮개를 닫은 채 과열되면 재워요.")),
        ]
    }
}

/// Each settings page's guide, behind the "?" at its bottom: what the page is for and what each
/// setting on it does, in plainer words than the footers and with when to change it.
extension SettingsPage {
    var guideSummary: String {
        switch self {
        case .general: L("How Tether starts and how it looks.", "Tether가 어떻게 시작되고 어떻게 보일지 정해요.")
        case .lid: L("What happens to the screen when the lid closes on power.", "전원이 연결된 채 덮개를 닫았을 때 화면을 어떻게 할지 정해요.")
        case .safety: L("Limits for staying awake on battery, and how a closed Mac is kept cool.", "배터리로 깨어 있을 때의 안전 기준과, 덮개를 닫은 Mac을 식히는 방법을 정해요.")
        case .history: L("What happened over the last seven days.", "최근 7일 동안 있었던 일이에요.")
        case .notifications: L("Which events get a notification.", "어떤 일에 알림을 보낼지 정해요.")
        case .automation: L("Control Tether from Terminal, scripts, agents and the Shortcuts app.", "터미널, 스크립트, 에이전트, 단축어 앱에서 Tether를 다뤄요.")
        case .system: L("The helper, what Tether changes on your Mac, troubleshooting and updates.", "도우미, Tether가 바꾸는 설정, 문제 해결과 업데이트예요.")
        case .help: L("How Tether works and the words it uses.", "Tether의 동작 방식과 쓰는 용어예요.")
        }
    }

    var guide: [HelpItem] {
        switch self {
        case .general:
            [
                HelpItem(title: L("Open at login", "로그인하면 자동으로 열기"),
                         text: L("Keep it on. The app keeps the screen unlocked and dark under the lid; without it only the helper's power rules apply.",
                                 "켜 두세요. 덮개 아래 화면을 잠그지 않고 어둡게 하는 일은 앱이 해요. 앱이 없으면 도우미의 전원 규칙만 적용돼요.")),
                HelpItem(title: L("Language", "언어"),
                         text: L("English or Korean, or whatever macOS uses. The tether command follows it.",
                                 "영어나 한국어를 고르거나 macOS를 따라요. tether 명령도 같은 언어를 써요.")),
                HelpItem(title: L("Panel", "패널"),
                         text: L("Full shows power, lid, temperature, the battery hold and today; Compact shows the state and one row of controls.",
                                 "자세히는 전원, 덮개, 온도, 배터리 유지, 오늘 기록을, 컴팩트는 상태와 조작 한 줄만 보여 줘요.")),
                HelpItem(title: L("Menu bar", "메뉴바"),
                         text: L("During a battery hold, a ring and the time left; when a closed Mac runs hot, the battery temperature. Off leaves just the icon.",
                                 "배터리 유지 중에는 링과 남은 시간을, 덮개를 닫고 뜨거울 때는 배터리 온도를 아이콘 옆에 보여 줘요. 끄면 아이콘만 남아요.")),
            ]
        case .lid:
            [
                HelpItem(title: L("When the lid closes", "덮개를 닫으면"),
                         text: L("Stay unlocked: remote sessions, agents and downloads carry on, and reopening needs no password. Lock the screen: safer when you leave the Mac somewhere.",
                                 "잠그지 않기: 원격 접속, 에이전트, 다운로드가 계속되고 다시 열 때 암호가 필요 없어요. 화면 잠그기: Mac을 두고 자리를 뜰 때 더 안전해요.")),
                HelpItem(title: L("Screen under the lid", "덮개 아래 화면"),
                         text: L("Unlocked, the built-in screen and keyboard light go dark and come back when the lid opens. With an external display, macOS handles the screens.",
                                 "잠그지 않으면 내장 화면과 키보드 조명을 꺼 두었다가 덮개를 열면 돌려요. 외장 모니터가 있으면 화면은 macOS가 맡아요.")),
                HelpItem(title: L("Turn the screen off when idle", "입력이 없으면 화면 끄기"),
                         text: L("While clamshell mode is on, display sleep would lock the Mac, so after these idle minutes the screen goes black instead and any input brings it back, no password. It waits during videos and calls.",
                                 "클램쉘 모드에서는 화면이 꺼지면 Mac이 잠겨서, 이 시간 동안 입력이 없으면 대신 화면을 검게 끄고 입력하면 암호 없이 돌려요. 동영상이나 통화 중에는 기다려요.")),
            ]
        case .safety:
            [
                HelpItem(title: L("Measured on this Mac", "이 Mac에서 잰 값"),
                         text: L("Battery temperatures, battery use and heat from the last seven days, and the limits they suggest. Apply copies the suggestions once.",
                                 "최근 7일의 배터리 온도, 사용량, 발열과 거기서 나온 추천값이에요. '추천값 적용'은 한 번 옮겨 넣어요.")),
                HelpItem(title: L("Adjust to this Mac", "이 Mac에 맞춰 자동 조정"),
                         text: L("Keeps the temperature limits and the longest hold at the suggestions as measurements come in, never looser than the defaults.",
                                 "기록이 쌓일 때마다 온도 기준과 최대 시간을 추천값으로 맞춰요. 기본값보다 느슨해지지 않아요.")),
                HelpItem(title: L("Battery hold limits", "배터리 유지 기준"),
                         text: L("A hold ends and a closed Mac sleeps at the battery floor, at the temperature limit, at “serious” heat for a minute, or when the longest hold is up.",
                                 "하한선, 온도 기준, 1분 이어진 발열 '심각', 최대 시간 중 하나에 닿으면 유지를 끝내고 덮개가 닫힌 Mac을 재워요.")),
                HelpItem(title: L("Low Power Mode", "저전력 모드"),
                         text: L("Whether Tether may turn it on during a battery hold, and from which heat when a closed Mac runs hot on power. Your own setting always comes back.",
                                 "배터리 유지 중에 켤지, 전원 연결 중 덮개를 닫은 채 뜨거울 때 어느 발열부터 켤지 정해요. 끝나면 원래 설정으로 돌아와요.")),
                HelpItem(title: L("Safety net", "안전장치"),
                         text: L("Can't be turned off: a closed Mac on power with no display is put to sleep if it overheats or its charger can't keep up.",
                                 "끌 수 없어요. 모니터 없이 전원에 연결된 채 덮개가 닫힌 Mac이 과열되거나 충전기 출력이 모자라면 재워요.")),
            ]
        case .history:
            [
                HelpItem(title: L("Daily peak battery temperature", "하루 최고 배터리 온도"),
                         text: L("Orange is the lid closed, blue the lid open. The dashed lines are your battery-hold limits; the further below them, the more headroom.",
                                 "주황은 덮개 닫힘, 파랑은 덮개 열림이에요. 점선은 배터리 유지 기준이고, 선이 멀수록 여유가 있어요.")),
                HelpItem(title: L("Recent sleeps", "최근 잠자기"),
                         text: L("How long each sleep lasted, what put the Mac to sleep and what woke it, and charge used per hour. Over 3% an hour means something kept waking it.",
                                 "얼마나 잤는지, 무엇이 재우고 깨웠는지, 시간당 사용량이에요. 시간당 3%를 넘으면 무언가 자꾸 깨운 거예요.")),
                HelpItem(title: L("Recent lid sessions", "최근 덮개 세션"),
                         text: L("Each stretch awake with the lid closed: how long, the peak battery temperature and the charge used.",
                                 "덮개를 닫고 깨어 있던 때마다 걸린 시간, 최고 배터리 온도, 쓴 배터리예요.")),
                HelpItem(title: L("Last 7 days", "최근 7일"),
                         text: L("Totals: time awake with the lid closed, sleeps Tether caused, battery holds and heat-guard runs.",
                                 "합계: 덮개를 닫고 깨어 있던 시간, Tether가 재운 횟수, 배터리 유지와 발열 보호 횟수예요.")),
            ]
        case .notifications:
            [
                HelpItem(title: L("Sleep used a lot of battery", "잠자는 동안 배터리를 많이 썼을 때"),
                         text: L("Over 3% an hour; usually an app or a device keeps waking the Mac. History shows what woke it.",
                                 "시간당 3%를 넘을 때요. 보통 앱이나 기기가 Mac을 자꾸 깨우는 경우이고, 기록에서 무엇이 깨웠는지 볼 수 있어요.")),
                HelpItem(title: L("A battery hold ended", "배터리 유지가 끝났을 때"),
                         text: L("Why it ended (time, battery or heat), after the Mac wakes.",
                                 "왜 끝났는지(시간, 배터리, 발열) Mac이 깨어난 뒤 알려요.")),
                HelpItem(title: L("Overheating with the lid closed", "덮개를 닫은 채 과열될 때"),
                         text: L("Critical heat for 3 minutes on power, and a Mac put to sleep for overheating.",
                                 "전원 연결 중 발열 '위험'이 3분 이어질 때와, 과열로 잠재웠을 때요.")),
                HelpItem(title: L("Always reported", "항상 알리는 것"),
                         text: L("A stopped helper, and a sleep because the charger couldn't keep up.",
                                 "도우미가 멈췄을 때, 충전기 출력이 부족해 잠재웠을 때요.")),
            ]
        case .automation:
            [
                HelpItem(title: L("The tether command", "tether 명령"),
                         text: L("status, on and off, sleep, hold, run, doctor and diagnose in Terminal. tether run -- <command> keeps the Mac awake until the command finishes.",
                                 "터미널에서 status, on/off, sleep, hold, run, doctor, diagnose를 써요. tether run -- <명령>은 명령이 끝날 때까지 깨어 있게 해요.")),
                HelpItem(title: L("For scripts and agents", "스크립트와 에이전트"),
                         text: L("tether status --json gives the state as JSON, and commands that change something wait until the helper has applied it.",
                                 "tether status --json은 상태를 JSON으로 주고, 무언가 바꾸는 명령은 도우미가 적용할 때까지 기다려요.")),
                HelpItem(title: L("URLs", "URL"),
                         text: L("tether://sleep, tether://toggle and tether://hold/90m, for the Shortcuts app's Open URL action.",
                                 "단축어 앱의 'URL 열기'에 tether://sleep, tether://toggle, tether://hold/90m을 넣어요.")),
            ]
        case .system:
            [
                HelpItem(title: L("Helper", "도우미"),
                         text: L("The background service that switches sleep. If its status isn't green, reinstall it.",
                                 "잠자기를 바꾸는 백그라운드 서비스예요. 상태가 초록이 아니면 다시 설치하세요.")),
                HelpItem(title: L("What Tether changes", "Tether가 바꾸는 설정"),
                         text: L("Only “prevent sleep”, Low Power Mode where you allow it, and a keep-screen-on request. Timers, the password and the screen saver are never touched.",
                                 "잠자기 금지, 허용한 경우의 저전력 모드, 화면 켜 둠 요청뿐이에요. 타이머, 암호, 화면 보호기는 건드리지 않아요.")),
                HelpItem(title: L("Apps keeping the Mac awake", "잠을 막는 앱"),
                         text: L("Other apps holding off sleep. With the lid open on battery they drain it; closing the lid still sleeps the Mac.",
                                 "잠자기를 막는 다른 앱이에요. 배터리로 덮개를 연 채 두면 배터리가 닳지만, 덮개를 닫으면 그래도 잠들어요.")),
                HelpItem(title: L("Diagnostics", "진단"),
                         text: L("The checks. For a problem, turn on detailed logging, make it happen again and create a report; names are masked and nothing is sent. Turn detailed logging off afterwards.",
                                 "점검 목록이에요. 문제가 있으면 자세한 기록을 켜고 다시 일으킨 뒤 보고서를 만드세요. 이름은 가려지고 아무 데도 보내지 않아요. 끝나면 자세한 기록을 꺼 주세요.")),
                HelpItem(title: L("Updates and uninstall", "업데이트와 제거"),
                         text: L("Tether asks GitHub once a day for a newer release. Uninstall removes everything and gives the Mac its normal sleep back.",
                                 "하루 한 번 GitHub에 새 릴리스를 물어봐요. 완전히 제거하면 모두 지우고 Mac을 원래 잠자기 동작으로 돌려요.")),
            ]
        case .help:
            []
        }
    }

    /// The README section with more on this page, in the app's language.
    var readmeURL: URL {
        let korean = Localization.current == .korean
        let anchor: String = switch self {
        case .general, .notifications, .automation: korean ? "사용법" : "use"
        case .lid: korean ? "동작-방식" : "how-it-works"
        case .safety: korean ? "안전장치" : "safety"
        case .history: korean ? "기능" : "features"
        case .system: korean ? "tether가-바꾸는-시스템-설정" : "what-tether-changes-on-your-mac"
        case .help: korean ? "용어" : "glossary"
        }
        let page = korean ? "/blob/main/README.ko.md" : ""
        let encoded = anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchor
        return URL(string: UpdateChecker.projectURL.absoluteString + page + "#" + encoded) ?? UpdateChecker.projectURL
    }
}
