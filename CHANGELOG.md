# Changelog

## 2026.11.1 Beta 1 (빌드 59)

- 메뉴바에서 현재 유지, 새 수동 시작, 자동만 일시 중지, 모두 중지를 구분합니다. 덮개·화면 허용과 실제 적용 상태를 함께 확인할 수 있습니다.
- 전원·덮개, 수동 유지, 보호·진단, 일반 설정을 사이드바로 정리했습니다. 전원 분리와 덮개 설정의 저장값을 빠르게 확인할 수 있습니다.
- 전원 범위가 다른 곳에서 바뀌면 열린 자동 조건 편집창에서 오래된 값으로 덮어쓰지 않습니다. 덮개 해제 확인 안내는 복구 조작이 있는 페이지로 이동합니다.
- 보호 후 자동 회복을 켜면 최신 안전 관측과 도우미의 보호 확인을 거쳐 자동 조건을 다시 평가합니다. 소진된 배터리 한도의 회복에는 안정된 AC 전원이 필요합니다.
- 사용하지 않던 메뉴 구현과 시작 화면 미디어를 제거했습니다.

## v4 로컬 후보58 · 2026-10-15 · 설치·배포 보류

- 자동을 AC 전용으로 정리하고 전원 분리 때 기존 자동·수동·작업 사건을 모두 소비한다. 승계 예약과 옛 수동의 복원을 제거한다.
- 분리·종료·원복과 일회 Sleep 요청을 구분하고 기존 보호 ACK 반복·하한 이관·GUI 관측 공백·native 위임·타사 전역값의 일반 작업 차단을 보완한다.
- 고급 규칙·프리셋·+15/+30분 연장·PID/CLI 작업·예행연습·작업 후 업데이트·설정 이력과 선택적 만료 예고를 연결하고 승인된 컴팩트 메뉴/설정3탭을 적용한다.
- 최종 자동49단계 통과·소스1,127개(CLI2개는 패키지에서 보완)·정적34장 검수. 실제 UI24개는 자동화 모드 초기화에서 차단됐고 설치·물리 시험은 미실시다. [구현·검증 결과](docs/IMPLEMENTATION-V4-20261015.ko.md).

## 로컬 설치 후보 · 2026.10.1 Beta 1 (빌드 57) · 미배포

- 도우미 로그 폴더가0700으로 남아 일반 사용자 진단·수집이 실패하던 권한 문제를 수정했다. 설치 전 안전한 파일 신원을 확인하고 폴더0755·기존 로그0644를 적용한다. root 쓰기 소유권·활성 inode·로그 내용과 기존 설정을 보존한다.
- 수집 분석에서 아직 생성되지 않은 선택 회전 로그를 조회 실패로 세던 표시를 수정했다. 활성 로그 부재·실제 권한 오류와 물리 미확인 판정은 보존하며 관련38개 회귀를 통과했다.
- 실제 앱·도우미57 설치 후 일반 사용자UID501 로그 읽기와 진단 보고서140줄 포함을 확인했다. 자동49단계·Swift1,043개·설치61사례가 통과했다. native UI는 기존17개+전면 유지 조건의 후속1개로18개 고유 경로를 확인했다. 원래 실패를 보존하며 한 번의18/18 실행으로 표시하지 않는다. 물리 시험은 나중에 진행한다. [검증 결과](docs/VALIDATION-CHECKLIST.ko.md).

## 미배포 후보 · 2026.10.1 Beta 1 (빌드 53)

- 닫힌 전원 분리와 유한 허가/수동 마감이 겹칠 때 GUI·도우미 관측 순서에 따라 Sleep 요청이 달라지던 경로를 수정했다. 만료된 허가로 새로운 Sleep을 실행하지 않으며 자체 원복과 유효한 자동 유지의 종료는 보존한다.
- 화면 진단이 열린 덮개에 과거 재시도 중단을 경고로 표시하지 않게 했다. 현재 연결·소유권·신선도와 가상/외장 화면의 실제 관측을 확인하고 원본 JSON 이력은 유지한다.
- 자동 확인 OFF→ON에서 과거 자동 다운로드 설정이 되살아나는 Sparkle 초기화를 보완했다. private bundle에서 실제 시작·KVO·구성 실패와 채널 잠금을 검사한다.
- 설정 설명을 native Section footer로 묶고 전원 조건의 “항상”을 “둘 다”로 명확히 했다. 메뉴의 중복 펼침 기호를 줄이고 수동 끝내기를 native 버튼으로 정리했다. 다크 기본·조작부 Liquid Glass와 사용자가 선택한 아이콘을 유지한다.
- 자동/수동 검증 근거와 이전 설치본52·새 후보53을 문서에서 구별한다. [현재 검사와 한계](docs/VALIDATION-CHECKLIST.ko.md), [남은 직접 조작](docs/MANUAL-ACCEPTANCE.ko.md).

## 미배포 후보 · 설계 v3 · 빌드 51

- MacBook에서는 현재 도우미 준비를 확인해야 시작 안내를 완료한다. 데스크톱은 설치를 생략하고 일반 작업 유지를 사용한다. 설치는 자동 트리거나 덮개 유지 활성화와 별개이며 기존 설정을 보존한다.
- 자동/수동 종료 예고·수동 만료·열/관측·배터리 보호 알림과 OS 권한 상태를 연결했다. 권한은 명시적 허용 버튼에서만 요청하며, 최근 동작·종료 사유와 다시 보는 사용법을 제공한다.
- 최초 배터리 전환 ACK의 지연·유실·종료와의 역순 응답으로 마감이 연장되거나 끝난 요청이 부활하던 경로를 수정했다. helper가 OS 배터리 경고를 직접 집행하고 경고 회복만으로 재개하지 않게 했다.
- 전원 분리 후 배터리 예외 시간에 1~120분 직접 입력을 제공한다. 선택은 시작과 분리하고 실행 중 마감은 바꾸지 않는다. 남은 시간을 접근성 Value에도 제공한다.
- 메뉴를 상태·자동 유지·수동 유지로 재구성하고 시작·남은 시간·일시 중지의 위계를 맞췄다. 설정은 세 개의 native 탭, 전원/배터리/항상 선택 버튼, 간결한 옵션 그룹을 사용한다. 메뉴바는 고정 크기의 전원 기호를 사용하며 진단의 긴 요청 정보는 펼침에 둔다. 최종 UI·충돌 표시 회귀 16개와 native 미리보기 조작을 확인했다. [화면과 검증 범위](docs/DESIGN-REVIEW.ko.md#2026-10-07--메뉴와-설정-시각-재구성).
- 전체 Swift 967개, 일괄 자동 검증 42단계, 패키지 helper 격리 실행 49개가 통과했다. 이전 49/50 helper 이관 14건·native Sparkle 13건과 현재 후보의 native UI 조작/정상 종료도 확인했다. 설치본 50·전원 설정은 유지했고 macOS 26 실물·인증된 원격·관리자 설치·실제 알림 표시는 별도 인수 항목이다. [현재 검증](docs/VALIDATION-CHECKLIST.ko.md).

## 미배포 후보 · 2026.9.1 Beta 8 (빌드 50)

- 도우미 해제 실패로 종료가 취소되면 같은 일반 작업·타이머를 보존하고, 업데이트의 비동기 해제 뒤 덮개 상태를 다시 검사한다. 만료된 타이머는 되살리지 않으며 native 해제 재시도·실제 소켓·실행 잠금 유지도 검증했다. 전체 Swift 555개(native 7개 포함), 실패·건너뜀 0. 실제 관리자·물리·전체 업데이트는 남는다. [종료 동작과 확인 범위](docs/UPDATE-TERMINATION-20261001.ko.md).

- 데스크톱/내장 배터리 미확인 상태의 배터리 예약·연장·조건 변경을 앱·URL·CLI에서 거절한다. 일반 작업·가져온 설정·원래 마감은 보존하고 취소는 제공한다. 기기별 조건과 CLI 가용성 표시를 맞췄으며 Swift 547개가 통과했다. [구조·검증 범위](docs/BATTERY-CAPABILITY-20261001.ko.md).

- 실행 중 기기 조회 실패·회복 때 일반 조정자·타이머·소비 예산을 유지하고 덮개 연결만 해제·재준비한다. 오래된 비동기 응답은 새 연결 권한으로 사용하지 않으며 해제 관측 전에는 갱신하지 않는다. 전체 Swift 543개와 새 격리 IPC 2개가 통과했다. [구조·검증 범위](docs/CAPABILITY-REFRESH-20261001.ko.md).

- 설정 v4 이관에서 기존 꺼짐·자동 조건·소비 예산을 보존하고 임시 타이머 재시작을 막았다. 도우미의 연결 준비와 현재 상태 재조회, epoch/revision·마감·호출 신원 검사로 지연된 연결이 최신 중지를 덮어쓰지 못하게 한다. Swift 534개가 통과했으며 실제 관리자 인계·물리·전체 업데이트 검증은 남아 있다. [이관 구조와 확인 범위](docs/SESSION-HANDOFF-20261001.ko.md).
- 앱 초기화 전에 사용자별 실행 잠금과 명령 서버를 확보한다. 중복 실행·예약 실패는 설정 이관과 전원 세션을 시작하지 않으며, 서버 중지·종료 승인만으로 잠금을 넘기지 않는다. 파일 신원 상실 시 자체 요청 해제와 추가 쓰기 거절을 보완했다. Swift 523개 통과, 실제 GUI·구버전/root 기록 인계·전체 업데이트는 남아 있다. [실행 수명과 확인 범위](docs/APP-COORDINATOR-LIFETIME-20261001.ko.md).
- CLI의 수동·자동·예약 명령을 실행 중인 앱의 공통 정책으로 연결했다. 실행 파일·GUI 권한·빌드·상태 버전·요청 ID·15초 마감을 확인하고 중복 연장·토글, 뒤의 끄기 취소, 만료 후 늦은 재개를 막는다. Swift 515개가 통과했으며 실제 관리자·Sleep/Wake·원격·전체 업데이트 검증은 남아 있다. [CLI 구현과 확인 범위](docs/USER-COMMAND-COORDINATOR-20261001.ko.md).

- MacBook도 앱의 공통 작업 정책과 유한 도우미 계약을 사용한다. 자동·수동 이유를 독립적으로 종료하고, 덮개 지원 오류가 일반 작업을 취소하지 않도록 분리했다. v1/v2 설정·꺼짐 선택·더 엄격한 제한·소비 예산을 v3에 보존한다. Swift 492개, debug·포장 동일 도우미 IPC 10개, 교차 14개·설치 원복 34개가 통과했다. CLI 공통 시작·실기기·전체 업데이트는 남아 있다. [공통 세션 구현과 확인 범위](docs/COMMON-SESSION-20261001.ko.md).
- 배터리·덮개 특성의 일부 조회 실패가 일반 작업 유지까지 막지 않도록 실행 경로를 보완했다. 초기 전원·잔량 표시를 갱신과 통일하고, 제한 변경 시 소비 예산을 보존한다. 전체 Swift 472개가 통과했으며 멈춘 별도 프로세스에서 실제 90초 OS 요청 만료와 외부 요청 보존을 확인했다. 확인된 MacBook·CLI의 공통 통합과 물리 검증은 남아 있다. [현재 구현·실측 범위](docs/GENERAL-SESSION-ROUTING-20261001.ko.md).
- 사용자 세션 시작·재개·연장 시 현재 전원·발열·잔량·GUI 권한을 재확인한다. 누락된 배터리 입력과 하한 도달 시 자체 요청을 해제하고, 기존의 더 엄격한 잔량·시간 제한과 원본 설정·소비 예산을 보존한다. 활성 목록의 NULL 응답은 종류별 OS 집계로 교차 확인한다. native 검사 포함 Swift 467개 통과. [검증 범위와 남은 라우팅](docs/USER-SESSION-INPUT-20261001.ko.md).
- 도우미 설치 전 기기 판정을 적용했다. 데스크톱은 관리자 도우미 없이 기존 작업 유지 경로를 사용하고, 관측 실패·미지원 플랫폼은 교체를 보류한다. MacBook의 덮개 열림 재검사는 유지한다. [설치·원복 34개와 검증 제한](docs/INSTALL-TARGET-20261001.ko.md).
- GUI 로그인 신원을 커널 소켓 정보와 Security 조회로 확인한다. 사용자 전환 시 자체 유지·임시 예약을 종료하고 새 사용자에게 자동 이전하거나 전체 Mac을 잠재우지 않는다.
- 같은 로그인의 화면 잠금과 원격 연결을 사용자 전환으로 취급하지 않는다. 잠금 정책을 변경하거나 잠금을 해제하는 기능은 추가하지 않았다.
- GUI 관측 공백에서 새 유지·갱신을 막고 기존 마감만 보존한다. 이전 상태는 새 핸드셰이크로 연결하며 명시적 끄기 선택과 설정을 보존한다.
- native 작성자 게이트 v2는 실행 직전 GUI 권한과 제어 앱 수명을 재검증한다. 대기 중 승인 철회·앱 종료·이전 실행기 혼합을 격리 시험했다. [실행 검증 범위](docs/GUI-WRITER-GATE-20261001.ko.md).
- 실제 관리자 실행·사용자 전환·동일 UID의 여러 GUI 로그인·원격/실기기 검증은 남아 있다. [GUI 구현 범위](docs/GUI-AUTHORITY-20261001.ko.md).

## 2.0.1 (2026-09-27)

Security fix; please update, including the helper (the app asks you to).

- Fixed a local privilege escalation. 2.0.0 left `/Library/Application Support/Tether` writable by
  the `admin` group and the root helper wrote its files through predictable temporary names, so a
  process running as an administrator could, without the password, make the helper overwrite or
  change the mode of other files as root. The folder is now root's alone, control.json is rewritten
  in place with links and hard links refused, the helper's own files go through `mkstemp` and
  `rename`, oversized files aren't read, and both the installer and the helper's start take the
  folder back and remove anything unexpected in it.
- The watchdog runs with a fixed `PATH`, and a path read from control.json can't add lines to the
  helper log.
- CI: `actions/checkout@v7` pinned to its commit, read-only token, Dependabot for actions.

## 2.0.0 (2026-09-26)

First public release.

- Clamshell mode follows power: on while connected, off on battery, and a Mac already closed is put
  to sleep the moment it's unplugged. Its switch turns it off until power is connected again.
- No lock: the screen under the lid is dimmed instead of sleeping the display. Optionally lock
  when the lid closes instead.
- Battery hold with safety limits enforced by the helper (battery temperature by lid state,
  thermal pressure, battery floor, time), adjustable only toward stricter values.
- Heat guard: Low Power Mode for a closed Mac running hot on power, and sleep if it keeps
  overheating with no display attached (a bag on a power bank counts as power).
- Low Power Mode only where you allow it (during battery holds; when hot on power, from "serious",
  from "fair" or never), and your own change to it is never undone.
- A watchdog LaunchDaemon that turns sleep back on if the helper ever stops while sleep is off on
  battery.
- A Mac put to sleep on power stays asleep through Power Nap's dark wakes; a charger that can't
  keep up can no longer run the battery flat with the lid closed; a battery hold can't start at or
  below the floor; the app relaunches after a crash.
- Data-based settings: time-weighted battery temperatures, battery use during holds, and
  recommended limits from them; "Adjust to this Mac" applies them by itself as measurements come
  in, never looser than the defaults.
- Sleep log: duration, charge per hour, sleep and wake causes, dark wakes; alerts on high drain.
- Screen off without locking after a few idle minutes.
- `tether` command with `status --json`, `hold`, `sleep`, `run -- <command>` and `diagnose`.
- `tether://` URLs for the Shortcuts app.
- Apps keeping the Mac awake, live in Settings and `tether status`.
- Troubleshooting: detailed logging and a Markdown report with masked names, from Settings or
  `tether diagnose --record`.
- Control Center style panel (full and compact) with a clamshell switch and a countdown to the
  second; a status item with a ring that empties during a battery hold.
- Icon Composer app icon (Liquid Glass, dark, clear and tinted), sidebar settings, English and
  Korean with a choice in Settings.
- `tether doctor` and a checks list in Settings › System and at the top of the report; "+30m"
  for a running battery hold (`tether hold +30m`), still capped at 4 hours from its start.
- In-place help: an ⓘ next to each setting that needs explaining (what it does, the words it
  uses), Help › Tether Help opening the README, and a glossary in the README.
- First-run welcome, update check against GitHub releases, full uninstall.
- A quiet panel: controls that can't act right now are hidden rather than greyed out, and there
  are no lid-open or toggle notifications (the last lid session is in the panel and History).
- Desktop Macs are left alone.
