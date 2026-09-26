import Foundation
import TetherCore

/// What the ⓘ next to a setting explains. Only settings whose meaning or trade-off isn't clear
/// from the name get one; the words Tether uses (battery floor, heat levels, lid session) are
/// explained where they appear.
enum SettingsInfo {
    static var lidCloses: String {
        L("Stay unlocked: remote sessions, agents and downloads carry on, and reopening the lid needs no password; the screen and keyboard light under the lid go dark. Lock the screen: it locks as the lid closes, safer if you leave the Mac somewhere. Either way the Mac stays awake on power.",
          "잠그지 않고 화면만 어둡게: 원격 접속, 에이전트, 다운로드가 계속되고 덮개를 다시 열 때 암호가 필요 없어요. 덮개 아래 화면과 키보드 조명은 꺼 둬요. 화면 잠그기: 덮개를 닫는 순간 잠겨서 Mac을 두고 자리를 뜰 때 더 안전해요. 어느 쪽이든 전원이 연결돼 있으면 Mac은 깨어 있어요.")
    }

    static var idleScreenOff: String {
        L("In clamshell mode the screen can't sleep the usual way: display sleep would lock the Mac. So after this many idle minutes Tether blacks the screen out instead, and any key or mouse brings it straight back, unlocked. It waits while a video or a call keeps the screen on.",
          "클램쉘 모드에서는 화면을 평소처럼 끄면 Mac이 잠겨요. 그래서 이 시간 동안 입력이 없으면 대신 화면을 검게 끄고, 키보드나 마우스를 쓰면 잠금 없이 바로 돌려요. 동영상이나 통화가 화면을 켜 두는 동안에는 기다려요.")
    }

    static var batteryHold: String {
        L("A battery hold keeps clamshell mode on battery for a while, 30 minutes to 4 hours, say to finish a job in a bag. Start it from the panel. It ends early, and a closed Mac sleeps, at any of the limits below; the helper enforces them even with the app closed.",
          "배터리 유지는 배터리로도 클램쉘 모드를 잠시(30분~4시간) 유지해요. 가방 안에서 작업을 끝낼 때처럼 쓰고, 패널에서 켜요. 아래 기준 중 하나에 닿으면 먼저 끝내고 덮개가 닫힌 Mac을 재워요. 이 기준은 앱이 꺼져 있어도 도우미가 지켜요.")
    }

    static var autoAdjust: String {
        L("Tether measures this Mac's battery temperature with the lid closed and open, and the charge a hold uses. With this on, the two temperature limits sit 4 °C above the usual peak and the longest hold fits the measured drain, updated as measurements come in. It needs about 30 minutes with the lid closed first, and never goes looser than the defaults.",
          "Tether는 덮개를 닫았을 때와 열었을 때의 배터리 온도, 배터리 유지 중 사용량을 재요. 이걸 켜면 두 온도 기준을 평소 최고 온도보다 4°C 위로, 최대 시간을 잰 사용량에 맞춰 정하고 기록이 쌓일 때마다 다시 맞춰요. 덮개를 닫고 30분쯤 쓴 기록이 필요하고, 기본값보다 느슨해지지 않아요.")
    }

    static var floor: String {
        L("The battery floor: a hold ends when the charge falls to this. A hold can't start at or below it, and a closed Mac on a charger too weak to keep up is put to sleep at this level too.",
          "하한선이에요. 배터리가 이만큼 남으면 유지를 끝내요. 이 잔량 이하에서는 유지를 시작할 수 없고, 출력이 모자란 충전기에 연결된 채 덮개가 닫힌 Mac도 이 잔량이 되면 재워요.")
    }

    static var closedLidLimit: String {
        L("A closed Mac may be in a bag with no airflow, so its limit is lower than with the lid open. Battery wear speeds up above 40 °C. Besides this limit, a hold with the lid closed also ends after a minute at 3 °C below it, or at “serious” heat.",
          "덮개가 닫혀 있으면 가방 안처럼 바람이 통하지 않을 수 있어서, 덮개를 열었을 때보다 기준이 낮아요. 배터리는 40°C를 넘으면 빨리 닳아요. 덮개가 닫혀 있으면 이 온도 말고도 3°C 낮은 온도가 1분 이어지거나 발열이 '심각'이 될 때 끝내요.")
    }

    static var heatLevel: String {
        L("Heat is how hard macOS works to stay cool: normal, fair, serious, critical. When a closed Mac on power reaches the level chosen here, Low Power Mode comes on to cool it, and your setting comes back after \(Int(ACThermalPolicy.coolDown / 60)) cool minutes. At critical for \(Int(ACThermalPolicy.sleepAfterCritical / 60)) minutes with no display attached, the Mac is put to sleep whatever you choose.",
          "발열 단계는 macOS가 열을 식히느라 애쓰는 정도예요: 정상, 주의, 심각, 위험. 전원 연결 중 덮개를 닫은 Mac이 여기서 고른 단계에 이르면 저전력 모드를 켜서 식히고, \(Int(ACThermalPolicy.coolDown / 60))분 동안 식으면 원래 설정으로 돌려요. 모니터 없이 '위험'이 \(Int(ACThermalPolicy.sleepAfterCritical / 60))분 이어지면 이 설정과 상관없이 재워요.")
    }

    static var lidSessions: String {
        L("A lid session is one stretch awake with the lid closed, from closing the lid to opening it or sleeping. Those of \(Int(LidSession.minimumDuration / 60)) minutes or more are kept, with the peak battery temperature and the charge used.",
          "덮개 세션은 덮개를 닫고 깨어 있던 한 번의 기간이에요. 덮개를 닫을 때부터 열거나 잠들 때까지이고, \(Int(LidSession.minimumDuration / 60))분 넘게 이어진 것만 최고 배터리 온도, 쓴 배터리와 함께 남겨요.")
    }
}
