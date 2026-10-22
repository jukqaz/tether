import Foundation
import TetherCore

// `tether`: control Tether from a terminal, a script, an agent, or Shortcuts ("Run Shell Script").
// Commands are delegated to the running app's common work-session coordinator.

let usageText = L("""
tether: control Tether's work sessions

  tether [status] [--json]      current state (--json for scripts)
  tether on | off | toggle      enable / disable Tether / flip the current state
  tether auto on | off          enable / disable the automatic power trigger
  tether condition ac          automatic requests are AC only
  tether manual unlimited       unlimited manual work on AC (independent of the automatic trigger)
  tether manual <time>          timed manual work on AC; battery up to 2h, stricter limits apply
  tether manual +15m | +30m     explicitly extend manual work when the full amount is allowed
  tether manual off             end only manual work; automatic work can continue
  tether manual <time> --pid PID
                                end this manual request when the verified process ends
  tether run --minutes N|--unlimited -- executable [arguments...]
                                confirm manual work before running; return the child's exit status
  tether task begin             structured AC-only work event; returns job identity and scope token
  tether task working|waiting|idle|heartbeat|finish|fail|cancel
      --job-id UUID --seq N --scope TOKEN [--producer ID] [--ttl 1...300]
                                send subsequent states; idle/end releases only this job reason
  tether sleep                  sleep now, even on power
  tether hold <time>            battery work: 30m, 1h, 1h30m, 90 (minutes), up to 2h
  tether hold off               end the battery hold
  tether displays [--json]       Read current display names, connections and evidence.
  tether doctor                 quick checks of the helper, watchdog, settings and login item
  tether diagnose [--record] [--record-minutes 1...240] [--out <file>] [--hours 1...72] [--include-app-names]
                                a troubleshooting report in Markdown, for an issue or an AI assistant;
                                --record logs in detail while you reproduce a problem, then reports it

The same commands work as URLs: tether://sleep, tether://hold/90m, tether://toggle
Open the matching Tether app first. The CLI does not start a background service.
Desktop Macs use the general sleep-prevention request without a lid helper.

""", """
tether: Tether 작업 세션 제어

  tether [status] [--json]      지금 상태 (--json: 스크립트용)
  tether on | off | toggle      Tether 켜기 / 끄기(다시 켤 때까지) / 전환
  tether auto on | off          자동 전원 트리거 켜기 / 끄기
  tether condition ac          자동 요청은 AC 전용
  tether manual unlimited       전원 연결 중 수동 무제한 유지 (자동 트리거와 별개)
  tether manual <시간>           전원에서는 시간 지정, 배터리 최대 2시간 · 더 엄격한 보호값 우선
  tether manual +15m | +30m     선택 분량 전체가 허용될 때 명시적으로 연장
  tether manual off             수동 유지에만 적용 · 자동 유지는 계속될 수 있음
  tether manual <시간> --pid PID
                                확인한 프로세스 종료 시 이 수동 요청도 종료
  tether run --minutes N|--unlimited -- 실행파일 [인수...]
                                수동 유지 확인 후 실행 · 자식 프로세스 종료 상태 반환
  tether task begin             AC 전용 구조화 사건 · 작업 ID와 scope 토큰 반환
  tether task working|waiting|idle|heartbeat|finish|fail|cancel
      --job-id UUID --seq N --scope TOKEN [--producer ID] [--ttl 1...300]
                                후속 상태 전송 · 유휴/종료는 이 작업 요구만 해제
  tether sleep                  지금 잠자기 (전원이 연결돼 있어도)
  tether hold <시간>             배터리 유지: 30m, 1h, 1h30m, 90 (분), 최대 2시간
  tether hold off               배터리 유지 끄기
  tether displays [--json]       현재 화면 이름·연결·판정 근거 읽기.
  tether doctor                 도우미, 감시 장치, 설정, 로그인 항목 빠른 점검
  tether diagnose [--record] [--record-minutes 1...240] [--out <파일>] [--hours 1...72] [--include-app-names]
                                문제 해결용 Markdown 보고서 (이슈나 AI 도우미에 붙여 넣기용).
                                --record는 문제를 재현하는 동안 자세히 기록한 뒤 보고서를 만듦

같은 명령을 URL로도 쓸 수 있습니다: tether://sleep, tether://hold/90m, tether://toggle
같은 버전의 Tether 앱을 먼저 열어 주세요. CLI는 별도의 백그라운드 서비스를 시작하지 않습니다.
전원 분리는 기존 요청을 모두 종료합니다. 작업 사건은 실제 작업 중에만 heartbeat를 보내 주세요.
데스크톱 Mac은 덮개 도우미 없이 일반 절전 방지 요청을 사용합니다.

""")

let arguments = Array(CommandLine.arguments.dropFirst())

/// A line on stderr, so stdout stays clean for pipes and --json.
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    note(message)
    exit(code)
}

let cannotWrite = L("Can't write the control file (\(TetherPaths.controlPath)). Try reinstalling the helper.",
                    "설정 파일을 쓸 수 없습니다 (\(TetherPaths.controlPath)). 도우미를 다시 설치해 보세요.")

func time(_ t: Double) -> String {
    Texts.time(Date(timeIntervalSince1970: t))
}
