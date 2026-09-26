import SwiftUI
import TetherCore

struct SafetyPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let summary = model.summary
        let advice = model.recommendations
        Page {
            Section {
                LabeledContent(L("Battery, lid closed", "덮개 닫힘 배터리 온도")) { Text(temperatureSummary(summary.closed)) }
                LabeledContent(L("Battery, lid open", "덮개 열림 배터리 온도")) { Text(temperatureSummary(summary.open)) }
                LabeledContent(L("Used during battery holds", "배터리 유지 중 사용량")) {
                    Text(summary.drainPerHour.map { L(String(format: "%.0f%% an hour", $0), String(format: "시간당 %.0f%%", $0)) }
                         ?? L("no data yet", "아직 기록 없음"))
                }
                LabeledContent(L("Used while asleep", "잠자는 동안 사용량")) {
                    Text(model.sleepLog.averageDrain.map {
                        L(String(format: "%.1f%% an hour · %@", $0, Texts.drainLevel($0)), String(format: "시간당 %.1f%% · %@", $0, Texts.drainLevel($0)))
                    } ?? L("no data yet", "아직 기록 없음"))
                }
                LabeledContent(L("Low Power Mode for heat", "발열로 저전력 모드")) {
                    Text(summary.heatGuards == 0 ? L("never needed", "켜진 적 없음")
                         : L("\(summary.heatGuards)× · peak heat with the lid closed: \(Texts.thermal(summary.closedMaxThermal))",
                             "\(summary.heatGuards)회 · 덮개 닫힘 최고 발열 \(Texts.thermal(summary.closedMaxThermal))"))
                }
                if !advice.isEmpty, model.recommendationsDiffer {
                    LabeledContent {
                        Button(L("Apply", "추천값 적용")) { model.applyRecommendations() }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    } label: {
                        Label(adviceSummary(advice, limits: !model.autoLimits), systemImage: "wand.and.stars")
                    }
                }
            } header: {
                Text(L("Measured on This Mac · Last 7 Days", "이 Mac에서 잰 값 · 최근 7일"))
            } footer: {
                Note(adviceNote(advice))
            }

            Section {
                Toggle(isOn: Binding(get: { model.autoLimits }, set: { model.setAutoLimits($0) })) {
                    InfoLabel(L("Adjust to this Mac", "이 Mac에 맞춰 자동 조정"), info: SettingsInfo.autoAdjust)
                    Text(L("Temperatures and the longest hold follow the measurements, never looser than the defaults",
                           "온도와 최대 시간을 측정값에 맞춰요. 기본값보다 느슨해지지 않아요"))
                }
                Picker(selection: limit(\.batteryFloor, SafetyPolicy.floor(model.limits), default: SafetyPolicy.batteryFloor)) {
                    ForEach(SafetyPolicy.floorChoices, id: \.self) { value in
                        Text(choice("\(value)%", isDefault: value == SafetyPolicy.batteryFloor, isRecommended: false)).tag(value)
                    }
                } label: {
                    InfoLabel(L("End at this much battery", "배터리가 이만큼 남으면 끝내기"), info: SettingsInfo.floor)
                }
                if model.autoLimits {
                    autoRows(advice)
                } else {
                    limitPickers(advice)
                }
            } header: {
                InfoLabel(L("Battery Hold", "배터리 유지"), info: SettingsInfo.batteryHold)
            } footer: {
                Note((model.autoLimits
                      ? L("Recommendations are applied by themselves and re-checked as measurements come in. Until there's enough data (about 30 minutes with the lid closed), the current values stay. ",
                          "추천값을 알아서 적용하고 기록이 쌓일 때마다 다시 맞춰요. 기록이 모이기 전(덮개를 닫고 약 30분)에는 지금 값을 써요. ")
                      : L("Limits can't be looser than the defaults. ", "기본값보다 느슨하게는 바꿀 수 없어요. "))
                     + L("With the lid closed it also ends after a minute at 3°C below the limit, or at “serious” heat. If the battery temperature can't be read, it ends at once.",
                         "덮개가 닫혀 있으면 이 온도보다 3°C 낮은 상태가 1분 이어지거나 발열이 '심각'이 돼도 끝내요. 배터리 온도를 읽지 못하면 바로 끝내요."))
            }

            Section {
                Toggle(L("During a battery hold", "배터리 유지 중"),
                       isOn: Binding(get: { model.holdLowPower }, set: { model.setHoldLowPower($0) }))
                Picker(selection: Binding(get: { model.heatLowPowerLevel }, set: { model.setHeatLowPowerLevel($0) })) {
                    Text(choice(L("From “serious” heat", "발열 '심각'부터"), isDefault: true,
                                isRecommended: advice.heatLevel?.value == 2)).tag(2)
                    Text(choice(L("From “fair” heat", "발열 '주의'부터"), isDefault: false,
                                isRecommended: advice.heatLevel?.value == 1)).tag(1)
                    Text(L("Never", "켜지 않음")).tag(0)
                } label: {
                    InfoLabel(L("On power, lid closed and hot", "전원 연결 중 덮개를 닫은 채 뜨거울 때"), info: SettingsInfo.heatLevel)
                }
            } header: {
                Text(L("Low Power Mode", "저전력 모드"))
            } footer: {
                Note(L("Tether turns Low Power Mode on only in these cases, for less heat and drain, and puts your setting back afterwards: on power after \(Int(ACThermalPolicy.coolDown / 60)) cool minutes. If you change Low Power Mode yourself meanwhile, it's left as you set it.",
                       "Tether는 이 두 경우에만 저전력 모드를 켜서 열과 배터리 소모를 줄이고, 끝나면 원래 설정으로 돌려요(전원 연결 중에는 \(Int(ACThermalPolicy.coolDown / 60))분 동안 식은 뒤). 그사이 직접 저전력 모드를 바꾸면 그대로 둬요."))
            }

            Section {
                LabeledContent(L("Put to sleep when overheating", "과열되면 잠재우기")) {
                    Text(L("always on", "항상 켜짐"))
                }
            } header: {
                Text(L("Safety Net · On Power, Lid Closed", "안전장치 · 전원 연결, 덮개 닫힘"))
            } footer: {
                Note(L("With no display attached, a closed Mac on power may be in a bag on a power bank. If heat stays “critical” for 2 minutes or the battery reaches \(Int(ACThermalPolicy.hotBattery))°C for a minute, it's put to sleep. With an external display attached it's left running.",
                       "모니터 없이 전원이 연결된 채 덮개가 닫혀 있으면 보조배터리를 꽂고 가방에 넣은 상태일 수 있어요. 발열 '위험'이 2분 이어지거나 배터리가 \(Int(ACThermalPolicy.hotBattery))°C로 1분 지나면 잠재워요. 외장 모니터가 있으면 그대로 둬요."))
            }

            Section {
                HStack {
                    if model.helperOutdated {
                        Label(L("Update the helper to apply these", "도우미를 업데이트해야 적용돼요"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(L("Restore Defaults", "기본값으로 되돌리기")) { model.resetSafety() }
                        .disabled(model.safetyIsDefault)
                }
            }
        }
    }

    /// The limits auto-adjust sets, read-only: the value in force, and whether it follows the data yet.
    @ViewBuilder
    private func autoRows(_ advice: Recommendations) -> some View {
        autoRow(L("Lid closed · end at once at", "덮개 닫힘 · 이 온도면 바로 끝내기"), info: SettingsInfo.closedLidLimit,
                "\(Int(model.safetyLimits(lidClosed: true).hardTemperature))°C", following: advice.closedLid != nil)
        autoRow(L("Lid open · end at once at", "덮개 열림 · 이 온도면 바로 끝내기"),
                "\(Int(model.safetyLimits(lidClosed: false).hardTemperature))°C", following: advice.openLid != nil)
        autoRow(L("Longest hold", "한 번에 최대"), L("\(model.maxHoldMinutes / 60) h", "\(model.maxHoldMinutes / 60)시간"),
                following: advice.maxHold != nil)
    }

    private func autoRow(_ title: String, info: String? = nil, _ value: String, following: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(following ? L("Auto", "자동") : L("Collecting data", "기록 모으는 중"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
            }
        } label: {
            if let info { InfoLabel(title, info: info) } else { Text(title) }
        }
    }

    @ViewBuilder
    private func limitPickers(_ advice: Recommendations) -> some View {
        Picker(selection: limit(\.closedLidMaxTemperature, model.safetyLimits(lidClosed: true).hardTemperature,
                                default: SafetyPolicy.closedLid.hardTemperature)) {
            ForEach(SafetyPolicy.closedLidChoices, id: \.self) { value in
                Text(choice("\(Int(value))°C", isDefault: value == SafetyPolicy.closedLid.hardTemperature,
                            isRecommended: value == advice.closedLid?.value)).tag(value)
            }
        } label: {
            InfoLabel(L("Lid closed · end at once at", "덮개 닫힘 · 이 온도면 바로 끝내기"), info: SettingsInfo.closedLidLimit)
        }
        Picker(L("Lid open · end at once at", "덮개 열림 · 이 온도면 바로 끝내기"),
               selection: limit(\.openLidMaxTemperature, model.safetyLimits(lidClosed: false).hardTemperature,
                                default: SafetyPolicy.openLid.hardTemperature)) {
            ForEach(SafetyPolicy.openLidChoices, id: \.self) { value in
                Text(choice("\(Int(value))°C", isDefault: value == SafetyPolicy.openLid.hardTemperature,
                            isRecommended: value == advice.openLid?.value)).tag(value)
            }
        }
        Picker(L("Longest hold", "한 번에 최대"), selection: limit(\.maxHoldHours, SafetyPolicy.maxHold(model.limits) / 3600,
                                                           default: SafetyPolicy.maxHold / 3600)) {
            ForEach(SafetyPolicy.maxHoldChoices, id: \.self) { hours in
                Text(choice(L("\(Int(hours)) h", "\(Int(hours))시간"), isDefault: hours == SafetyPolicy.maxHold / 3600,
                            isRecommended: hours == advice.maxHold?.value)).tag(hours)
            }
        }
    }

    /// `limits`: include the battery-hold limits, which auto-adjust otherwise applies by itself.
    private func adviceSummary(_ a: Recommendations, limits: Bool) -> String {
        var parts: [String] = []
        if limits, let v = a.closedLid?.value { parts.append(L("lid closed \(Int(v))°C", "덮개 닫힘 \(Int(v))°C")) }
        if limits, let v = a.openLid?.value { parts.append(L("lid open \(Int(v))°C", "덮개 열림 \(Int(v))°C")) }
        if limits, let v = a.maxHold?.value { parts.append(L("up to \(Int(v)) h", "최대 \(Int(v))시간")) }
        if let v = a.heatLevel?.value { parts.append(L("Low Power Mode from “\(Texts.thermal(v))”", "저전력 모드 '\(Texts.thermal(v))'부터")) }
        return L("Recommended: ", "추천: ") + parts.joined(separator: " · ")
    }

    private func adviceNote(_ a: Recommendations) -> String {
        let reasons = [a.closedLid?.reason, a.openLid?.reason, a.maxHold?.reason, a.heatLevel?.reason].compactMap { $0 }
        guard !reasons.isEmpty else {
            return L("The helper records battery temperature and heat every 30 seconds. After about 30 minutes with the lid closed, recommendations for this Mac appear here.",
                     "도우미가 30초마다 배터리 온도와 발열을 기록해요. 덮개를 닫고 30분쯤 쓰면 이 Mac에 맞는 추천값을 보여 줘요.")
        }
        return reasons.joined(separator: " · ")
            + L(". Recommendations sit 4°C above the usual peak: ordinary use never trips them, a bag soon does.",
                ". 추천은 평소 최고 온도보다 4°C 위로 잡아서, 평소에는 멈추지 않고 가방 안처럼 뜨거워지면 일찍 멈추게 해요.")
    }

    /// A picker binding for one user limit: shows the value in force, stores nil for the default.
    private func limit<V: Equatable>(_ key: WritableKeyPath<UserLimits, V?>, _ current: V, default standard: V) -> Binding<V> {
        Binding(get: { current }, set: { value in
            var limits = model.limits
            limits[keyPath: key] = value == standard ? nil : value
            model.setLimits(limits)
        })
    }
}
