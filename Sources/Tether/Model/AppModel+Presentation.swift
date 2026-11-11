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
                            helperResponding: helperResponding, enabled: tetherEnabled, holdingOnBattery: holdingOnBattery,
                            heatGuard: heatGuardActive, thermal: thermalLevel, sleepDisabled: clamshellActive)
    }

    var presentation: Presentation {
        if let session = userSessionStatus {
            if let reason = session.blockReason {
                return Presentation(title: L("Stopped for protection", "보호를 위해 중지됨"), subtitle: protectionReason(reason),
                    icon: .symbol("shield.lefthalf.filled"), color: .tetherWarning, menuBarIcon: .symbol("shield.lefthalf.filled"))
            }
            if session.ownReleasePending == true {
                return Presentation(title: L("Confirming release", "유지 해제 확인 중"),
                    subtitle: L("Tether has ended keep-awake, but macOS has not confirmed its release. This does not confirm that the Mac is asleep.",
                                "유지는 종료했지만 macOS의 절전 방지 해제를 아직 확인하지 못했습니다. Mac이 실제로 잠들었는지는 별도 확인이 필요합니다."),
                    icon: .symbol("hourglass"), color: .tetherWarning, menuBarIcon: .symbol("hourglass"))
            }
            if session.observationLimited == true {
                return Presentation(title: L("Checking power and protection", "전원·보호 상태 확인 중"),
                    subtitle: L("New starts and extensions wait for the required power and protection checks. Current keep-awake remains within its existing limits.",
                                "필수 상태를 확인할 때까지 새로 시작하거나 시간을 추가할 수 없습니다. 실행 중인 유지에는 기존 제한이 적용됩니다."),
                    icon: .symbol("hourglass"), color: .tetherWarning, menuBarIcon: .symbol("hourglass"))
            }
            if session.error != nil || (session.manualActive && !session.holding) {
                return Presentation(title: L("Review needed", "유지 상태 확인 필요"),
                    subtitle: session.error ?? L("Keep-awake could not be confirmed.", "잠자기 방지 적용을 확인하지 못했습니다."),
                    icon: .symbol("exclamationmark.triangle"), color: .tetherWarning, menuBarIcon: .symbol("exclamationmark.triangle"))
            }
            if workPaused {
                if v3Settings.runtimeMarkers?.pauseReason == .userSleep {
                    return Presentation(title: L("Waiting after Sleep request", "잠자기 요청 후 자동 시작 대기"),
                        subtitle: L("Waking the Mac alone does not restart keep-awake. Choose Resume or wait for a new automatic condition.",
                                    "깨우기만 해서는 유지를 다시 시작하지 않습니다. 중지를 해제하거나 새 자동 조건을 기다립니다."),
                        icon: .mark(.off), color: .secondary, menuBarIcon: .mark(.off))
                }
                return Presentation(title: L("All keep-awake stopped", "모두 중지됨"),
                    subtitle: L("Resume rechecks automatic conditions. Ended manual keep-awake does not restart.",
                                "중지를 해제하면 자동 조건을 다시 확인합니다. 종료된 수동 유지는 다시 시작하지 않습니다."),
                    icon: .mark(.off), color: .secondary, menuBarIcon: .mark(.off))
            }
            if session.manualActive && session.holding {
                return manualPresentation
            }
            if automaticPauseActive {
                return Presentation(title: L("Automatic starts are paused", "자동 유지 일시 중지됨"),
                    subtitle: automaticPauseUntil.map {
                        L("Automatic starts are paused until \(Texts.time($0)). Manual keep-awake remains available.",
                          "\(Texts.time($0))까지 자동 시작을 중지합니다. 수동 유지는 사용할 수 있습니다.")
                    } ?? L("Automatic starts are paused until you resume them. Manual keep-awake remains available.",
                           "자동 유지를 재개할 때까지 일시 중지합니다. 수동 유지는 사용할 수 있습니다."),
                    icon: .symbol("pause.circle"), color: .secondary, menuBarIcon: .mark(.off))
            }
            if automaticBatteryEnded {
                return Presentation(title: L("Automatic battery keep-awake ended", "배터리 자동 유지 종료"),
                    subtitle: L("The original battery limit has been reached. Waking the Mac or reconnecting power does not reset this automatic keep-awake limit.",
                                "처음 정한 배터리 유지 한도에 도달했습니다. 깨우거나 전원을 다시 연결해도 같은 자동 유지의 한도는 초기화되지 않습니다."),
                    icon: .mark(.off), color: .secondary, menuBarIcon: .mark(.off))
            }
            if !session.holding, !session.manualActive, !session.automaticActive,
               userSession?.hasConfirmedSessionAuthority == true,
               let deferred = sleepDeferralPresentation {
                return deferred
            }
            return Presentation(title: session.holding ? L("Automatic keep-awake active", "자동 유지 중")
                    : session.automaticEnabled ? L("Waiting for an automatic condition", "자동 유지 대기") : L("Keep-awake is off", "유지 꺼짐"),
                subtitle: session.holding
                    ? activeWorkReasonSummary(at: Date()) ?? lidObservationNotice ?? L("Display sleep and locking follow macOS settings.", "화면 꺼짐과 잠금은 macOS 설정을 따릅니다.")
                    : session.automaticEnabled ? L("Waiting for \(session.powerCondition.title). Manual keep-awake remains available.", "\(session.powerCondition.title) 조건을 기다립니다. 수동 유지는 직접 시작할 수 있습니다.")
                        : L("Manual keep-awake remains available.", "수동 유지는 직접 시작할 수 있습니다."),
                icon: session.holding ? .mark(.on) : .symbol("timer"), color: session.holding ? .tetherAccent : .secondary,
                menuBarIcon: session.holding ? .mark(.on) : .mark(.off))
        }
        if commandPending {
            return Presentation(title: L("Applying…", "적용 중…"), subtitle: L("Waiting for the helper's result", "설정을 적용하고 있습니다"), icon: .symbol("hourglass"), color: .secondary, menuBarIcon: .symbol("hourglass"))
        }
        if helperResponding, supportedMac, let reason = protection?.blockReason,
           ["powerConflict", "displayConflict", "ownershipUnreadable", "bootSessionUnavailable"].contains(reason) {
            return Presentation(title: L("Review needed", "확인 필요"), subtitle: protectionReason(reason),
                icon: .symbol("exclamationmark.bubble"), color: .tetherWarning, menuBarIcon: .symbol("exclamationmark.triangle"))
        }
        if helperResponding, supportedMac, let reason = protection?.blockReason {
            let subtitle = [protectionReason(reason), sleepDeferralPresentation?.subtitle].compactMap { $0 }.joined(separator: " · ")
            return Presentation(title: L("Stopped for protection", "보호를 위해 중지됨"), subtitle: subtitle,
                icon: .symbol("shield.lefthalf.filled"), color: .tetherWarning, menuBarIcon: .symbol("shield.lefthalf.filled"))
        }
        if helperResponding, (enabled || manualSessionActive), let notice = lidObservationNotice {
            return Presentation(title: L("Checking lid support", "덮개 유지 상태 확인 중"), subtitle: notice,
                icon: .symbol("hourglass"), color: .tetherWarning, menuBarIcon: .symbol("hourglass"))
        }
        if helperResponding, manualSessionActive {
            return manualPresentation
        }
        if let deferred = sleepDeferralPresentation { return deferred }
        if helperResponding, enabled, snapshot.displayTopology == .unknown {
            return Presentation(title: L("Checking display setup", "화면 구성 확인 필요"),
                subtitle: status?.ownsOverride == true
                    ? L("Work stays active while the display setup is rechecked", "작업을 유지하며 화면 구성을 다시 확인합니다")
                    : L("No additional hold while display configuration is unknown", "화면 연결을 확인할 때까지 잠자기 방지를 시작하지 않습니다"),
                icon: .symbol("display.trianglebadge.exclamationmark"), color: .tetherWarning, menuBarIcon: .symbol("exclamationmark.triangle"))
        }
        if helperResponding, enabled, status?.appConnected == false {
            return Presentation(title: L("Connection unconfirmed", "연결 확인 중"), subtitle: L("The helper is waiting for the app", "도우미가 앱의 연결을 기다립니다"),
                icon: .symbol("pause.circle"), color: .secondary, menuBarIcon: .mark(.off))
        }
        if helperResponding, snapshot.usesNativeClamshell {
            return Presentation(title: L("Managed by macOS", "macOS가 관리 중"),
                subtitle: enabled ? L("External display on power · no extra sleep override", "외장 화면과 전원이 연결되어 있습니다")
                    : L("Tether is off · macOS manages the external display", "Tether 꺼짐 · 외장 화면은 macOS가 관리"),
                icon: .symbol("display"), color: .secondary, menuBarIcon: .symbol("display"))
        }
        return switch state {
        case .unsupported:
            Presentation(title: L("Unsupported platform", "지원 조건 확인 필요"),
                         subtitle: L("Requires Apple Silicon and macOS 26 or later", "Apple Silicon과 macOS 26 이상이 필요합니다"),
                         icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        case .helperMissing:
            Presentation(title: L("Helper needed", "도우미 설치 필요"),
                         subtitle: L("Closed-lid use requires the helper", "덮개를 닫고 사용하려면 도우미가 필요합니다"),
                         icon: .symbol("wrench.and.screwdriver.fill"), color: .gray,
                         menuBarIcon: .symbol("exclamationmark.triangle"))
        case .helperDown:
            Presentation(title: L("Helper not responding", "도우미 응답 없음"),
                         subtitle: L("The power rules aren't being applied right now", "현재 전원 조건을 적용할 수 없습니다"),
                         icon: .symbol("exclamationmark.triangle.fill"), color: .red,
                         menuBarIcon: .symbol("exclamationmark.triangle"))
        case .off:
            Presentation(title: L("Closed-lid use off", "덮개 닫고 사용 안 함"),
                         subtitle: L("Stays off until you turn it on", "다시 켜면 설정한 전원 조건을 적용합니다"),
                         icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        case .holdingOnBattery:
            Presentation(title: L("Holding on battery", "배터리로 사용 중"),
                         subtitle: L("Awake within your battery and time limits", "설정한 시간과 배터리 잔량까지 잠자기를 방지합니다"),
                         icon: .symbol("timer"), color: .tetherAccent, menuBarIcon: .mark(.held))
        case .heatGuard(let critical):
            Presentation(title: critical ? L("Critical heat", "발열 위험") : L("Heat guard on", "발열 보호 중"),
                         subtitle: L("Running hot with the lid closed, cooling with Low Power Mode",
                                     "발열을 낮추기 위해 저전력 모드를 사용합니다"),
                         icon: .symbol(critical ? "flame.fill" : "thermometer.high"),
                         color: critical ? .red : .tetherWarning, menuBarIcon: .mark(.on))
        case .clamshellOn:
            Presentation(title: snapshot.lidClosed ? L("Keeping your Mac awake", "덮개를 닫고 사용 중") : L("Ready for a closed lid", "잠자기 방지 켜짐"),
                         subtitle: snapshot.displayTopology == .virtualOnly
                            ? L("Virtual display connected · keeping your Mac awake", "가상 화면 연결 · Mac 작업 유지 중")
                            : snapshot.lidClosed ? status?.displayRecovery?.summary ?? L("Checking display sleep", "화면 절전 확인 중")
                            : L("Screen sleep and locking follow macOS settings", "화면 자동 꺼짐과 잠금은 macOS 설정을 따릅니다"),
                         icon: .mark(.on), color: .tetherAccent, menuBarIcon: .mark(.on))
        case .clamshellOff:
            Presentation(title: L("Waiting for power condition", "전원 조건 대기 중"),
                         subtitle: powerCondition.title,
                         icon: .mark(.off), color: .secondary, menuBarIcon: .mark(.off))
        }
    }

    /// A completed own release is distinct from whole-system sleep. Share this
    /// observation gate across common-session and helper-only presentation.
    private var sleepDeferralPresentation: Presentation? {
        guard hasCoordinatorAuthority, capabilities.lidControlAvailable,
              helperResponding, !helperOutdated, !commandPending, !lidCommandPending,
              coordinatedLidError == nil, coordinatedLidBlockReason == nil,
              protection?.blockReason == nil, protection?.lastError == nil, errorText == nil,
              let status, status.protection?.blockReason == nil, status.protection?.lastError == nil,
              status.appConnected == true, status.appPID == ProcessInfo.processInfo.processIdentifier,
              status.guiSessionAuthority == .confirmed,
              status.systemPowerObservationAvailable == true, status.observedLidClosed == true,
              status.fullWake == true, status.power != .unknown, status.power == snapshot.power,
              status.observedSleepDisabled == false, status.ownsOverride == false,
              let summary = status.sleepDeferralSummary else { return nil }
        let age = Date().timeIntervalSince1970 - status.updatedAt
        guard age.isFinite, age >= 0, age < 30 else { return nil }
        return Presentation(title: L("Tether hold ended", "Tether 유지 종료"), subtitle: summary,
            icon: .mark(.off), color: .secondary, menuBarIcon: .mark(.off))
    }

    private var manualPresentation: Presentation {
        let holding = manualSessionInfo?.holding == true
        let subtitle = manualSessionUntil.map { L("Ends at \(Texts.time($0))", "종료 시간: \(Texts.time($0))") }
            ?? (snapshot.power == .ac ? L("Until ended", "종료할 때까지")
                : L("Confirming the power source", "전원 연결 상태 확인 중"))
        let title = automaticWorkReasonActive
            ? L("Automatic + manual active", "자동·수동 유지 중")
            : L("Manual keep-awake active", "수동 유지 중")
        return Presentation(title: holding ? title : L("Checking manual keep-awake", "수동 유지 확인 중"),
            subtitle: activeWorkReasonSummary(at: Date()) ?? subtitle, icon: .symbol("timer"), color: holding ? .tetherAccent : .tetherWarning,
            menuBarIcon: holding ? .mark(.held) : .symbol("hourglass"))
    }

    /// Only a finite, confirmed manual timer may add text. Remote/display
    /// diagnostics never change the status item's width or create a timer.
    struct MenuBarItem: Hashable {
        var icon: Icon
        var text: String?
        var ring: Double?
        var countdown: MenuBarCountdown?
    }

    func menuBarItem(at now: Date, continuousNow: Double = ContinuousTime.now) -> MenuBarItem {
        var item = MenuBarItem(icon: presentation.menuBarIcon)
        guard manualSessionActive, let remaining = manualRemaining(at: now, continuousNow: continuousNow) else { return item }
        guard remaining.isFinite, remaining > 0 else {
            // The policy's next refresh may be a tick later than the display.
            // Do not draw a spent manual timer as active in that interval.
            if item.icon == .mark(.held) {
                item.icon = automaticWorkReasonActive && workSessionHolding ? .mark(.on) : .mark(.off)
            }
            return item
        }
        guard menuBarDetails, workSessionHolding, manualSessionInfo?.holding == true,
              !workPaused, workProtectionReason == nil,
              userSessionStatus?.observationLimited != true, userSessionStatus?.ownReleasePending != true,
              userSessionStatus?.error == nil, item.icon == .mark(.held) else { return item }
        item.text = Self.menuBarRemainingText(seconds: remaining)
        return item
    }

    /// At most six ASCII characters, independent of locale and wall-clock edits.
    /// Hours/days deliberately omit smaller units to keep the menu bar compact.
    static func menuBarRemainingText(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "<1m" }
        guard seconds < 1000 * 86400 else { return "999d+" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        let days = minutes / 1440, hours = (minutes % 1440) / 60
        return days >= 100 || hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
    }

    // MARK: Problems

    /// Something the user has to act on, shown as a banner above everything else.
    enum Problem {
        case translocated, missing, down, outdated, error(String), lid(String)

        var title: String {
            switch self {
            case .translocated: L("Move Tether to Applications", "Tether를 응용 프로그램 폴더로 이동")
            case .missing: L("The helper isn't installed", "도우미가 설치되지 않았습니다")
            case .down: L("The helper isn't responding", "도우미가 응답하지 않습니다")
            case .outdated: L("The helper needs an update", "도우미 업데이트가 필요합니다")
            case .error: L("Keep-awake needs review", "유지 상태 확인 필요")
            case .lid: L("Closed-lid support needs review", "덮개 지원 확인 필요")
            }
        }

        var message: String {
            switch self {
            case .translocated: L("It's running from a temporary copy macOS made of the download. Quit, move Tether.app to Applications, and open it again.",
                                  "macOS가 다운로드한 앱을 임시 위치에서 실행하고 있습니다. 앱을 종료하고 Tether.app을 응용 프로그램 폴더로 옮긴 뒤 다시 실행해야 합니다.")
            case .missing: L("Installation requires administrator authentication once.", "관리자 인증을 한 번 완료하면 설치됩니다.")
            case .down: L("It may be off in Login Items, or stopped after a macOS update.", "로그인 항목에서 꺼졌거나 macOS 업데이트 뒤 멈췄을 수 있습니다.")
            case .outdated: L("An older helper than this app is running.", "앱보다 오래된 도우미가 실행 중입니다.")
            case .error(let text): text
            case .lid(let text): text
            }
        }

        /// Generic errors share diagnostic tools; their source is not inferred
        /// from localized prose or presented as a known helper failure.
        var reviewLabel: String {
            if case .error = self { return L("Review protection and diagnostics…", "보호·진단에서 확인…") }
            return L("Review setup…", "도우미 상태 보기…")
        }

        var action: String? {
            switch self {
            case .translocated, .error: nil
            case .missing: L("Install Helper…", "도우미 설치…")
            case .down: L("Reinstall…", "다시 설치…")
            case .outdated: L("Update…", "업데이트…")
            case .lid: L("Retry", "다시 확인")
            }
        }

        var color: Color {
            switch self {
            case .down, .error: .tetherError
            case .translocated, .missing, .outdated, .lid: .tetherWarning
            }
        }
    }

    var problem: Problem? {
        if let coordinatedLidError { return .lid(coordinatedLidError) }
        if let errorText { return .error(errorText) }
        if let code = protection?.lastError { return .error(ServiceFailure(code).localizedDescription) }
        guard supportedMac else { return nil }
        if isTranslocated { return .translocated }
        if usesUserSession { return nil }
        if !helperInstalled { return .missing }
        if !helperResponding { return .down }
        if helperOutdated { return .outdated }
        return nil
    }

    /// One line for the settings window: is the helper there, alive, current?
    var helperStatus: (text: String, color: Color) {
        if usesUserSession && !capabilities.lidControlAvailable { return (L("Not required for keep-awake", "일반 잠자기 방지에는 필요 없음"), .secondary) }
        if !helperInstalled { return (L("not installed", "설치되지 않음"), .tetherWarning) }
        guard helperResponding, let status else { return (L("not responding", "응답 없음"), .red) }
        if developmentService { return (L("preview · v\(status.version)", "미리보기 · v\(status.version)"), .tetherSuccess) }
        if helperOutdated { return (L("needs an update · v\(status.version)", "업데이트 필요 · v\(status.version)"), .tetherWarning) }
        return (L("running · v\(status.version)", "실행 중 · v\(status.version)"), .tetherSuccess)
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
        batteryPercent.map { "\($0)%" } ?? "–"
    }

    var deviceStatusSymbol: String {
        if capabilities.hardware == .desktop { return "desktopcomputer" }
        if capabilities.hardware == .portable { return snapshot.lidClosed ? "laptopcomputer.slash" : "laptopcomputer" }
        return "display"
    }
    var generalSessionDetail: String {
        if lidReleasePending { return L("General work continues; closed-lid release awaits confirmation", "일반 작업 유지 중 · 덮개 유지 해제 확인 중") }
        if let notice = lidObservationNotice { return notice }
        if !workSessionHolding { return L("Display sleep and locking follow macOS settings", "화면 꺼짐과 잠금은 macOS 설정을 따릅니다") }
        if capabilities.lidControlAvailable && snapshot.displayTopology == .unknown {
            return L("Work continues · rechecking display connections", "작업 유지 중 · 화면 연결 다시 확인 중")
        }
        if capabilities.lidControlAvailable {
            return lidUsageStatusText + L(" · locking follows macOS", " · 잠금은 macOS 설정을 따름")
        }
        return capabilities.hardware == .desktop
            ? L("Display sleep and locking follow macOS settings", "화면 꺼짐과 잠금은 macOS 설정을 따릅니다")
            : L("Idle sleep is prevented; lid closing and locking follow macOS settings", "일반 절전만 방지합니다. 덮개를 닫을 때와 잠금은 macOS 설정을 따릅니다")
    }
    var lidDetail: String {
        if usesUserSession { return generalSessionDetail }
        if let notice = lidObservationNotice { return notice }
        guard let closed = snapshot.observedLidClosed else { return L("Checking lid state", "덮개 상태 확인 중") }
        if !closed { return L("Lid open · macOS controls display sleep", "덮개 열림 · 화면 끄기는 macOS 설정에 따름") }
        if snapshot.displayTopology == .unknown { return DisplayTopology.unknown.title }
        if snapshot.externalDisplay { return snapshot.displayTopology.title + L(" · no all-display sleep", " · macOS가 화면 관리") }
        if status?.displaySleeping == true { return L("display asleep", "화면 꺼짐으로 보고됨") }
        return clamshellActive ? L("display sleep requested", "화면 끄기 요청 중") : L("sleep allowed", "잠자기 허용")
    }

    /// Screen recovery is a separate capability; it never changes the work title
    /// or the automatic/manual session. Do not present stale closed-lid observations.
    var displaySleepStatus: DisplayRecoveryStatus? {
        guard v3Settings.closedLidDisplayMode == .off else { return nil }
        guard helperResponding, capabilities.lidControlAvailable, clamshellActive,
              snapshot.lidControlObservationAvailable, snapshot.observedLidClosed == true,
              snapshot.observedFullWake == true, snapshot.displayTopology != .unknown,
              let status, status.displayTopology == snapshot.displayTopology else { return nil }
        return status.currentDisplayRecovery()
    }

    var displaySleepSummary: String? {
        guard let recovery = displaySleepStatus else { return nil }
        guard snapshot.externalDisplay else { return recovery.summary }
        return switch recovery.phase {
        case .asleep: L("Built-in display sleep observed", "내장 화면 절전 관측")
        case .deferred: L("Built-in display awake · all-display sleep withheld", "내장 화면 켜짐 · 전체 화면 절전 보류")
        default: L("Built-in display unconfirmed · all-display sleep withheld", "내장 화면 상태 미확인 · 전체 화면 절전 보류")
        }
    }

    var displaySleepDetail: String? {
        guard displaySleepStatus != nil, snapshot.externalDisplay else { return nil }
        if [.virtualOnly, .externalWithVirtual].contains(snapshot.displayTopology) {
            return L("A virtual display may be needed for remote rendering, so all-display sleep is withheld. Work and time limits continue; remote frames, input and lock state need separate confirmation.",
                     "원격 화면에 가상 화면이 필요할 수 있어 전체 화면 절전 명령을 보류합니다. 작업 유지와 시간 한도는 계속 적용되며, 원격 화면·입력과 잠금 상태는 별도 확인이 필요합니다.")
        }
        return L("All-display sleep could turn connected screens off, so it is withheld. Keep-awake and its time limits still apply.",
                 "외장 화면까지 꺼질 수 있어 전체 화면 절전을 보류합니다. 잠자기 방지와 유지 시간 제한은 계속 적용됩니다.")
    }

    var lidObservationNotice: String? {
        guard capabilities.lidControlAvailable, helperResponding, !snapshot.lidControlObservationAvailable else { return nil }
        let parts = snapshot.unavailablePowerObservations.map {
            switch $0 {
            case "lid": L("lid", "덮개")
            case "sleepOverride": L("sleep setting", "절전 설정")
            default: L("wake state", "깨움 상태")
            }
        }.joined(separator: "·")
        return usesUserSession && workSessionHolding
            ? L("Work continues · rechecking \(parts)", "작업 유지 중 · \(parts) 다시 확인 중")
            : L("Rechecking \(parts) before changing lid support", "덮개 유지 변경 전 \(parts) 다시 확인 중")
    }

    var temperatureValue: String {
        if usesUserSession { return Texts.thermal(thermalLevel) }
        guard let t = status?.batteryTemperature ?? SystemProbe.batteryTemperature() else { return "–" }
        return String(format: "%.1f°C", t)
    }

    var thermalLevel: Int { userSessionStatus?.thermal ?? status?.thermal ?? ProcessInfo.processInfo.thermalState.rawValue }

    var sessionConditionTitle: String {
        usesUserSession ? (userSessionStatus?.automaticEnabled == true ? powerCondition.title : L("Manual keep-awake", "수동 유지")) : powerCondition.title
    }

    var thermalLabel: String {
        heatGuardActive ? L("Low Power Mode", "저전력 모드") : L("heat ", "발열 ") + Texts.thermal(thermalLevel)
    }

    /// The same in as few characters as possible, for the status module's narrow rows.
    var thermalShort: String {
        heatGuardActive ? L("Low Power", "저전력 모드") : L(Texts.thermal(thermalLevel), "발열 " + Texts.thermal(thermalLevel))
    }

    var thermalColor: Color {
        switch thermalLevel {
        case 0: .tetherSuccess
        case 1: .tetherWarning
        case 2: .tetherWarning
        default: .red
        }
    }

    // MARK: Records

    /// Who armed the hold, when it wasn't this app's panel.
    var holdSourceText: String? { Texts.holdSource(holdSource) }

    var lastEventText: String? {
        guard let status, let event = status.lastEvent, let at = status.lastEventAt else { return nil }
        let time = Texts.time(Date(timeIntervalSince1970: at))
        return "\(time) · \(event.displayText)"
    }
}

extension AppModel {
    var showsLidOptions: Bool { capabilities.lid == true && capabilities.hardware != .desktop }
    var workProtectionReason: String? { userSessionStatus?.blockReason ?? protection?.blockReason }
    var workPaused: Bool {
        !v3Settings.enabled || workProtectionReason != nil || v3Settings.runtimeMarkers?.pauseReason != nil
    }
    var automaticBatteryEnded: Bool {
        guard !workPaused, let session = userSessionStatus, session.power == .battery,
              session.automaticEnabled, session.powerCondition.includesBattery,
              !session.automaticActive, !session.manualActive, !session.holding else { return false }
        return v3Settings.runtimeMarkers?.automaticActivation?.batteryExpired == true
    }
    var canResumeWork: Bool {
        acceptingUserCommands && userSession?.canResume == true
    }
    var observedThermalSummary: String {
        let value = userSessionStatus?.thermal ?? status?.thermal
        guard let value, (0...3).contains(value) else { return L("Not confirmed", "확인되지 않음") }
        return Texts.thermal(value)
    }
    var automaticSelectionSummary: String {
        v3Settings.automaticEnabled ? v3Settings.condition.title : L("Off", "꺼짐")
    }
    /// Shared execution copy, independent of the saved permission toggles.
    var featureStopSummary: String? {
        if workProtectionReason != nil { return L("Stopped for protection", "보호로 중지됨") }
        guard workPaused else { return nil }
        switch v3Settings.runtimeMarkers?.pauseReason {
        case .userSleep: return L("Waiting after Sleep request", "잠자기 요청 후 대기")
        case .ownerEnded: return L("Keep-awake ended", "유지 종료됨")
        default: return L("All keep-awake stopped", "모두 중지됨")
        }
    }
    var automaticStartStateDetail: String {
        if userSessionStatus?.ownReleasePending == true || lidReleasePending {
            return L("Checking keep-awake release. New starts wait for confirmation.",
                     "유지 해제를 확인하고 있습니다. 확인 전에는 새로 시작하지 않습니다.")
        }
        if workProtectionReason != nil {
            return L("Stopped for protection. Saved automatic settings remain; safety and resume settings are checked before work can restart.",
                     "보호로 중지됨. 자동 시작 설정은 보존하며, 안전 상태와 재개 설정을 확인한 뒤 다시 시작할 수 있습니다.")
        }
        if workPaused {
            if v3Settings.runtimeMarkers?.pauseReason == .userSleep {
                return L("Waiting after a Sleep request. Resume or a new automatic condition is required; ended manual work does not restart.",
                         "잠자기 요청 후 대기 중입니다. 중지 해제나 새 자동 조건이 필요하며, 종료된 수동 유지는 다시 시작하지 않습니다.")
            }
            if v3Settings.runtimeMarkers?.pauseReason == .ownerEnded, canStartManualSession {
                return L("Automatic starts remain stopped. You can start new manual work separately.",
                         "자동 시작은 멈춰 있습니다. 새 수동 유지는 따로 시작할 수 있습니다.")
            }
            return L("All keep-awake stopped. Resume rechecks automatic conditions; ended manual work does not restart.",
                     "모두 중지됨. 중지를 해제하면 자동 조건을 다시 확인하며, 종료된 수동 유지는 다시 시작하지 않습니다.")
        }
        if automaticPauseActive {
            return L("Only automatic starts are paused. Manual deadlines and saved automatic settings stay unchanged.",
                     "자동 시작만 일시 중지합니다. 수동 유지 기한과 저장된 자동 설정은 바뀌지 않습니다.")
        }
        if !automaticEnabled {
            if manualSessionActive, workSessionHolding {
                return L("Automatic start is off. Current manual work keeps its original deadline and protection limits.",
                         "자동 시작은 꺼져 있습니다. 현재 수동 유지는 원래 기한과 보호 한도를 따릅니다.")
            }
            return canStartManualSession
                ? L("Automatic start is off. You can start manual keep-awake separately.", "자동 시작은 꺼져 있습니다. 수동 유지는 따로 시작할 수 있습니다.")
                : L("Automatic start is off. Manual starts require current power and protection checks.", "자동 시작은 꺼져 있습니다. 수동 시작에는 현재 전원·보호 상태 확인이 필요합니다.")
        }
        if automaticWorkReasonActive, workSessionHolding {
            return v4Settings.usesAdvancedAutomaticConditions
                ? L("Automatic keep-awake is active for the selected conditions.", "선택한 조건으로 자동 유지 중입니다.")
                : L("Automatic keep-awake is active while power is connected.", "전원 연결 조건으로 자동 유지 중입니다.")
        }
        return v4Settings.usesAdvancedAutomaticConditions
            ? L("Starts when the selected conditions and protection checks allow.", "선택한 조건과 보호 기준을 충족하면 시작합니다.")
            : L("Starts on power when this Mac is awake and protection allows.", "깨어 있는 Mac에서 전원이 연결되고 보호 중이 아니면 시작합니다.")
    }
    var displayUsageStatusText: String {
        if userSessionStatus?.ownReleasePending == true {
            return [featureStopSummary, L("Checking keep-awake release", "유지 해제 확인 중")]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if userSessionStatus?.displayError != nil {
            return [featureStopSummary, L("Display keep-awake needs review", "화면 켜두기 확인 필요")]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if !v3Settings.keepDisplayAwake { return L("Display sleep follows macOS", "화면 절전은 macOS에 맡김") }
        if let stopped = featureStopSummary { return stopped + L(" · permission stays enabled", " · 허용 설정 유지") }
        if userSessionStatus?.displayHolding == true {
            return L("Display keep-awake requested · locking follows macOS", "화면 켜두기 요청 중 · 잠금은 macOS 설정을 따름")
        }
        if !workSessionHolding {
            return manualSessionActive || automaticWorkReasonActive
                ? L("Allowed · keep-awake not confirmed", "허용 저장됨 · 유지 적용 확인 필요")
                : L("Allowed · no keep-awake session active", "허용 저장됨 · 현재 유지 없음")
        }
        return userSessionStatus?.displayHolding == nil
            ? L("Checking display keep-awake", "화면 켜두기 상태 확인 중")
            : L("Allowed · not applied to this session", "허용됨 · 이번 유지에는 화면 켜두기 미적용")
    }
    var lidSupportConfirmed: Bool {
        v3Settings.allowClosedLid && clamshellActive && coordinatedLidError == nil
            && coordinatedLidBlockReason == nil && !lidReleasePending
    }
    var lidSupportSummary: String {
        if lidReleasePending { return L("Release unconfirmed", "해제 확인 중") }
        if !v3Settings.allowClosedLid { return L("Off", "꺼짐") }
        if lidSupportConfirmed { return L("Closed-lid support applied", "덮개 유지 기능 적용됨") }
        return L("Not confirmed", "준비 미확인")
    }
    /// A saved permission and an applied helper override do not prove that the
    /// lid is physically closed. Share the observed position + execution status
    /// between the menu and settings without changing a request or its policy.
    var lidUsageStatusText: String {
        let position: String = switch snapshot.observedLidClosed {
        case true?: L("Lid closed", "덮개 닫힘")
        case false?: L("Lid open", "덮개 열림")
        case nil: L("Checking lid state", "덮개 상태 확인 중")
        }
        let execution: String
        if lidReleasePending {
            execution = L("checking support release", "덮개 유지 해제 확인 중")
        } else if userSessionStatus?.ownReleasePending == true {
            execution = L("Checking keep-awake release", "유지 해제 확인 중")
        } else if !v3Settings.allowClosedLid {
            execution = L("closed-lid permission off", "덮개 유지 허용 꺼짐")
        } else if let stopped = featureStopSummary {
            execution = stopped
        } else if workSessionHolding, userSession?.v4LidRequested == false {
            execution = L("closed-lid use not selected for this session", "이번 유지에는 덮개 기능 미선택")
        } else if !workSessionHolding, helperSetupConfirmed {
            execution = manualSessionActive || automaticWorkReasonActive
                ? L("keep-awake not confirmed", "유지 적용 확인 필요")
                : L("no keep-awake session", "현재 유지 없음")
        } else if lidSupportConfirmed, let closed = snapshot.observedLidClosed {
            execution = closed ? L("closed-lid support active", "덮개 유지 적용 중")
                : L("ready for closed-lid use", "닫고 사용 준비됨")
        } else if !helperSetupConfirmed {
            execution = L("helper setup needed", "도우미 준비 필요")
        } else {
            execution = L("closed-lid support unconfirmed", "덮개 유지 적용 확인 필요")
        }
        return position + " · " + execution
    }
    var disconnectActionDetail: String {
        v3Settings.disconnectAction == .sleepIfClosed
            ? L("A sleep request can also pause work in other apps.",
                "잠자기 요청은 다른 앱의 작업도 멈출 수 있습니다.")
            : L("Tether cannot clear another app's sleep-prevention requests.",
                "Tether는 다른 앱의 절전 방지 요청을 해제하지 않습니다.")
    }
    var lockOnCloseDetail: String {
        if !canRequestLockOnClose {
            return L("Tether's lock command is unavailable on this OS. macOS password requirements still apply; review them below.",
                     "현재 OS에서 Tether의 잠금 명령을 사용할 수 없습니다. macOS의 암호 요구는 계속 적용되며 아래 설정에서 확인할 수 있습니다.")
        }
        if !v3Settings.lockOnClose {
            return L("Tether does not request a lock. macOS may still lock when the display sleeps.",
                     "Tether는 잠금을 요청하지 않습니다. 화면 절전 시 macOS가 잠글 수 있습니다.")
        }
        if !lidSupportConfirmed {
            return L("Tether requests a lock. Closed-lid keep-awake is not confirmed until setup and restoration are complete.",
                     "Tether가 잠금을 요청합니다. 도우미 준비·복구가 확인되기 전에는 덮개 유지를 제공할 수 없습니다.")
        }
        return L("Tether requests a lock. Work can continue while locked only during valid closed-lid keep-awake.",
                 "Tether가 잠금을 요청합니다. 유효한 덮개 유지가 동작할 때만 잠긴 채 작업을 계속할 수 있습니다.")
    }
}
