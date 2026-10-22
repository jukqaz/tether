import SwiftUI
import TetherCore

/// Initial setup guidance; reading it never changes session settings.
struct WorkSessionGuide: View {
    @ObservedObject var model: AppModel
    var includesSetup = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if includesSetup && model.requiresHelperSetup {
                point("wrench.and.screwdriver", L("Prepare the MacBook helper first", "MacBook 도우미 먼저 준비"),
                    L("The helper is required for MacBook setup. macOS asks for administrator approval. Desktop Macs skip this installation.",
                      "MacBook 시작 준비에는 도우미가 필수입니다. macOS에서 관리자 인증을 요구합니다. 데스크톱 Mac은 이 설치를 생략합니다."))
            }
            point("powerplug.fill", L("Automatic sessions", "자동 유지"),
                L("Enable AC automatic in Work sessions to keep working when the selected AC conditions match. New installations start off. Closed-lid permission is independent.",
                  "작업 유지에서 ‘AC 자동 유지’를 켜면 선택한 AC 조건이 맞을 때 유지합니다. 새 설치는 꺼짐이며 덮개 허용과 독립적입니다."))
            point("timer", L("Manual sessions", "수동 유지"), model.hasInternalBattery
                ? L("From the menu, choose a duration and press Start. Power allows Unlimited; battery allows up to 2 hours. End manual session leaves automatic rules enabled.",
                    "메뉴에서 시간을 고르고 시작을 누르세요. 전원에서는 무제한, 배터리에서는 최대 2시간입니다. ‘수동 유지 종료’는 자동 조건을 끄지 않습니다.")
                : L("From the menu, choose a duration or Unlimited and press Start. End manual session leaves automatic rules enabled.",
                    "메뉴에서 시간이나 무제한을 고르고 시작을 누르세요. ‘수동 유지 종료’는 자동 조건을 끄지 않습니다."))
            point("pause.circle", L("Pause automatic and manual work", "자동·수동 중지"),
                L("Ends manual work and pauses automatic triggers until Resume work. Resuming does not enable disabled rules or restart an ended timer.",
                  "수동 유지를 끝내고 ‘작업 재개’를 누를 때까지 자동 유지도 멈춥니다. 재개해도 꺼 둔 자동 조건이나 끝난 타이머를 켜지 않습니다."))
            if model.showsLidOptions {
                point("macbook", L("Closed-lid work", "덮개를 닫고 작업"),
                    L("Allow closed-lid work after required helper setup. It only applies during active work. Unplugging ends all existing requests; the selected closed-lid action then applies. Actual sleep is not guaranteed.",
                      "필수 도우미 준비 뒤 덮개 유지를 허용하세요. 진행 중인 유지에만 적용합니다. 전원 분리는 모든 기존 요청을 끝내고 선택한 닫힘 동작을 적용하며 실제 Sleep을 보장하지 않습니다."))
            }
            point("shield.lefthalf.filled", L("Protection comes first", "보호가 먼저 적용됩니다"),
                L("Serious or critical OS thermal pressure stops work. ", "OS 열 상태가 심각·위험이면 유지를 중단합니다. ")
                + (model.hasInternalBattery ? L("Battery limits can end it earlier. ", "배터리 한도에 따라 더 일찍 끝날 수 있습니다. ") : "")
                + L("After recovery, resume in Device protection; ended manual requests are not restored.", "회복 뒤 기기 보호에서 다시 시작하며, 끝난 수동 요청은 복원하지 않습니다."))
            point("display", L("Screen off, lock and sleep are separate", "화면 꺼짐·잠금·잠자기는 별개"),
                L("Keep-awake lets work continue with the screen off. macOS controls password requirements. Tether does not unlock a locked Mac or change remote apps' requests.",
                  "화면이 꺼져도 작업을 유지할 수 있습니다. 암호 요구는 macOS 설정을 따릅니다. Tether는 잠긴 Mac을 해제하거나 원격 앱의 요청을 바꾸지 않습니다."))
        }
    }
    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.tetherAccent).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
