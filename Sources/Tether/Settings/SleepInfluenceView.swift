import SwiftUI
import TetherCore

/// A read-only explanation. These observations never start or extend a work session.
struct SleepInfluenceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var inspector: PowerActivityInspector

    private var setting: PowerSleepPreferences.Setting? {
        inspector.sleepPreferences.setting(for: inspector.observedPower)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("macOS idle settings", "macOS 대기 설정"), systemImage: "gearshape")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(model.hasInternalBattery ? L("Battery settings…", "배터리 설정…")
                    : L("Lock Screen settings…", "잠금 화면 설정…")) {
                    model.open(model.hasInternalBattery ? .battery : .lockScreen)
                }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(inspector.simulated)
            }
            WorkSessionRow(title: L("Observed power", "점검한 전원"), value: inspector.observedPower == .ac
                ? L("Power adapter", "전원 연결") : inspector.observedPower == .battery ? L("Battery", "배터리") : L("Not confirmed", "미확인"))
            WorkSessionRow(title: L("Idle system sleep", "사용하지 않을 때 잠자기"), value: Self.timeout(setting?.systemMinutes))
            WorkSessionRow(title: L("Idle display sleep", "사용하지 않을 때 화면 끄기"), value: Self.timeout(setting?.displayMinutes))
            if inspector.observedPower != .unknown && inspector.observedPower != model.snapshot.power {
                Note(L("Power changed after this check. Check again for the current settings.", "점검 후 전원이 바뀌었습니다. 현재 설정은 다시 점검하세요."))
            }
            if setting?.systemMinutes == 0 {
                Note(L("macOS idle system sleep is disabled for this power source. Ending Tether alone need not put this Mac to sleep. Tether's configured closed-lid Sleep on unplug is a separate request.",
                       "이 전원에서는 macOS의 자동 유휴 잠자기가 꺼져 있습니다. Tether 유지를 끝내도 바로 잠들지는 않습니다. 닫힌 채 전원을 뺄 때의 잠자기 요청은 별도로 동작합니다."))
            }
            DisclosureGroup(L("Recent input and macOS requests", "최근 입력·macOS 유지 요청")) {
                VStack(alignment: .leading, spacing: 12) {
                    if let signals = inspector.activitySignals {
                        if signals.isEmpty {
                            Note(L("No user-activity or display-delay request was observed in this check.", "이번 점검에서는 사용자 활동·화면 지연 요청이 관측되지 않았습니다."))
                        }
                        ForEach(signals) { signal in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(signal.source ?? signal.process).font(.callout.weight(.medium))
                                Text(signal.summary).foregroundStyle(.secondary)
                                if signal.source != nil {
                                    Text(L("Input process reported by \(signal.process)", "\(signal.process)의 입력 프로세스 기록"))
                                        .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                                }
                                if let pid = signal.sourcePID, signal.source != nil, inspector.canOpen(pid) {
                                    Button(L("Open app", "앱 열기")) { inspector.open(pid) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Note(L("User activity could not be read. This does not mean there is no input.", "사용자 활동을 읽지 못했습니다. 입력이 없다는 뜻은 아닙니다."))
                    }
                    ForEach(inspector.systemRequests) { request in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.process).font(.callout.weight(.medium))
                            PowerRequestEffects(kinds: request.kinds)
                        }
                    }
                    if setting?.terminalKeepsAwake == true {
                        Note(L("macOS can postpone idle system sleep while a terminal is active. This setting alone does not establish an active terminal blocker.",
                               "macOS는 터미널 활동 중 유휴 잠자기를 늦출 수 있습니다. 이 설정만으로 터미널이 현재 절전을 막는다고 판단하지 않습니다."))
                    }
                    Note(L("Local, remote and automated input can restart display idle time. An activity request does not prove a remote connection. These observations do not extend Tether's time or closed-lid permission.",
                           "직접 입력·원격 입력·자동 입력은 화면 대기 시간을 갱신할 수 있습니다. 활동 요청만으로 원격 연결을 확정하지 않습니다. 이 정보는 Tether의 유지 시간이나 덮개 허가를 연장하지 않습니다."))
                    Note(L("Settings and requests are read only. Tether does not change them, cancel another app's work or identify who last changed a shared macOS setting.",
                           "설정과 요청은 읽기만 합니다. 다른 앱 작업을 취소하지 않으며, macOS 공유 설정을 마지막으로 바꾼 앱은 구별할 수 없습니다."))
                }.padding(.top, 8)
            }.font(.callout)
        }
    }

    static func timeout(_ minutes: Int?) -> String {
        guard let minutes else { return L("Not confirmed", "미확인") }
        return minutes == 0 ? L("Disabled", "사용 안 함") : L("\(minutes) min", "\(minutes)분")
    }
}
