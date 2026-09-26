import Foundation
import TetherCore

// `tether`: control Tether from a terminal, a script, an agent, or Shortcuts ("Run Shell Script").
// Writes the same control file the menu bar app writes; the helper applies it.

let usageText = L("""
tether: control Tether's clamshell mode

  tether [status] [--json]      current state (--json for scripts and agents)
  tether on | off | toggle      turn clamshell mode on, off (until power is connected again), or flip it
  tether sleep                  sleep now, even on power
  tether hold <time>            stay awake on battery too: 30m, 1h, 1h30m, 90 (minutes), up to 4h
  tether hold +30m              extend the running battery hold (at most 4 h from its start)
  tether hold off               end the battery hold
  tether run [--max <time>] [--] <command…>
                                keep the Mac awake until the command finishes (lid closed and on
                                battery too, within the safety limits), then let it sleep again
  tether doctor                 quick checks of the helper, watchdog, settings and login item
  tether diagnose [--record] [--out <file>] [--hours <n>]
                                a troubleshooting report in Markdown, for an issue or an AI assistant;
                                --record logs in detail while you reproduce a problem, then reports it

The same commands work as URLs: tether://sleep, tether://hold/90m, tether://toggle
""", """
tether: Tether 클램쉘 모드 제어

  tether [status] [--json]      지금 상태 (--json: 스크립트·에이전트용)
  tether on | off | toggle      클램쉘 모드 켜기 / 끄기(전원을 다시 연결할 때까지) / 전환
  tether sleep                  지금 잠자기 (전원이 연결돼 있어도)
  tether hold <시간>             배터리에서도 유지: 30m, 1h, 1h30m, 90 (분), 최대 4h
  tether hold +30m              켜져 있는 배터리 유지 늘리기 (시작부터 최대 4시간)
  tether hold off               배터리 유지 끄기
  tether run [--max <시간>] [--] <명령…>
                                명령이 끝날 때까지 깨어 있게 함 (덮개를 닫고 배터리여도 안전 기준 안에서),
                                끝나면 다시 잠들 수 있게 풀어 줌
  tether doctor                 도우미, 감시 장치, 설정, 로그인 항목 빠른 점검
  tether diagnose [--record] [--out <파일>] [--hours <n>]
                                문제 해결용 Markdown 보고서 (이슈나 AI 도우미에 붙여 넣기용).
                                --record는 문제를 재현하는 동안 자세히 기록한 뒤 보고서를 만듦

같은 명령을 URL로도 쓸 수 있습니다: tether://sleep, tether://hold/90m, tether://toggle
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
