import SwiftUI
import TetherCore

extension AppModel {
    var needsActivityReview: Bool {
        if ["powerConflict", "displayConflict", "ownershipUnreadable"].contains(protection?.blockReason ?? "") { return true }
        return displaySleepStatus.map({ [.stopped, .deferred].contains($0.phase) }) == true
    }
    var expectsDisplaySleep: Bool {
        !v3Settings.keepDisplayAwake && (clamshellActive || protection?.blockReason == "displayConflict")
            && snapshot.lidClosed && !snapshot.externalDisplay
    }
}

struct ActivityReviewView: View {
    @ObservedObject var model: AppModel
    @StateObject private var inspector: PowerActivityInspector
    @StateObject private var initialFocus: SheetInitialFocusState
    @Environment(\.dismiss) private var dismiss
    private let sample: Bool
    init(model: AppModel, sample: Bool = false, presentationOrigin: SheetPresentationOrigin = .unknown) {
        self.model = model; self.sample = sample
        _inspector = StateObject(wrappedValue: PowerActivityInspector(simulated: sample || model.developmentService || model.userCommandsArePreview))
        _initialFocus = StateObject(wrappedValue: SheetInitialFocusState(origin: presentationOrigin))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Sleep influences", "앱·시스템 절전 영향")).font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(L("See what each app requests and where to change it.", "앱이 요청하는 동작과 조정할 위치를 확인하세요."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if inspector.simulated { PreviewNotice() }
                    findingsSummary
                    requestsCard
                    Divider()
                    DisclosureGroup(L("Other installed power apps", "추가로 확인된 전원 앱")) {
                        utilitiesCard.padding(.top, 10)
                    }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("sleep-influences-installed-apps")
                    DisclosureGroup(L("Your Mac and observation details", "현재 Mac·관측 상세")) {
                        contextCard.padding(.top, 10)
                    }.accessibilityIdentifier("sleep-influences-observations")
                    DisclosureGroup(L("macOS idle settings and input", "macOS 대기 설정·입력")) {
                        SleepInfluenceView(model: model, inspector: inspector).padding(.top, 10)
                    }.accessibilityIdentifier("sleep-influences-macos-details")
                    DisclosureGroup(L("Displays and remote observations", "화면·원격 관측")) {
                        VStack(alignment: .leading, spacing: 16) {
                            if let remote = inspector.remoteContext {
                                RemoteFindingsView(context: remote, canOpenSettings: !inspector.simulated) {
                                    model.open(.lockScreen)
                                }
                            }
                            if let displays = inspector.displays { DisplayFindingsView(report: displays) }
                            if inspector.displays == nil && inspector.remoteContext == nil {
                                Note(inspector.busy ? L("Reading display observations…", "화면 정보를 확인하는 중…")
                                    : L("Current display and remote observations are unavailable.", "현재 화면·원격 정보를 확인하지 못했습니다."))
                            }
                        }.padding(.top, 12)
                    }.font(.callout)
                }.padding(20)
            }
            .accessibilityIdentifier("sleep-influences-content")
            Divider()
            HStack(spacing: 12) {
                if inspector.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    PowerObservationFreshness(checkedAt: inspector.checkedAt, refreshing: inspector.busy)
                        .help(inspector.checkedAt?.formatted(date: .abbreviated, time: .standard) ?? L("Not checked yet", "아직 점검하지 않음"))
                    if inspector.clearedRequests > 0 {
                        Text(L("\(inspector.clearedRequests) previous requests no longer observed", "이전 요청 \(inspector.clearedRequests)개가 현재 확인되지 않습니다"))
                            .font(.caption).foregroundStyle(Color.tetherSuccess)
                    }
                }
                Spacer()
                tetherPauseButton
                Button(L("Check again", "다시 점검")) { refresh() }
                    .actionButton(prominent: true).disabled(inspector.busy)
                    .accessibilityIdentifier("sleep-influences-refresh")
            }.padding(18)
        }
        .font(.callout).controlSize(.regular)
        .workSessionWindowSurface()
        .onExitCommand { dismiss() }
        .frame(width: 744, height: 660)
        .background { SheetInitialFocus(state: initialFocus).allowsHitTesting(false) }
        .task { refresh() }
        .onChange(of: model.expectsDisplaySleep) { _, expected in inspector.reclassify(displaySleepExpected: expected) }
        .onChange(of: model.displayRevision) { _, _ in refreshForScopeChange() }
        .onChange(of: model.remoteInspectionSessionKey) { _, _ in refreshForScopeChange() }
        .onDisappear { inspector.cancel() }
    }

    private func refreshForScopeChange() {
        inspector.invalidateRemoteContext(displayRevision: model.displayRevision, sessionKey: model.remoteInspectionSessionKey)
        refresh()
    }
    private func refresh() {
        let revision = model.displayRevision, key = model.remoteInspectionSessionKey
        inspector.refresh(displaySleepExpected: sample || model.expectsDisplaySleep, topology: model.snapshot.displayTopology,
            displayRevision: revision, sessionKey: key, isScopeCurrent: { [weak model] in
                model?.displayRevision == revision && model?.remoteInspectionSessionKey == key
            })
    }
    private func openButton(_ pid: Int32, name: String) -> some View {
        Button(L("Open app", "앱 열기")) { inspector.open(pid) }
            .disabled(!inspector.canOpen(pid))
            .accessibilityLabel(L("Open \(name)", "\(name) 열기"))
    }
    private func appActions(_ pid: Int32, name: String) -> some View {
        HStack(spacing: 8) {
            openButton(pid, name: name)
            Button(L("Show in Finder", "Finder에서 보기")) { inspector.reveal(pid) }
                .disabled(!inspector.canReveal(pid))
                .accessibilityLabel(L("Show \(name) in Finder", "Finder에서 \(name) 보기"))
        }
        .buttonStyle(.bordered).controlSize(.small).tint(.tetherControl)
    }

    private var opposingRequests: [PowerRequestFinding] { inspector.appRequests.filter(\.opposesDisplaySleep) }
    private var findingsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(findingsTitle, systemImage: findingsNeedAttention ? "exclamationmark.circle" : "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(findingsNeedAttention ? Color.tetherWarning : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sleep-influences-conclusion")
            Text(findingsDetail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsActivityReview, let reason = model.protection?.blockReason, !reason.isEmpty {
                Text(protectionReason(reason)).foregroundStyle(Color.tetherWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inspector.globalSleepDisabled == true && !model.clamshellActive {
                Text(L("A shared macOS sleep block is active; its writer cannot be identified. Review observation details.",
                       "macOS 잠자기 차단이 관측됐지만 설정한 앱은 구별할 수 없습니다. 관측 상세를 확인하세요."))
                    .foregroundStyle(Color.tetherWarning).fixedSize(horizontal: false, vertical: true)
            }
            if let note = inspector.note { Note(note) }
        }
        .accessibilityElement(children: .contain)
    }
    private var findingsNeedAttention: Bool {
        !inspector.assertionsAvailable || !opposingRequests.isEmpty || model.needsActivityReview
            || (inspector.globalSleepDisabled == true && !model.clamshellActive)
    }
    private var findingsTitle: String {
        if inspector.busy { return L("Checking current requests…", "현재 요청 확인 중…") }
        if !inspector.assertionsAvailable { return L("App requests could not be read", "앱 요청을 확인하지 못했습니다") }
        if !opposingRequests.isEmpty {
            return L("\(opposingRequests.count) app requests may oppose display sleep", "화면 끄기와 반대되는 요청 \(opposingRequests.count)개")
        }
        if inspector.appRequests.contains(where: { $0.kinds.contains(.display) }) {
            return L("An app requests an awake display", "화면을 켜 두도록 요청하는 앱이 있습니다")
        }
        return inspector.appRequests.isEmpty
            ? L("No other app requests observed", "다른 앱의 유지 요청 관측 없음")
            : L("\(inspector.appRequests.count) app requests observed", "다른 앱의 유지 요청 \(inspector.appRequests.count)개 확인")
    }
    private var findingsDetail: String {
        if inspector.busy { return L("Rows from the previous check may remain visible.", "아래에는 이전 점검 결과가 보일 수 있습니다.") }
        if !inspector.assertionsAvailable { return L("Check again; unavailable evidence is not evidence of no requests.", "다시 점검하세요. 확인하지 못한 상태를 요청이 없는 상태로 판단하지 않습니다.") }
        if inspector.appRequests.contains(where: { $0.kinds.contains(.display) }) {
            return L("Review each app's screen-awake option below. A request alone does not prove failed display sleep.",
                     "아래 앱의 화면 유지 옵션을 확인하세요. 요청만으로 실제 화면 절전 실패를 확정하지 않습니다.")
        }
        if inspector.appRequests.contains(where: { $0.kinds == [.legacySystem] }) {
            return L("A legacy request is present. Its effect on this macOS is unconfirmed; review the app details.",
                     "이전 방식의 요청이 있습니다. 현재 macOS에서의 효과는 미확인이므로 앱별 상세를 확인하세요.")
        }
        return inspector.appRequests.isEmpty
            ? L("macOS idle settings and input can still affect sleep; open the details below if needed.", "macOS 대기 설정·입력도 절전에 영향을 줄 수 있습니다. 필요하면 아래 상세를 확인하세요.")
            : L("These requests do not require a lit display and can coexist with Tether.", "이 요청은 화면 켜짐을 요구하지 않으며 Tether의 화면 절전과 함께 사용할 수 있습니다.")
    }
    private var tetherPauseButton: some View {
        Button(model.workPaused ? L("Resume Tether", "Tether 다시 시작") : L("Pause Tether only", "Tether만 일시 중지")) {
            model.setEnabled(model.workPaused)
        }
        .actionButton()
        .accessibilityIdentifier("panel-pause-all")
        .help(model.workPaused
            ? L("Allow Tether work again. Enabled automatic rules can resume; ended manual work does not restart.", "Tether 작업을 다시 허용합니다. 켜 둔 자동 조건은 다시 적용하며, 끝난 수동 유지는 다시 시작하지 않습니다.")
            : L("End Tether's manual work and pause its automatic triggers. Other apps' requests remain.", "Tether 수동 유지와 자동 조건만 중지합니다. 다른 앱의 요청은 유지됩니다."))
        .accessibilityHint(L("Changes Tether only. Other apps' requests remain.", "Tether만 변경하며 다른 앱의 요청은 유지됩니다."))
        .disabled(!model.sessionAvailable || model.commandPending || (model.workPaused && !model.canResumeWork))
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentReadings).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisplaySleepNotice(model: model, showsReview: false)
            if model.showsLidOptions {
                WorkSessionRow(title: L("Tether closed-lid support", "Tether 덮개 유지"), value: model.lidSupportSummary)
                Text(L("Tether follows its power, duration and protection settings independently of remote apps.",
                       "Tether의 덮개 유지는 원격 앱과 무관하게 전원·시간·보호 설정에 따릅니다."))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            WorkSessionRow(title: L("System sleep block", "잠자기 차단"), value: globalOverrideSummary)
            VStack(alignment: .leading, spacing: 8) {
                if inspector.globalSleepDisabled == true && !model.clamshellActive {
                    Note(L("The global setting's writer cannot be identified reliably. An installed power app is not proof that it owns this setting.",
                           "전역 설정의 작성자는 정확히 구별할 수 없습니다. 설치된 전원 앱이 작성자라는 뜻은 아닙니다."))
                }
                if model.snapshot.power == .ac {
                    Note(L("Connected power does not always mean charging. Heavy work or a charge-management app can still drain the battery.",
                           "전원 연결과 실제 충전은 다릅니다. 큰 부하나 충전 관리 앱의 방전 기능으로 잔량이 줄 수도 있습니다."))
                }
                Note(L("Power, temperature and app requests are observations from different sources; a request alone does not establish failed sleep.",
                       "전원·발열·앱 요청은 각각 관측한 정보입니다. 요청이 있다는 사실만으로 잠자기 실패를 판단하지 않습니다."))
            }.padding(.top, 8)
        }
    }
    private var currentReadings: String {
        var values = [L("Power: \(model.powerValue)", "전원 \(model.powerValue)"),
            L("Thermal: \(model.observedThermalSummary)", "열 상태 \(model.observedThermalSummary)")]
        if model.hasInternalBattery { values.append(L("Battery: \(model.percentText)", "배터리 \(model.percentText)")) }
        return values.joined(separator: " · ")
    }
    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Observed app requests", "유지 요청이 확인된 앱"), systemImage: "moon.zzz")
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(inspector.appRequests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: request.opposesDisplaySleep ? "exclamationmark.circle.fill" : "app")
                            .foregroundStyle(request.opposesDisplaySleep ? Color.tetherWarning : Color.secondary)
                            .frame(width: 20).padding(.top, 2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.process).font(.callout.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(PowerRequestEffects.compactSummary(request)).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(request.opposesDisplaySleep ? Color.tetherWarning : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        appActions(request.pid, name: request.process)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup(L("Technical details", "기술 정보")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Note(PowerRequestEffects.optionToReview(request.kinds))
                                LabeledContent("PID", value: String(request.pid)).monospacedDigit()
                                    .textSelection(.enabled)
                                PowerRequestEffects(kinds: request.kinds)
                                ForEach(request.purposes.sorted { $0.rawValue < $1.rawValue }, id: \.self) { purpose in
                                    Note(purpose.summary)
                                }
                                ForEach(utilities(for: request)) { app in
                                    Text(app.bundleURL.path).font(.system(.subheadline, design: .monospaced))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(app.bundleID).foregroundStyle(.secondary).textSelection(.enabled)
                                    Note(app.adjustmentGuidance)
                                }
                                ForEach(request.overlapDescriptions, id: \.self) { Note($0) }
                                Note(request.guidance)
                                if !request.assertionTypes.isEmpty {
                                    Text(request.assertionTypes.joined(separator: "\n"))
                                        .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                Note(L("Setting names differ by app. The suggestions above come from observed request types, not a reading of this app's preferences.",
                                       "설정 이름은 앱마다 다릅니다. 위 안내는 관측한 요청 종류에 따른 것으로, 앱의 실제 설정을 읽은 결과는 아닙니다."))
                            }.padding(.top, 8)
                        }.font(.callout)
                        .accessibilityLabel(L("Technical details for \(request.process)", "\(request.process) 기술 정보"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, 30)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sleep-request-\(request.pid)")
                if request.id != inspector.appRequests.last?.id { Divider() }
            }
            DisclosureGroup(L("Coexistence and protection", "공존·보호의 범위")) {
                VStack(alignment: .leading, spacing: 8) {
                    Note(L("Tether does not release other apps' requests or end their work.",
                           "Tether는 다른 앱의 요청을 해제하거나 작업을 종료하지 않습니다."))
                    Note(L("Idle system sleep, display sleep and explicit Sleep have different effects. An observed request is not proof of active work or failed sleep.",
                           "일반 유휴 절전·화면 꺼짐·명시적인 잠자기는 서로 다릅니다. 요청 관측만으로 실제 작업 진행이나 잠자기 실패를 판단하지 않습니다."))
                    Note(L("Tether's power, duration and heat/battery limits still apply. System Sleep can interrupt other apps' work. If work must continue after unplugging, choose bounded battery work beforehand; save important work before a protection stop.",
                           "전원·시간·발열·배터리 제한은 계속 적용됩니다. Mac이 잠들면 다른 앱의 작업도 중단될 수 있습니다. 전원 분리 뒤에도 필요하면 미리 제한된 배터리 유지를 선택하고, 보호 중지에 대비해 중요한 작업을 저장하세요."))
                }.padding(.top, 8)
            }.font(.callout)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-influences-request-apps")
    }
    private var globalOverrideSummary: String {
        guard let blocked = inspector.globalSleepDisabled else { return L("Not confirmed", "확인되지 않음") }
        if !blocked { return L("Not observed", "차단 관측 없음") }
        return model.clamshellActive ? L("Tether's request is active", "Tether 요청 적용 중") : L("Active · writer unknown", "차단 중 · 작성자 미확인")
    }
    private func utilityImpact(_ app: PowerActivityInspector.InstalledUtility) -> String {
        guard app.assertionsAvailable, !app.requestKinds.isEmpty else {
            return PowerUtilityEvidence.summary(runningPID: app.runningPID, requestPIDs: app.requestPIDs,
                assertionsAvailable: app.assertionsAvailable, opposesDisplaySleep: app.opposesDisplaySleep)
        }
        return PowerRequestFinding(pid: app.runningPID ?? 0, process: app.name, kinds: app.requestKinds,
            opposesDisplaySleep: app.opposesDisplaySleep).summary
    }
    private func utilities(for request: PowerRequestFinding) -> [PowerActivityInspector.InstalledUtility] {
        inspector.installedUtilities.filter { $0.requestPIDs.contains(request.pid) || $0.runningPID == request.pid }
    }
    private var additionalUtilities: [PowerActivityInspector.InstalledUtility] {
        let requestPIDs = Set(inspector.appRequests.map(\.pid))
        return inspector.installedUtilities.filter { app in
            !app.requestPIDs.contains(where: requestPIDs.contains)
                && !(app.runningPID.map(requestPIDs.contains) ?? false)
        }
    }
    private var utilitiesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Note(L("Installation or a running process does not establish a conflict.",
                   "설치·실행만으로 충돌을 판단하지 않습니다."))
            if additionalUtilities.isEmpty {
                Note(inspector.busy ? L("Checking installed and running apps…", "설치·실행 앱을 확인하는 중…")
                    : L("No additional catalogued power apps found. Apps with observed requests appear above.", "추가로 확인된 전원 앱이 없습니다. 요청이 확인된 앱은 위 목록에 표시합니다."))
            }
            ForEach(additionalUtilities) { app in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "app").foregroundStyle(.secondary)
                            .frame(width: 20).padding(.top, 2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.callout.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(utilityImpact(app))
                                .font(.callout).foregroundStyle(app.opposesDisplaySleep ? Color.tetherWarning : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            Button(L("Open app", "앱 열기")) { inspector.openUtility(app) }
                                .disabled(!inspector.canOpenUtility(app))
                                .accessibilityLabel(L("Open \(app.name)", "\(app.name) 열기"))
                            Button(L("Show in Finder", "Finder에서 보기")) { inspector.revealUtility(app) }
                                .disabled(!inspector.canRevealUtility(app))
                                .accessibilityLabel(L("Show \(app.name) in Finder", "Finder에서 \(app.name) 보기"))
                        }.buttonStyle(.bordered).controlSize(.small).tint(.tetherControl)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup(L("Technical details", "기술 정보")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(PowerUtilityEvidence.summary(runningPID: app.runningPID, requestPIDs: app.requestPIDs,
                                    assertionsAvailable: app.assertionsAvailable, opposesDisplaySleep: app.opposesDisplaySleep))
                                    .font(.callout).foregroundStyle(.secondary)
                                if let pid = app.runningPID {
                                    LabeledContent("PID", value: String(pid)).monospacedDigit()
                                        .textSelection(.enabled)
                                }
                                if !app.requestKinds.isEmpty { PowerRequestEffects(kinds: app.requestKinds) }
                                Note(PowerUtilityEvidence.optionToReview(kinds: app.requestKinds,
                                    assertionsAvailable: app.assertionsAvailable))
                                ForEach(app.overlapDescriptions, id: \.self) { Note($0) }
                                Note(app.adjustmentGuidance)
                                Text(app.bundleURL.path).font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(app.bundleID).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.top, 8)
                        }.font(.callout)
                        .accessibilityLabel(L("Technical details for \(app.name)", "\(app.name) 기술 정보"))
                    }.padding(.leading, 30)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sleep-installed-\(app.bundleID)")
                if app.id != additionalUtilities.last?.id { Divider() }
            }
            Button(L("Activity Monitor…", "활동 모니터…")) { inspector.openActivityMonitor() }
                .buttonStyle(.bordered).controlSize(.small).tint(.tetherControl).disabled(inspector.simulated)
        }
    }
}
