import SwiftUI
import TetherCore

/// The global display/lid permissions live here. Automatic acquisition belongs
/// to Power & automation; these switches never start a session on their own.
struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var manualBatteryExpanded = false
    @State private var workRulesExpanded = false
    @State private var protectionExpanded = false
    @State private var closedLidDisplayExpanded = false
    @State private var showManualDefaults = false

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
            SettingsContentGroup(L("Allowed work features", "유지 기능 허용")) {
                if model.showsLidOptions {
                    SettingsToggle(title: L("Allow closed-lid work", "덮개 유지 허용"),
                        isOn: lidBinding)
                        .disabled(lidControlDisabled)
                        .accessibilityIdentifier("closed-lid-allow-toggle")
                }
                SettingsToggle(title: L("Allow display keep-awake", "화면 켜두기 허용"),
                    isOn: Binding(get: { model.v3Settings.keepDisplayAwake }, set: { model.setKeepDisplayAwake($0) }))
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("keep-display-awake-toggle")
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    Note(L("These app-wide permissions apply only to features requested by the work. Turning them on does not start work.",
                           "작업에서 요청한 기능만 허용합니다. 허용을 켜도 새 작업이 시작되지는 않습니다."))
                        .accessibilityIdentifier("settings-global-permission-scope")
                    if model.showsLidOptions {
                        if model.v3Settings.allowClosedLid {
                            closedLidDisplayControls
                        } else {
                            SettingsDisclosure(title: L("Saved built-in display choice", "저장된 내장 화면 선택"),
                                summary: closedLidDisplayTitle, isExpanded: closedLidDisplayExpansion, groupsSection: false) {
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
                    Note(L("Locking and password requirements still follow macOS. Tether does not unlock the Mac.",
                           "잠금·암호 요구는 macOS 설정을 따릅니다. Tether가 잠금을 해제하지는 않습니다."))
                        .accessibilityIdentifier("settings-lock-policy-note")
                    Button(L("Lock Screen settings…", "macOS 잠금 화면 설정…")) { model.open(.lockScreen) }
                        .buttonStyle(.link)
                        .disabled(model.userCommandsArePreview || model.developmentService)
                    if let error = model.userSessionStatus?.displayError { Note(error, color: .tetherWarning) }
                }

            }

            SettingsContentGroup(L("Manual work defaults", "다음 수동 작업 기본값")) {
                SettingRow(title: model.showsLidOptions ? L("Display, lid and idle", "화면·덮개·유휴")
                    : L("Display and idle", "화면·유휴"),
                    detail: L("New manual work only; current work is unchanged", "새 수동 작업에만 적용 · 현재 작업은 그대로")) {
                    Button(L("Edit…", "편집…")) { showManualDefaults = true }
                        .buttonStyle(.link)
                        .accessibilityLabel(L("Edit next manual work defaults", "다음 수동 작업 기본값 편집"))
                        .accessibilityIdentifier("settings-open-manual-defaults")
                        .disabled(settingsControlsDisabled)
                }
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    SettingRow(title: L("Start duration", "직접 시작 시간")) {
                        Text(model.selectedManualMinutes == 0 ? L("Until turned off", "끄기 전까지")
                            : model.durationChoiceTitle(model.selectedManualMinutes))
                            .foregroundStyle(Color.tetherSecondary)
                    }.accessibilityIdentifier("settings-manual-duration-summary")
                    Note(L("Choose a duration and start from the menu.", "시간 선택과 직접 시작은 메뉴에서 합니다."))
                }

                if model.hasInternalBattery {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        SettingRow(title: L("Maximum on battery", "배터리에서 최대")) {
                            Picker(L("Battery time limit", "배터리 시간 한도"), selection: Binding(
                                get: { model.v3Settings.batteryTimeLimit }, set: { model.setBatteryTimeLimit($0) })) {
                                ForEach(WorkSessionBatteryLimit.allCases, id: \.self) { value in
                                    Text(model.batteryLimitTitle(value)).tag(value)
                                }
                            }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                        }.accessibilityIdentifier("settings-battery-manual-limit")
                        Note(L("The limit is captured at start and counts from first battery use. Reconnecting power does not reset it or extend the timer.",
                               "시작할 때 정한 한도를 첫 배터리 사용부터 계산합니다. 전원을 다시 연결해도 한도·타이머는 늘어나지 않습니다."))
                    }

                }
            }

            SettingRow(title: L("Power and automatic start", "전원과 자동 시작")) {
                Button(L("Power & automation…", "전원·자동화에서 설정…")) {
                    model.settingsPage = .safety
                }.buttonStyle(.link)
                    .accessibilityIdentifier("settings-go-to-automatic")
            }

            if model.hasInternalBattery {
                SettingsDisclosure(title: L("Manual power range", "수동 유지 전원 범위"),
                    summary: model.v3Settings.manualPowerCondition.title, isExpanded: manualBatteryExpansion) {
                    SettingRow(title: L("New manual work may use", "새 수동 유지에 허용할 전원")) {
                        Picker(L("Manual work power range", "수동 유지 전원 범위"), selection: Binding(
                            get: { model.v3Settings.manualPowerCondition }, set: { model.setManualPowerCondition($0) })) {
                            ForEach(PowerCondition.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                    }.accessibilityIdentifier("settings-manual-power-condition")
                    Note(L("Captured when work starts. The unplug policy on Power & automation still applies.",
                           "시작할 때 적용됩니다. 전원·자동화 탭의 전원 분리 규칙도 함께 따릅니다."))
                }.accessibilityIdentifier("settings-manual-battery-details")
            }

            SettingsDisclosure(title: L("Device protection", "기기 보호"),
                summary: protectionSummary, isExpanded: protectionExpansion) {
                ProtectionSettingsContent(model: model)
            }.accessibilityIdentifier("settings-protection-rules-details")

            SettingsDisclosure(title: L("After protection stops work", "보호로 멈춘 뒤"),
                summary: model.v3Settings.automaticallyResumeAfterProtection
                    ? L("Automatic rules after recovery", "안전 회복 후 자동 조건 적용")
                    : L("Manual restart after protection", "보호 후 직접 다시 시작"), isExpanded: workRulesExpansion) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsToggle(title: L("Resume automatic rules after protection", "보호 회복 후 자동 조건 다시 적용"),
                        isOn: Binding(get: { model.v3Settings.automaticallyResumeAfterProtection },
                                      set: { model.setAutomaticallyResumeAfterProtection($0) }))
                        .disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("settings-protection-auto-resume")
                    Note(L("Automatic rules may resume after 60 seconds of safe observations. Ended timers stay ended; Stop all stays stopped.",
                           "안전한 상태가 60초 이어지면 자동 조건을 다시 확인합니다. 끝난 타이머와 모두 중지는 복원하지 않습니다."))
                    Note(L("Ending a timer or turning off automatic start affects only that work. Stop all ends both; resuming never restores an ended timer.",
                           "타이머 종료·자동 시작 끄기는 각각에만 적용됩니다. 모두 중지는 둘 다 끝내며, 다시 허용해도 끝난 타이머는 돌아오지 않습니다."))
                }
            }.accessibilityIdentifier("settings-work-rules-details")
        }
        .sheet(isPresented: $showManualDefaults) { ManualDefaultsOptionsView(model: model) }
        .alert(L("Current manual session", "현재 수동 유지"), isPresented: $model.reviewingManualDeadline) {
            Button(L("Close", "닫기"), role: .cancel) {}
        } message: {
            if model.manualSessionActive, let until = model.manualSessionUntil {
                Text(L("Ends at \(Texts.time(until)). You can extend or end it from the menu.",
                       "\(Texts.time(until))에 끝납니다. 메뉴에서 연장하거나 끝낼 수 있습니다."))
            } else if model.manualSessionActive {
                Text(ManualSessionControls(model: model, clock: model.clock).hasConfirmedUnlimitedDuration
                    ? L("This request has no timer deadline. Its original power, battery and protection limits still apply.",
                        "이 요청에는 타이머 마감이 없습니다. 시작할 때의 전원·배터리·보호 한도는 계속 적용됩니다.")
                    : L("The timer deadline is being confirmed. Review the current power and protection state.",
                        "타이머 마감을 확인 중입니다. 현재 전원·보호 상태를 확인하세요."))
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
    private var manualBatteryExpansion: Binding<Bool> { disclosures?.manualBattery ?? $manualBatteryExpanded }
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
            SettingsToggle(title: L("Stop in Low Power Mode", "저전력 모드가 되면 멈추기"),
                isOn: Binding(get: { model.v4Settings.stopOnLowPowerMode }, set: { model.setV4StopOnLowPowerMode($0) }))
                .disabled(model.commandPending || !model.acceptingUserCommands)
                .accessibilityIdentifier("settings-low-power-stop")
            Note(L("Thermal state comes from macOS, not a Celsius reading. Critical always stops work; turning off notifications never disables protection.",
                   "열 상태는 macOS 기준이며 섭씨 온도가 아닙니다. 위험 단계는 항상 중지하고, 알림을 꺼도 보호는 계속됩니다."))
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
