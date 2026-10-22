import Foundation

public struct HealthCheck: Equatable, Sendable {
    public enum Result: String, Sendable { case ok, warning, failed }
    public let name: String
    public let result: Result
    public let detail: String
}

/// A scheduled watchdog is normally idle. Its own completion receipt establishes that it ran;
/// a plist, a process name, or launchd registration alone does not establish that.
public struct WatchdogReceipt: Codable, Equatable, Sendable {
    public var checkedAt: Double
    public var boot: String
    public var exitStatus: Int
}

/// A live launchd process can outlast files removed from disk. These are the
/// durable components required to start and safely recover the installed helper.
public enum HelperInstallationFile: String, CaseIterable, Sendable {
    case helper, helperRegistration, watchdog, watchdogRegistration, recoveryLock, recoveryExecutor

    public var path: String {
        switch self {
        case .helper: TetherPaths.helperPath
        case .helperRegistration: TetherPaths.helperPlistPath
        case .watchdog: TetherPaths.watchdogPath
        case .watchdogRegistration: TetherPaths.watchdogPlistPath
        case .recoveryLock: TetherPaths.recoveryLockLibraryPath
        case .recoveryExecutor: TetherPaths.recoveryExecutorPath
        }
    }

    public var requiresExecutable: Bool { self != .helperRegistration && self != .watchdogRegistration }

    public func title(language: Language) -> String {
        let korean = language == .korean
        switch self {
        case .helper: return korean ? "전원 관리 도우미" : "Power management helper"
        case .helperRegistration: return korean ? "도우미 실행 예약" : "Helper startup registration"
        case .watchdog: return korean ? "독립 감시 장치" : "Independent watchdog"
        case .watchdogRegistration: return korean ? "감시 장치 실행 예약" : "Watchdog startup registration"
        case .recoveryLock: return korean ? "원복 보호 구성 요소" : "Recovery coordination component"
        case .recoveryExecutor: return korean ? "원복 실행 도구" : "Recovery executor"
        }
    }
}

public enum HealthChecks {
    enum Registration: Equatable { case registered, missing, unavailable }
    struct Evidence {
        var supported = true
        var capabilities: MacCapabilities?
        var userSessionRequested = false
        var userSession: UserSessionReply?
        var helperInstalled = false
        var missingHelperFiles: [HelperInstallationFile]?
        var reply: ServiceReply?
        var serviceError: String?
        var watchdogInstalled = false
        var watchdogRegistration = Registration.unavailable
        var watchdogReceipt: WatchdogReceipt?
        var boot = ContinuousTime.bootID
        var snapshot = Snapshot(power: .unknown, lidClosed: false, sleepDisabled: false)
        var temperature: Double?
    }

    public static func missingHelperFiles(fileManager: FileManager = .default) -> [HelperInstallationFile] {
        HelperInstallationFile.allCases.filter { file in
            var directory = ObjCBool(false)
            return !fileManager.fileExists(atPath: file.path, isDirectory: &directory) || directory.boolValue
                || (file.requiresExecutable && !fileManager.isExecutableFile(atPath: file.path))
        }
    }

    /// Only an authenticated live reply supplies helper state. A recently written status file
    /// can survive a crash; mixing it with a separate control file also races configuration.
    public static func run(now: Date? = nil, language: Language = Localization.current,
                           userSession: UserSessionReply? = nil, userSessionRequested: Bool = false,
                           capabilities: MacCapabilities? = nil) -> [HealthCheck] {
        var evidence = Evidence()
        evidence.capabilities = capabilities ?? SystemProbe.capabilities
        evidence.supported = evidence.capabilities?.generalIdleAvailable == true
        evidence.userSession = userSession; evidence.userSessionRequested = userSessionRequested
        guard evidence.supported else { return evaluate(evidence, now: now ?? Date(), language: language) }
        // A desktop or an uncertain lid observation still supports common work.
        // Do not prescribe privileged helper installation for that execution path.
        if userSessionRequested, evidence.capabilities?.helperInstallTarget != .portable {
            return evaluate(evidence, now: now ?? Date(), language: language)
        }
        evidence.missingHelperFiles = missingHelperFiles()
        evidence.helperInstalled = evidence.missingHelperFiles?.isEmpty == true
        do { evidence.reply = try ServiceClient().perform(ServiceRequest(.snapshot)) }
        catch { evidence.serviceError = (error as? ServiceFailure)?.code ?? "unavailable" }
        evidence.watchdogInstalled = FileManager.default.isExecutableFile(atPath: TetherPaths.watchdogPath)
            && FileManager.default.fileExists(atPath: TetherPaths.watchdogPlistPath)
        if evidence.watchdogInstalled {
            // launchctl print's text is explicitly not an API. Use only the targeted command's
            // success to establish registration; never parse an undocumented state/PID layout.
            let result = Shell.run("/bin/launchctl", ["print", "system/" + TetherPaths.watchdogLabel], timeout: 2, maxOutputBytes: 256)
            evidence.watchdogRegistration = result.status == 0 ? .registered : result.status == 113 ? .missing : .unavailable
            evidence.watchdogReceipt = JSONFile.read(WatchdogReceipt.self, from: TetherPaths.watchdogStatusPath)
        }
        evidence.snapshot = SystemProbe.snapshot()
        evidence.temperature = SystemProbe.batteryTemperature()
        // A helper snapshot can refresh its observations during this read. Compare at
        // collection completion, not before the IPC request, to avoid a false future date.
        return evaluate(evidence, now: now ?? Date(), language: language)
    }

    static func fresh(_ timestamp: Double?, now: Date) -> Bool {
        guard let timestamp, timestamp.isFinite else { return false }
        let age = now.timeIntervalSince1970 - timestamp
        return age >= 0 && age < 90
    }

    static func evaluate(_ e: Evidence, now: Date, language: Language) -> [HealthCheck] {
        func t(_ en: String, _ ko: String) -> String { language == .korean ? ko : en }
        var out: [HealthCheck] = []
        func add(_ name: String, _ result: HealthCheck.Result, _ detail: String) {
            out.append(HealthCheck(name: name, result: result, detail: detail))
        }
        guard e.supported else {
            add(t("Supported platform", "지원 환경"), .warning,
                t("Apple Silicon and macOS 26 or later are required.", "Apple Silicon과 macOS 26 이상이 필요합니다."))
            return out
        }
        if e.userSessionRequested {
            out += commonChecks(e.userSession, now: now, language: language)
            if e.capabilities?.helperInstallTarget != .portable { return out }
        }
        if !e.helperInstalled {
            let components = e.missingHelperFiles?.map { $0.title(language: language) }.joined(separator: ", ")
            let detail: String
            if let components, !components.isEmpty {
                detail = t("Required installation components are unavailable: \(components). Repair the helper in App Settings; a live reply does not confirm installation on disk.",
                           "필수 설치 구성 요소를 사용할 수 없습니다: \(components). 앱 설정에서 도우미를 복구해 주세요. 실시간 응답과 영구 설치 상태는 별도로 확인합니다.")
            } else {
                detail = t("Helper files are missing. Install it from App Settings.", "도우미 파일이 없습니다. 앱 설정에서 설치해 주세요.")
            }
            add(t("Helper installation", "도우미 설치"), .failed, detail)
        }
        let reply = e.reply
        let connected = reply?.ok == true && reply?.version == 2 && reply?.protection?.protocolVersion == 2
        let stateFresh = fresh(reply?.status?.updatedAt, now: now)
        if !connected {
            let mismatch = e.serviceError == "unsupportedVersion" || reply.map { $0.version != 2 || $0.protection?.protocolVersion != 2 } == true
            add(t("Helper connection", "도우미 연결"), .failed, mismatch
                ? t("Protocol mismatch. Update the app and helper together.", "통신 규약이 다릅니다. 앱과 도우미를 함께 업데이트해 주세요.")
                : t("No valid live reply. Check the helper in App Settings; a saved status file is not proof of a connection.", "실시간 응답을 확인하지 못했습니다. 앱 설정에서 도우미를 확인해 주세요."))
        } else {
            add(t("Helper connection", "도우미 연결"), .ok, t("Authenticated live reply · protocol 2", "실시간 응답 확인 · 통신 규약 2"))
            if let status = reply?.status {
                let version = "\(status.version) (\(status.build.map(String.init) ?? "?"))"
                add(t("Helper version", "도우미 버전"), status.matchesCurrentBuild ? .ok : .failed,
                    status.matchesCurrentBuild ? version
                    : t("Helper \(version); app \(TetherPaths.version) (\(TetherPaths.build)). Finish the helper update.", "도우미 \(version) · 앱 \(TetherPaths.version) (\(TetherPaths.build)). 도우미 업데이트를 마무리해 주세요."))
            }
            add(t("Helper observations", "도우미 관측"), stateFresh ? .ok : .warning,
                stateFresh ? t("Recent observations received with the live reply.", "실시간 응답에 최근 관측값이 포함되어 있습니다.")
                    : t("The reply has missing, stale or future-dated observations. Recheck after waking; do not treat this as current state.", "관측값이 없거나 오래됐거나 시각이 맞지 않습니다. 깨어난 뒤 다시 확인해 주세요."))
        }
        if !e.watchdogInstalled {
            add(t("Watchdog", "감시 장치"), .failed, t("Files missing. Reinstall the helper.", "파일이 없습니다. 도우미를 다시 설치해 주세요."))
        } else if e.watchdogRegistration != .registered {
            add(t("Watchdog", "감시 장치"), .warning, e.watchdogRegistration == .missing
                ? t("Files exist, but the scheduled job is not registered with launchd. Reinstall the helper.", "파일은 있지만 macOS에 실행 예약이 등록되지 않았습니다. 도우미를 다시 설치해 주세요.")
                : t("Files exist, but launchd registration could not be checked. Registration and recent execution remain unverified.", "파일은 있지만 macOS 실행 예약을 조회하지 못했습니다. 등록과 최근 실행을 확인할 수 없습니다."))
        } else if let receipt = e.watchdogReceipt, receipt.boot == e.boot, e.boot != "unknown", fresh(receipt.checkedAt, now: now) {
            add(t("Watchdog", "감시 장치"), receipt.exitStatus == 0 ? .ok : .failed, receipt.exitStatus == 0
                ? t("Scheduled job registered; a recent check completed. This does not prove physical sleep.", "실행 예약과 최근 점검 완료를 확인했습니다. 실제 잠자기 성공을 뜻하지는 않습니다.")
                : t("The latest watchdog check failed (exit \(receipt.exitStatus)). Review the diagnostic report.", "최근 감시 점검이 실패했습니다(종료 코드 \(receipt.exitStatus)). 진단 보고서를 확인해 주세요."))
        } else {
            add(t("Watchdog", "감시 장치"), .warning, t("Registered, but no recent completion from this boot. Recheck after the next scheduled run; older helpers need updating.", "등록되어 있지만 이번 부팅의 최근 점검 완료 기록이 없습니다. 다음 점검 후 다시 확인하고, 구형 도우미는 업데이트해 주세요."))
        }
        if connected, let reply, !reply.control.isSupported {
            add(t("Settings format", "설정 형식"), .failed, t("Unsupported settings format. Preserve the backup and update the app and helper together.", "지원하지 않는 설정 형식입니다. 백업을 보존하고 앱과 도우미를 함께 업데이트해 주세요."))
        }
        if connected, stateFresh, let reply, reply.control.isSupported, let status = reply.status, status.matchesCurrentBuild {
            let appConnected = status.appConnected == true
            add(t("App session", "앱 실행 연결"), appConnected || (!reply.control.enabled && status.appConnected == false) ? .ok : .warning,
                appConnected ? t("The running app is connected to the helper.", "실행 중인 앱이 도우미에 연결되어 있습니다.")
                : status.appConnected == nil ? t("The helper did not report an app connection. Active operation is unverified.", "도우미가 앱 연결 상태를 반환하지 않아 동작 여부를 확인할 수 없습니다.")
                : reply.control.enabled ? t("Tether is enabled in saved preferences, but the app is disconnected. Open Tether to resume; the helper releases its hold when the app exits.", "켜기 설정은 저장되어 있지만 앱 연결이 끊겨 유지를 중단했습니다. Tether를 실행해 주세요. 앱을 종료하면 도우미도 유지를 해제합니다.")
                : t("Tether is turned off and the app is disconnected.", "Tether가 꺼져 있고 앱 연결도 종료되어 있습니다."))
            let protection = reply.protection ?? status.protection
            if let reason = protection?.blockReason {
                add(t("Protection", "보호 상태"), .warning, t("Protection stopped the session. Review Protection before resuming.", "보호를 위해 중지된 상태입니다. 기기 보호에서 원인을 확인한 뒤 재개해 주세요.") + " (\(reason))")
            }
            if protection?.lastError != nil {
                add(t("Power changes", "전원 설정 적용"), .failed, t("The helper reported an apply/restore error. Review the diagnostic report.", "도우미가 적용·복원 오류를 보고했습니다. 진단 보고서를 확인해 주세요."))
            }
            if let recovery = status.currentDisplayRecovery(now: now) {
                let confirmed = recovery.phase == .asleep && status.displaySleeping == true
                add(t("Display sleep", "화면 절전"), confirmed ? .ok : .warning,
                    recovery.summary + (confirmed
                        ? t(". OS observation only; panel power is not measured.", ". OS 관측값이며 패널 전력을 측정한 것은 아닙니다.") : ""))
            } else if status.observedLidClosed == true, status.fullWake == true,
                      status.ownsOverride == true, status.appConnected == true,
                      status.observedSleepDisabled == true, status.displayTopology == DisplayTopology.none {
                add(t("Display sleep", "화면 절전"), .warning,
                    t("No current recovery observation; sleep prevention alone does not confirm display sleep.", "화면 복구 관측이 없습니다. 잠자기 방지 설정만으로 화면 꺼짐을 확인할 수 없습니다."))
            }
            let s = e.snapshot
            if s.lidControlObservationAvailable, s.observedFullWake == true, status.fullWake == true,
               s.power != .unknown, s.displayTopology != .unknown,
               s.power == status.power, s.observedLidClosed == status.observedLidClosed,
               s.observedSleepDisabled == status.observedSleepDisabled, s.displayTopology == status.displayTopology {
                // Never diagnose a foreign override as Tether's successful action. Also use
                // the app lease and pending sleep request, which the old check ignored.
                let holding = status.batteryHoldUntil.map { $0 > now.timeIntervalSince1970 } ?? false
                let common = e.userSessionRequested ? currentCommonStatus(e.userSession, now: now) : nil
                if e.userSessionRequested, common == nil || ![.active, .inactive].contains(e.userSession?.lidSupport ?? .unavailable) {
                    add(t("Sleep setting", "잠자기 설정"), .warning,
                        t("Common work and lid support do not yet have a current settled reply. No rule verdict.", "공통 작업·덮개 지원의 현재 응답이 준비되지 않아 규칙 판정을 보류합니다."))
                } else {
                    let expected = e.userSessionRequested ? e.userSession?.lidSupport == .active
                        : Policy.wantsClamshell(s, enabled: reply.control.enabled && protection?.blockReason == nil && status.appConnected == true,
                            sleepNowPending: reply.control.sleepNowRequest != nil, batteryHold: holding, condition: reply.control.condition)
                    let owned = status.ownsOverride == true
                    let foreign = s.sleepDisabled && !owned
                    let matches = s.sleepDisabled == expected && (!expected || owned)
                    add(t("Sleep setting", "잠자기 설정"), matches && !foreign ? .ok : .warning,
                        foreign ? t("Another setting prevents sleep; Tether does not own this override.", "Tether가 설정하지 않은 잠자기 방지가 남아 있습니다. 다른 앱·설정을 점검해 주세요.")
                        : matches ? t("The observed setting matches the current rule. Actual sleep is a separate observation.", "관측된 설정이 현재 규칙과 일치합니다. 실제 잠자기 여부는 별도로 확인해야 합니다.")
                        : t("Setting and rule differ. Recheck after the transition; create a report if this persists.", "설정과 규칙이 다릅니다. 전환 후 다시 확인하고 계속되면 보고서를 만들어 주세요."))
                }
            } else {
                add(t("Sleep setting", "잠자기 설정"), .warning, t("Power, display or wake state is changing or unavailable; no rule verdict yet.", "전원·화면·깨어남 상태가 바뀌는 중이거나 확인되지 않아 규칙 판정을 보류합니다."))
            }
            if DiagnosticRecording.isActive(enabled: reply.control.debugLog, until: reply.control.debugLogUntil, now: now) {
                add(t("Detailed recording", "상세 기록"), .ok, reply.control.debugLogUntil.map {
                    t("Recording ends automatically at \(Texts.time(Date(timeIntervalSince1970: $0))).", "\(Texts.time(Date(timeIntervalSince1970: $0)))에 자동으로 기록을 끝냅니다.")
                } ?? t("Recording until you stop it in App Settings.", "앱 설정에서 직접 끝낼 때까지 기록합니다."))
            }
        }
        add(t("Battery temperature", "배터리 온도"), e.temperature?.isFinite == true ? .ok : .warning,
            e.temperature.flatMap { $0.isFinite ? String(format: "%.1f °C", $0) : nil }
                ?? t("Optional diagnostic sensor unavailable. Protection uses macOS thermal state.", "선택적 진단 센서값을 제공하지 않습니다. 보호는 macOS 시스템 발열 상태를 사용합니다."))
        return out
    }

    static func currentCommonStatus(_ reply: UserSessionReply?, now: Date) -> UserSessionStatus? {
        guard let reply, reply.ok, reply.version == 1, reply.build == TetherPaths.build,
              fresh(reply.observedAt, now: now) else { return nil }
        return reply.status
    }

    static func commonChecks(_ reply: UserSessionReply?, now: Date, language: Language) -> [HealthCheck] {
        func t(_ en: String, _ ko: String) -> String { language == .korean ? ko : en }
        guard let status = currentCommonStatus(reply, now: now), let reply else {
            return [HealthCheck(name: t("Common work session", "공통 작업 유지"), result: .failed,
                detail: t("No current reply from the matching app coordinator. Saved helper settings do not establish common work.",
                          "같은 빌드의 앱 조정자에서 현재 응답을 확인하지 못했습니다. 저장된 도우미 설정만으로 공통 작업을 판정하지 않습니다."))]
        }
        let requested = status.enabled && status.blockReason == nil && (status.manualActive || status.automaticActive
            || (status.power == .battery && status.batteryHoldUntil.map { $0 > now } == true))
        let unverifiedRequest = requested && !status.holding
        let detail = unverifiedRequest
            ? t("A work session is requested, but the app does not report an active idle-sleep request. Check wake and user-session readiness.",
                "작업 유지가 요청됐지만 앱의 자체 절전 방지 요청은 활성 상태로 확인되지 않습니다. 깨어남과 사용자 세션 상태를 확인해 주세요.")
            : status.holding
            ? t("The app reports its own idle-sleep request active. This does not prove physical lid, display sleep or remote input.",
                "앱의 자체 유휴 절전 방지 요청이 활성 상태입니다. 실제 덮개 유지·화면 절전·원격 입력의 성공을 뜻하지는 않습니다.")
            : status.enabled ? t("Enabled, with no active common request at collection time.", "사용 설정은 켜져 있으며 조회 시점의 공통 유지 요청은 없습니다.")
                : t("The user's off choice is retained; no common request is active.", "사용자의 꺼짐 선택을 유지하며 공통 유지 요청은 없습니다.")
        var checks = [HealthCheck(name: t("Common work session", "공통 작업 유지"),
            result: status.error != nil ? .failed : unverifiedRequest ? .warning : .ok, detail: status.error == nil ? detail
                : t("The app could not verify its own idle-sleep request. Review the report.", "앱이 자체 유휴 절전 방지 요청을 확인하지 못했습니다. 보고서를 확인해 주세요."))]
        if let reason = status.blockReason {
            checks.append(HealthCheck(name: t("Common protection", "공통 보호 상태"), result: .warning,
                detail: t("Protection is paused until an explicit safe resume.", "보호 중지 상태이며 안전한 조건에서 직접 재개해야 합니다.") + " (\(reason))"))
        }
        checks.append(HealthCheck(name: t("Lid support", "덮개 지원"),
            result: reply.lidSupport == .notRequired || reply.lidSupport == .inactive
                || (reply.lidSupport == .active && reply.helperConnected == true && reply.helperBuild == TetherPaths.build && status.holding) ? .ok : .warning,
            detail: reply.lidSupport == .notRequired
                ? t("No privileged lid helper is required for this Mac's common work.", "이 Mac의 공통 작업 유지에는 관리자 덮개 도우미가 필요하지 않습니다.")
                : t("App-reported lid support: \(reply.lidSupport.rawValue). It is independent of common work and remote readiness.",
                    "앱이 보고한 덮개 지원: \(reply.lidSupport.rawValue). 공통 작업 및 원격 준비와 별도로 확인합니다.")))
        return checks
    }
}
