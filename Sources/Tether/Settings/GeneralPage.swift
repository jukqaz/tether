import SwiftUI
import TetherCore

/// The global display/lid permissions live here. Automatic acquisition belongs
/// to the Automatic start tab; these switches never start a session on their own.
struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var workRulesExpanded = false
    @State private var protectionExpanded = false
    @State private var closedLidDisplayExpanded = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
            }
            if let reason = model.workProtectionReason {
                WorkSessionNote(title: L("Stopped for protection", "보호를 위해 중지했어요"),
                    detail: protectionReason(reason), symbol: "exclamationmark.circle", color: .tetherWarning)
                if model.canResumeWork {
                    Button(L("Allow again", "다시 허용")) { model.setEnabled(true) }
                        .actionButton(prominent: true).disabled(model.commandPending)
                        .accessibilityIdentifier("settings-protection-resume")
                } else {
                    Note(L("Checking that it is safe to start again. Ended timers do not return.",
                           "다시 시작해도 되는지 확인하고 있어요. 끝난 타이머는 돌아오지 않습니다."))
                }
            }
            SettingsContentGroup(L("What to keep awake", "잠들지 않게 할 항목")) {
                SettingRow(title: L("Automatic start", "자동 시작")) {
                    Button(L("Configure in Automatic start…", "자동 시작에서 설정…")) {
                        model.settingsPage = .safety
                    }.buttonStyle(.link)
                        .accessibilityIdentifier("settings-go-to-automatic")
                }
                if model.showsLidOptions {
                    SettingsToggle(title: L("Continue with the lid closed", "덮개를 닫아도 계속 사용"),
                        isOn: lidBinding)
                        .disabled(lidControlDisabled)
                        .accessibilityIdentifier("closed-lid-allow-toggle")
                    if model.v3Settings.allowClosedLid {
                        closedLidDisplayControls
                    } else {
                        SettingsDisclosure(title: L("Saved built-in display choice", "저장된 내장 화면 선택"),
                            summary: closedLidDisplayTitle, isExpanded: closedLidDisplayExpansion) {
                            closedLidDisplayControls
                        }.accessibilityIdentifier("settings-closed-lid-display-details")
                    }
                    if let status = model.closedLidDisplayStatusText {
                        Note(status).accessibilityIdentifier("settings-closed-lid-display-status")
                    }
                    if model.closedLidDisplayRecoveryPending {
                        Button(L("Retry brightness restoration", "밝기 복구 다시 시도")) {
                            model.retryClosedLidDisplayRecovery()
                        }.actionButton().accessibilityIdentifier("settings-retry-brightness-restoration")
                    }
                    if !model.helperSetupConfirmed {
                        Button(L("Prepare the closed-lid helper…", "덮개 유지 도우미 준비…")) {
                            model.settingsPage = .system
                        }.buttonStyle(.link)
                            .accessibilityIdentifier("settings-prepare-lid-helper")
                    }
                }
                SettingsToggle(title: L("Keep the display awake during work", "덮개가 열려 있을 때 화면 켜두기"),
                    isOn: Binding(get: { model.v3Settings.keepDisplayAwake }, set: { model.setKeepDisplayAwake($0) }))
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("keep-display-awake-toggle")
                Note(L("Display and lid choices apply to current and future work. They do not start work by themselves.",
                       "화면·덮개 선택은 현재와 다음 유지에 적용됩니다. 이 옵션만으로 새 유지를 시작하지 않습니다."))
                Note(L("Keep-awake does not prevent every lock. Closing the lid and password requirements still follow macOS.",
                       "잠자기 방지가 모든 잠금을 막지는 않습니다. 덮개를 닫을 때의 잠금과 암호 요구는 macOS 설정을 따릅니다."))
                    .accessibilityIdentifier("settings-lock-policy-note")
                Button(L("Lock Screen settings…", "macOS 잠금 화면 설정…")) { model.open(.lockScreen) }
                    .buttonStyle(.link)
                    .disabled(model.userCommandsArePreview || model.developmentService)
                if let error = model.userSessionStatus?.displayError { Note(error, color: .tetherWarning) }
            }

            SettingsContentGroup(L("Power and duration", "전원과 사용 시간")) {
                SettingRow(title: L("When power is unplugged", "전원을 뺐을 때")) {
                    Picker(L("Unplug policy", "전원 분리 규칙"), selection: Binding(
                        get: { model.v3Settings.disconnectPolicy }, set: { model.setDisconnectPolicy($0) })) {
                        Text(L("End all · Recommended", "모두 끝내기 · 권장")).tag(WorkSessionDisconnectPolicy.endAll)
                        Text(L("End automatic only", "자동 유지 끝내기")).tag(WorkSessionDisconnectPolicy.endAutomatic)
                        Text(L("Continue eligible work", "허용된 유지 계속")).tag(WorkSessionDisconnectPolicy.continueEligible)
                    }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                }.accessibilityIdentifier("settings-unplug-policy")
                Note(model.disconnectPolicyDetail)
                if model.hasInternalBattery {
                    SettingRow(title: L("Manual work power range", "수동 유지 전원 범위")) {
                        Picker(L("Manual work power range", "수동 유지 전원 범위"), selection: Binding(
                            get: { model.v3Settings.manualPowerCondition }, set: { model.setManualPowerCondition($0) })) {
                            ForEach(PowerCondition.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                    }.accessibilityIdentifier("settings-manual-power-condition")
                    Note(L("The manual power range is captured when work starts. The unplug policy may still end it.",
                           "수동 전원 범위는 시작할 때 적용됩니다. 전원 분리 종료 규칙도 함께 따릅니다."))
                }
                if model.showsLidOptions && model.v3Settings.allowClosedLid {
                    SettingRow(title: L("With the lid closed", "덮개가 닫혀 있다면"), showsAccessibleTitle: false) {
                        Picker(L("Unplugged with lid closed", "닫힌 채 전원 분리"), selection: Binding(
                            get: { model.v3Settings.disconnectAction }, set: { model.setDisconnectAction($0) })) {
                            Text(L("Request sleep · Recommended", "잠자기 요청 · 권장")).tag(WorkSessionEndAction.sleepIfClosed)
                            Text(L("Follow macOS", "macOS에 맡김")).tag(WorkSessionEndAction.followOS)
                        }.labelsHidden().pickerStyle(.menu)
                            .disabled(settingsControlsDisabled)
                            .accessibilityIdentifier("closed-lid-disconnect-picker")
                    }
                }
                if model.hasInternalBattery {
                    SettingRow(title: L("Maximum on battery", "배터리에서 최대")) {
                        Picker(L("Battery time limit", "배터리 시간 한도"), selection: Binding(
                            get: { model.v3Settings.batteryTimeLimit }, set: { model.setBatteryTimeLimit($0) })) {
                            ForEach(WorkSessionBatteryLimit.allCases, id: \.self) { value in
                                Text(model.batteryLimitTitle(value)).tag(value)
                            }
                        }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                    }.accessibilityIdentifier("settings-battery-manual-limit")
                    Note(L("Each request keeps the limit selected when it starts. Its clock begins at first battery use; reconnecting power does not reset it or extend the timer.",
                           "한도는 유지 시작 때 정하고, 기준 시각은 처음 배터리로 사용할 때 정합니다. 전원 연결로 한도나 타이머가 초기화되지 않습니다."))
                }
            }

            SettingsDisclosure(title: L("Device protection", "기기 보호"),
                summary: protectionSummary, isExpanded: protectionExpansion) {
                ProtectionSettingsContent(model: model)
            }.accessibilityIdentifier("settings-protection-rules-details")

            SettingsDisclosure(title: L("After work ends", "끝난 뒤 동작·다시 시작"),
                summary: model.v3Settings.automaticallyResumeAfterProtection
                    ? L("Automatic rules after recovery", "안전 회복 후 자동 조건 적용")
                    : L("Manual restart after protection", "보호 후 직접 다시 시작"), isExpanded: workRulesExpansion) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsToggle(title: L("Resume automatic rules after protection", "보호 회복 후 자동 조건 다시 적용"),
                        isOn: Binding(get: { model.v3Settings.automaticallyResumeAfterProtection },
                                      set: { model.setAutomaticallyResumeAfterProtection($0) }))
                        .disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("settings-protection-auto-resume")
                    Note(L("Requires 60 seconds of fresh safe observations. Ended timers and task requests never return; Stop all stays stopped.",
                           "안전한 새 관측이 60초 동안 이어져야 합니다. 끝난 타이머·작업 요청은 복원하지 않으며 모두 중지는 유지됩니다."))
                    SettingsToggle(title: L("Stop in Low Power Mode", "저전력 모드가 되면 멈추기"),
                        isOn: Binding(get: { model.v4Settings.stopOnLowPowerMode }, set: { model.setV4StopOnLowPowerMode($0) }))
                        .disabled(settingsControlsDisabled)
                    Note(L("End timer: automatic work may continue. Automatic start off: manual work may continue.",
                           "타이머 종료: 자동 유지는 계속될 수 있습니다. 자동 시작 끄기: 수동 유지는 계속됩니다."))
                    Note(L("Stop all ends the timer and pauses automatic starts. Resume allows automatic starts again; it never restores an ended timer.",
                           "모두 중지: 타이머를 끝내고 자동 시작을 멈춥니다. 다시 허용: 자동 시작만 허용하며 끝난 타이머는 복원하지 않습니다."))
                    if model.hasInternalBattery {
                        Note(L("Connecting power during battery work does not extend its original deadline.",
                               "배터리 유지 중 전원을 연결해도 원래 종료 시각은 늘어나지 않습니다."))
                    }
                    Note(L("Sleep is a request. Other apps or macOS may keep the Mac awake. Tether never unlocks a locked Mac.",
                           "잠자기는 요청입니다. 다른 앱이나 macOS가 잠들지 않게 할 수 있으며, 이미 잠긴 Mac은 해제하지 않습니다."))
                }
            }.accessibilityIdentifier("settings-work-rules-details")
        }
        .alert(L("Current manual session", "현재 수동 유지"), isPresented: $model.reviewingManualDeadline) {
            Button(L("Close", "닫기"), role: .cancel) {}
        } message: {
            if model.manualSessionActive, let until = model.manualSessionUntil {
                Text(L("Ends at \(Texts.time(until)). You can extend or end it from the menu.",
                       "\(Texts.time(until))에 끝납니다. 메뉴에서 연장하거나 끝낼 수 있습니다."))
            } else if model.manualSessionActive {
                Text(L("No time limit while connected to power. Unplugging ends this session.",
                       "전원이 연결되어 있는 동안 시간 제한이 없습니다. 전원을 빼면 끝납니다."))
            } else {
                Text(L("This manual session has ended.", "이 수동 유지는 끝났습니다."))
            }
        }
    }

    private var closedLidDisplayControls: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("With the lid closed, built-in display", "덮개를 닫으면 내장 화면을"),
                       showsAccessibleTitle: false) {
                Picker(L("Built-in display with the lid closed", "덮개를 닫으면 내장 화면을"), selection: Binding(
                    get: { model.v3Settings.closedLidDisplayMode },
                    set: { model.setClosedLidDisplayMode($0) })) {
                    Text(L("Turn display off", "화면 끄기")).tag(ClosedLidDisplayMode.off)
                    Text(L("Set brightness to zero", "밝기 0으로 낮추기")).tag(ClosedLidDisplayMode.zeroBrightness)
                        .disabled(!model.canUseZeroBrightness)
                    Text(L("Do not change", "변경하지 않기")).tag(ClosedLidDisplayMode.unchanged)
                }.labelsHidden().pickerStyle(.menu)
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("settings-closed-lid-display-mode")
            }
            Note(closedLidDisplayExplanation)
            if let reason = model.closedLidDisplayAvailabilityReason {
                Note(reason).accessibilityIdentifier("settings-closed-lid-display-availability")
            }
        }
    }

    private var closedLidDisplayTitle: String {
        switch model.v3Settings.closedLidDisplayMode {
        case .off: L("Turn display off", "화면 끄기")
        case .zeroBrightness: L("Set brightness to zero", "밝기 0으로 낮추기")
        case .unchanged: L("Do not change", "변경하지 않기")
        }
    }

    private var closedLidDisplayExplanation: String {
        switch model.v3Settings.closedLidDisplayMode {
        case .off:
            L("Requests built-in display sleep. This does not measure panel power.",
              "내장 화면의 절전 처리를 요청합니다. 패널 전력을 측정한 결과는 아닙니다.")
        case .zeroBrightness:
            L("Lowers brightness only. It does not confirm display sleep, unlocking or a working remote connection.",
              "밝기만 낮춥니다. 화면 꺼짐·잠금 해제·원격 연결 성공을 뜻하지 않습니다.")
        case .unchanged:
            L("Tether does not change built-in display settings. macOS and other apps still apply their settings.",
              "Tether가 내장 화면 설정을 바꾸지 않습니다. macOS와 다른 앱의 설정은 계속 적용됩니다.")
        }
    }

    private var closedLidDisplayExpansion: Binding<Bool> {
        disclosures?.closedLidDisplay ?? $closedLidDisplayExpanded
    }

    var lidAvailability: LidOptionAvailability { LidOptionAvailability(model: model) }
    var lidControlDisabled: Bool { lidAvailability.isDisabled }
    var lidBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.allowClosedLid }, set: { value in
            guard lidAvailability.permits(value) else { return }
            model.setAllowClosedLid(value)
        })
    }
    private var settingsControlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    private var workRulesExpansion: Binding<Bool> { disclosures?.workRules ?? $workRulesExpanded }
    private var protectionExpansion: Binding<Bool> { disclosures?.protectionRules ?? $protectionExpanded }
    private var protectionSummary: String {
        model.workProtectionReason != nil ? L("Stopped for protection", "보호로 멈춤")
            : model.hasInternalBattery ? L("Thermal state · \(model.batteryFloor)% reserve", "열 상태 · 잔량 \(model.batteryFloor)%")
            : L("Thermal protection on", "열 보호 켬")
    }
}

/// Content only: protection stays within the page's one scroll viewport.
struct ProtectionSettingsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("Thermal protection", "열 보호")) {
                Text(L("Critical is always on", "위험 단계는 항상 켬")).foregroundStyle(Color.tetherSecondary)
            }
            SettingsToggle(title: L("Also stop at serious thermal pressure", "심각한 열 상태에서도 중지"),
                isOn: Binding(get: { model.v3Settings.stopOnSeriousThermal }, set: { model.setStopOnSeriousThermal($0) }))
                .disabled(model.commandPending || !model.acceptingUserCommands)
            SettingRow(title: L("Current thermal state", "현재 열 상태")) {
                Text(model.observedThermalSummary).foregroundStyle(thermalColor)
            }
            if model.hasInternalBattery {
                SettingRow(title: L("Stop below battery level", "배터리가 이보다 낮으면 끝내기"), showsAccessibleTitle: false) {
                    Picker(L("Stop below", "잔량 하한"), selection: Binding(
                        get: { model.batteryFloor }, set: { value in
                            var limits = model.limits; limits.batteryFloor = value; model.setLimits(limits)
                        })) {
                        ForEach(Array(Set(SafetyPolicy.floorChoices + [model.batteryFloor])).sorted(), id: \.self) {
                            Text("\($0)%").tag($0)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                        .disabled(model.commandPending || !model.acceptingUserCommands)
                }.accessibilityIdentifier("settings-battery-protection-floor")
            }
            Note(L("Critical macOS thermal pressure always ends work; serious pressure follows your option. This is not a Celsius reading. Notifications never disable protection.",
                   "macOS 열 상태가 위험이면 항상 유지를 끝내며 심각 단계는 선택을 따릅니다. 섭씨 온도 측정값이 아닙니다. 알림을 꺼도 보호는 계속 동작합니다."))
            if let error = model.errorText { Note(error, color: .tetherError) }
        }
    }

    private var thermalColor: Color {
        switch model.userSessionStatus?.thermal ?? model.status?.thermal {
        case 1, 2: .tetherWarning
        case 3: .tetherError
        case 0: .tetherPrimary
        default: .tetherSecondary
        }
    }
}
