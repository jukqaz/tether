import SwiftUI
import TetherCore

/// How the state reads in the panel and the menu bar.
extension AppModel {
    /// The Tether mark for the clamshell states, an SF Symbol where a symbol says it better.
    enum Icon: Hashable {
        case mark(TetherGlyph.Style)
        case symbol(String)
    }

    /// What the panel's main module shows: one state, its colour and icon.
    struct Presentation {
        let title: String
        let subtitle: String
        let icon: Icon
        let color: Color
        let menuBarIcon: Icon
    }

    var state: TetherState {
        TetherState.resolve(supportedMac: supportedMac, helperInstalled: helperInstalled,
                            helperResponding: helperResponding, enabled: enabled, holdingOnBattery: holdingOnBattery,
                            heatGuard: heatGuardActive, thermal: thermalLevel, sleepDisabled: snapshot.sleepDisabled)
    }

    var presentation: Presentation {
        switch state {
        case .unsupported:
            Presentation(title: L("Not a MacBook", "MacBook이 아님"),
                         subtitle: L("Tether needs a lid and a battery; this Mac's sleep is left alone",
                                     "덮개와 배터리가 있어야 해요. 이 Mac의 잠자기는 건드리지 않아요"),
                         icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        case .helperMissing:
            Presentation(title: L("Helper needed", "도우미 설치 필요"),
                         subtitle: L("Install it once to apply the power rules", "전원 규칙을 적용하려면 한 번 설치해 주세요"),
                         icon: .symbol("wrench.and.screwdriver.fill"), color: .gray,
                         menuBarIcon: .symbol("exclamationmark.triangle"))
        case .helperDown:
            Presentation(title: L("Helper not responding", "도우미 응답 없음"),
                         subtitle: L("The power rules aren't being applied right now", "지금은 전원 규칙이 적용되지 않아요"),
                         icon: .symbol("exclamationmark.triangle.fill"), color: .red,
                         menuBarIcon: .symbol("exclamationmark.triangle"))
        case .off:
            Presentation(title: L("Clamshell mode off", "클램쉘 모드 꺼짐"),
                         subtitle: L("Back on when power is connected again", "전원을 다시 연결하면 켜져요"),
                         icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        case .holdingOnBattery:
            Presentation(title: L("Holding on battery", "배터리로 유지 중"),
                         subtitle: L("Awake on battery, within the safety limits", "안전 기준 안에서 배터리로 깨어 있어요"),
                         icon: .symbol("bag.fill"), color: .orange, menuBarIcon: .mark(.held))
        case .heatGuard(let critical):
            Presentation(title: critical ? L("Critical heat", "발열 위험") : L("Heat guard on", "발열 보호 중"),
                         subtitle: L("Running hot with the lid closed, cooling with Low Power Mode",
                                     "덮개가 닫힌 채 뜨거워져 저전력 모드로 식히는 중이에요"),
                         icon: .symbol(critical ? "flame.fill" : "thermometer.high"),
                         color: critical ? .red : .orange, menuBarIcon: .mark(.on))
        case .clamshellOn:
            Presentation(title: L("Clamshell on", "클램쉘 켜짐"),
                         subtitle: L("Close the lid: no sleep, no lock", "덮개를 닫아도 잠들지도, 잠기지도 않아요"),
                         icon: .mark(.on), color: .tetherMint, menuBarIcon: .mark(.on))
        case .clamshellOff:
            Presentation(title: L("On battery", "배터리 사용 중"),
                         subtitle: L("Clamshell mode turns on with power", "전원을 연결하면 클램쉘 모드가 켜져요"),
                         icon: .mark(.off), color: .blue, menuBarIcon: .mark(.off))
        }
    }

    /// The status item: the mark, plus a ring and a countdown during a battery hold, or the
    /// battery temperature while a closed Mac runs hot on power.
    struct MenuBarItem: Hashable {
        var icon: Icon
        var text: String?
        var ring: Double?
    }

    func menuBarItem(at now: Date) -> MenuBarItem {
        let icon = presentation.menuBarIcon
        guard menuBarDetails else { return MenuBarItem(icon: icon) }
        if let until = batteryHoldUntil {
            return MenuBarItem(icon: icon, text: Texts.countdown(until.timeIntervalSince(now)),
                               ring: holdRemainingFraction(at: now))
        }
        if clamshellActive, snapshot.lidClosed, heatGuardActive || thermalLevel >= 2 {
            let text = status?.batteryTemperature.map { "\(Int($0.rounded()))°" } ?? Texts.thermal(thermalLevel)
            return MenuBarItem(icon: icon, text: text)
        }
        return MenuBarItem(icon: icon)
    }

    // MARK: Problems

    /// Something the user has to act on, shown as a banner above everything else.
    enum Problem {
        case translocated, missing, down, outdated, error(String)

        var title: String {
            switch self {
            case .translocated: L("Move Tether to Applications", "Tether를 응용 프로그램 폴더로 옮겨 주세요")
            case .missing: L("The helper isn't installed", "도우미가 설치되지 않았어요")
            case .down: L("The helper isn't responding", "도우미가 응답하지 않아요")
            case .outdated: L("The helper needs an update", "도우미 업데이트가 필요해요")
            case .error: L("That didn't work", "작업을 마치지 못했어요")
            }
        }

        var message: String {
            switch self {
            case .translocated: L("It's running from a temporary copy macOS made of the download. Quit, move Tether.app to Applications, and open it again.",
                                  "macOS가 다운로드한 앱을 임시 위치에서 실행하고 있어요. 종료한 뒤 Tether.app을 응용 프로그램 폴더로 옮기고 다시 열어 주세요.")
            case .missing: L("It installs with your administrator password, once.", "관리자 비밀번호를 한 번 입력하면 설치돼요.")
            case .down: L("It may be off in Login Items, or stopped after a macOS update.", "로그인 항목에서 꺼졌거나 macOS 업데이트 뒤 멈췄을 수 있어요.")
            case .outdated: L("An older helper than this app is running.", "앱보다 오래된 도우미가 실행 중이에요.")
            case .error(let text): text
            }
        }

        var action: String? {
            switch self {
            case .translocated, .error: nil
            case .missing: L("Install Helper…", "도우미 설치…")
            case .down: L("Reinstall…", "다시 설치…")
            case .outdated: L("Update…", "업데이트…")
            }
        }

        var color: Color {
            switch self {
            case .down, .error: .red
            case .translocated, .missing, .outdated: .orange
            }
        }
    }

    var problem: Problem? {
        if let errorText { return .error(errorText) }
        guard supportedMac else { return nil }
        if isTranslocated { return .translocated }
        if !helperInstalled { return .missing }
        if !helperResponding { return .down }
        if helperOutdated { return .outdated }
        return nil
    }

    /// One line for the settings window: is the helper there, alive, current?
    var helperStatus: (text: String, color: Color) {
        if !helperInstalled { return (L("not installed", "설치되지 않음"), .orange) }
        guard helperResponding, let status else { return (L("not responding", "응답 없음"), .red) }
        if helperOutdated { return (L("needs an update · v\(status.version)", "업데이트 필요 · v\(status.version)"), .orange) }
        return (L("running · v\(status.version)", "실행 중 · v\(status.version)"), .green)
    }

    // MARK: Tiles

    var powerValue: String {
        switch snapshot.power {
        case .ac: L("Power", "연결됨")
        case .battery: L("Battery", "배터리")
        case .unknown: L("Checking", "확인 중")
        }
    }

    var powerSymbol: String { snapshot.power == .ac ? "powerplug.fill" : "battery.75percent" }

    var percentText: String {
        (status?.batteryPercent ?? SystemProbe.batteryPercent()).map { "\($0)%" } ?? "–"
    }

    var lidDetail: String {
        if !snapshot.lidClosed { return screenBlank ? L("screen off", "화면 꺼짐") : L("screen on", "화면 켜짐") }
        if Displays.hasExternal { return L("external display", "외장 모니터") }
        return clamshellActive ? L("dimmed", "화면 어둡게") : L("asleep", "잠자는 중")
    }

    var temperatureValue: String {
        guard let t = status?.batteryTemperature ?? SystemProbe.batteryTemperature() else { return "–" }
        return String(format: "%.1f°", t)
    }

    var thermalLevel: Int { status?.thermal ?? ProcessInfo.processInfo.thermalState.rawValue }

    var thermalLabel: String {
        heatGuardActive ? L("Low Power Mode", "저전력 모드") : L("heat ", "발열 ") + Texts.thermal(thermalLevel)
    }

    /// The same in as few characters as possible, for the status module's narrow rows.
    var thermalShort: String {
        heatGuardActive ? L("Low Power", "저전력 모드") : L(Texts.thermal(thermalLevel), "발열 " + Texts.thermal(thermalLevel))
    }

    var thermalColor: Color {
        switch thermalLevel {
        case 0: .green
        case 1: .yellow
        case 2: .orange
        default: .red
        }
    }

    // MARK: Records

    /// The last lid session, for an hour after it ended.
    var visibleSession: LidSession? {
        guard let session = usage?.recentSessions.last, let end = session.end,
              Date().timeIntervalSince1970 - end < 3600, !snapshot.lidClosed else { return nil }
        return session
    }

    var today: DayStats { (usage?.stats ?? StatsTracker()).today(now: Date()) }
    var sleepLog: SleepLog { usage?.sleeps ?? SleepLog() }
    var lastSleep: SleepRecord? { sleepLog.recent.last }
    var week: [DayStats] { (usage?.stats ?? StatsTracker()).week(now: Date()) }

    /// Who armed the hold, when it wasn't this app's panel.
    var holdSourceText: String? { Texts.holdSource(holdSource) }

    var lastEventText: String? {
        guard let status, let event = status.lastEvent, let at = status.lastEventAt else { return nil }
        let time = Texts.time(Date(timeIntervalSince1970: at))
        return "\(time) · \(event.displayText)"
    }
}
