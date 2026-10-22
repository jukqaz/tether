import SwiftUI
import TetherCore

struct PowerRequestEffects: View {
    let kinds: Set<SleepBlocker.Kind>
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(kinds.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                Text(Self.effect(kind)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    static func effect(_ kind: SleepBlocker.Kind) -> String {
        switch kind {
        case .system:
            L("Idle system sleep: prevented. This request does not keep the display awake. Does not guarantee work through lid-close or explicit Sleep.",
              "일반 유휴 절전을 막습니다. 이 요청 자체는 화면 켜짐을 요구하지 않습니다. 덮개 수면·명시적인 잠자기까지 막는다는 뜻은 아닙니다.")
        case .display:
            L("Idle display sleep: prevented. The lit display can also keep the system awake.",
              "유휴 화면 꺼짐을 막습니다. 켜진 화면 때문에 시스템도 계속 깨어 있을 수 있습니다.")
        case .network:
            L("Network activity requests system wakefulness without requesting a lit display. Its effect on full system Sleep is not confirmed here.",
              "네트워크 작업을 위해 시스템 활동을 요청하며 화면 켜짐은 요구하지 않습니다. 실제 시스템 수면에 미치는 결과는 별도 확인이 필요합니다.")
        case .legacySystem:
            L("Deprecated system-sleep request. Its effect on this macOS version is not confirmed.",
              "이전 방식의 시스템 잠자기 요청입니다. 현재 macOS에서의 효과는 확인되지 않았습니다.")
        }
    }
    /// Describes observed requests rather than claiming completed sleep or a live app preference.
    static func compactSummary(_ request: PowerRequestFinding) -> String {
        var effects: [String] = []
        if request.kinds.contains(.display) {
            effects.append(request.opposesDisplaySleep
                ? L("May oppose display sleep", "화면 끄기와 충돌 가능")
                : L("Display-awake request", "화면 유지 요청"))
        }
        if request.kinds.contains(.system) { effects.append(L("Prevents idle system sleep", "유휴 잠자기 방지")) }
        if request.kinds.contains(.network) { effects.append(L("Network-work request", "네트워크 활동 요청")) }
        if request.kinds.contains(.legacySystem) { effects.append(L("Legacy request · effect unconfirmed", "이전 요청 · 영향 미확인")) }
        return effects.isEmpty ? request.summary : effects.joined(separator: " · ")
    }
    static func optionToReview(_ kinds: Set<SleepBlocker.Kind>) -> String {
        if kinds.contains(.display) {
            return L("To turn the screen off, check for a screen-awake option in this app.",
                     "화면을 끄려면 앱에 화면 유지 옵션이 있는지 확인하세요.")
        }
        if kinds.contains(.system) || kinds.contains(.network) {
            return L("To change this behavior, check for a background-work option in this app.",
                     "유지 방식을 바꾸려면 앱에 작업 유지 옵션이 있는지 확인하세요.")
        }
        return L("The current effect is unconfirmed. Review the app's sleep settings.",
                 "현재 영향은 미확인입니다. 앱의 절전 설정을 확인하세요.")
    }
}

enum PowerUtilityEvidence {
    static func summary(runningPID: Int32?, requestPIDs: [Int32], assertionsAvailable: Bool,
                        opposesDisplaySleep: Bool) -> String {
        if !assertionsAvailable {
            return runningPID == nil ? L("Installed · requests unavailable", "설치됨 · 요청 확인 불가")
                : L("Running · requests unavailable", "실행 중 · 요청 확인 불가")
        }
        if !requestPIDs.isEmpty {
            return opposesDisplaySleep ? L("Request observed · opposes display sleep", "요청 관측 · 화면 꺼짐과 충돌 가능")
                : L("Request observed · review its effects below", "요청 관측 · 아래 영향 확인")
        }
        return runningPID == nil ? L("Installed only · no request observed", "설치만 확인 · 요청 관측 없음")
            : L("Running · no request observed", "실행 중 · 요청 관측 없음")
    }
    static func optionToReview(kinds: Set<SleepBlocker.Kind>, assertionsAvailable: Bool) -> String {
        guard assertionsAvailable else {
            return L("Requests are unavailable. Review settings inside the app.",
                     "요청은 미확인입니다. 설정은 앱에서 직접 확인하세요.")
        }
        guard !kinds.isEmpty else {
            return L("Open the app to review its settings if needed.",
                     "필요하면 앱을 열어 설정을 확인하세요.")
        }
        return PowerRequestEffects.optionToReview(kinds)
    }
}

struct PowerObservationFreshness: View {
    let checkedAt: Date?
    let refreshing: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(Self.summary(checkedAt: checkedAt, now: context.date, refreshing: refreshing))
                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    static func summary(checkedAt: Date?, now: Date, refreshing: Bool) -> String {
        if refreshing { return L("Refreshing. Rows from the previous check may still be visible.", "다시 확인 중 · 이전 점검 결과가 보일 수 있습니다.") }
        guard let checkedAt else { return L("Not checked yet.", "아직 점검하지 않았습니다.") }
        let age = now.timeIntervalSince(checkedAt)
        guard age.isFinite, age >= 0 else { return L("Observation time not confirmed. Check again.", "관측 시각 미확인 · 다시 점검하세요.") }
        if age >= 45 {
            return L("Previous observation · \(Int(age)) seconds old. Check again before acting.",
                     "이전 점검 · \(Int(age))초 전 · 조정 전에 다시 점검하세요.")
        }
        return L("Observed \(Int(age)) seconds ago. Requests can change after this check.",
                 "\(Int(age))초 전 점검 · 요청은 달라질 수 있습니다.")
    }
}

struct SystemFeatureOverlapView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemSettingsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L("Background work", "작업 유지"),
                value: L("Other idle-sleep requests can coexist", "다른 앱의 일반 유지와 공존 가능"))
            LabeledContent(L("Display sleep", "화면 꺼짐"),
                value: model.v3Settings.keepDisplayAwake
                    ? L("Display keeping selected", "화면 유지 선택됨")
                    : L("Display keeping off", "화면 유지 선택 꺼짐"))
            LabeledContent(L("Tether display request", "Tether 화면 요청"), value: displayRequestStatus)
            if let error = model.userSessionStatus?.displayError {
                Note(L("Display request error: \(error)", "화면 요청 오류: \(error)"))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("Password after display sleep", "화면 꺼짐 후 암호 요구"), systemImage: "lock")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(L("Lock Screen settings…", "잠금 화면 설정…")) { model.open(.lockScreen) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel(L("Open Lock Screen settings", "화면 잠금 설정 열기"))
                        .disabled(model.userCommandsArePreview || model.developmentService)
                }
                Text(model.screenLockSettingTitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(L("Coexistence details", "공존·제한 상세")) {
                VStack(alignment: .leading, spacing: 10) {
                    overlapDetail(L("Work requests", "작업 유지"),
                        L("Ending Tether does not end other apps' idle-sleep requests. Overlap alone is not a conflict.",
                          "Tether를 끝내도 다른 앱의 유휴 절전 방지 요청은 유지됩니다. 기능 중복만으로 충돌은 아닙니다."))
                    overlapDetail(L("Screen-off", "화면 꺼짐"),
                        displayOverlapDetail)
                    overlapDetail(L("Login lock", "로그인 잠금"),
                        L("Display keeping targets idle display sleep. Manual lock and macOS password requirements still apply. Closed-lid and screen-saver locking need separate verification.",
                          "화면 유지는 유휴 화면 꺼짐에 적용합니다. 수동 잠금·암호 요구는 macOS에 따릅니다. 덮개·화면 보호기 잠금은 별도 확인이 필요합니다."))
                    if model.showsLidOptions {
                        overlapDetail(L("Closed-lid work", "덮개 유지"),
                            L("A global sleep override can overlap Tether's lid request; its writer cannot be reliably identified. Sleep on unplug can interrupt other apps' work, while releasing Tether alone need not put the Mac to sleep.",
                              "전역 잠자기 차단과 겹칠 수 있지만 설정한 앱은 구별할 수 없습니다. 분리 시 잠자기는 다른 앱 작업도 중단할 수 있고, Tether만 해제하면 Mac이 바로 잠들지는 않을 수 있습니다."))
                    }
                }.padding(.top, 8)
            }.font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var displayRequestStatus: String {
        guard let holding = model.userSessionStatus?.displayHolding else {
            return L("Request state unverified", "요청 상태 미확인")
        }
        return holding ? L("Idle display-sleep request active", "유휴 화면 꺼짐 방지 요청 활성")
            : L("Request inactive", "요청 해제됨")
    }
    private var displayOverlapDetail: String {
        if !model.v3Settings.keepDisplayAwake {
            return L("Tether's display-keeping choice is off. Other apps can still request a lit screen; review their screen-awake options.",
                     "Tether의 화면 유지 선택은 꺼져 있습니다. 다른 앱이 화면 켜짐을 요청하면 해당 앱의 화면 유지 옵션을 확인하세요.")
        }
        if model.userSessionStatus?.displayHolding == true {
            return L("Tether is requesting idle display-sleep prevention for all displays. Turn off display keeping in Work session settings to release this request.",
                     "Tether가 모든 화면의 유휴 꺼짐 방지를 요청 중입니다. 작업 유지 설정에서 화면 유지를 끄면 이 요청을 해제합니다.")
        }
        return L("Display keeping is selected, but an active request is not confirmed. It applies only during a valid work session; review the request state above.",
                 "화면 유지는 선택되어 있지만 활성 요청은 확인되지 않았습니다. 유효한 작업 유지 중에만 적용하며, 위 요청 상태를 확인하세요.")
    }
    private func overlapDetail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            Note(text)
        }
    }
}
