# Tether v4 구현·검증 · 후보58

2026-10-16 갱신. 사용자 승인 범위는 명세·승인 시안 구현과 자동 검증이다. 설치, 실제 덮개/케이블/Sleep, 시스템 잠금 설정 변경과 공개 배포는 수행하지 않는다.

## 구현한 동작

- 자동은 AC에서만 동작한다. AC→배터리는 기존 자동·수동·작업 이벤트를 소비한다. 배터리에서 시작해 AC를 방문한 수동도 재분리 시 끝나며, 승계 예약과 옛 요청 재생은 없다.
- 배터리 수동은 최초 시작+120분 상한이다. +15/+30분은 전체 분량을 승인할 때만 적용한다. 덮개가 필요한 연장은 기존 허가 준비와 새 마감 적용을 나누고, 실패하면 원래 마감으로 되돌린다. 그동안 원래 기한이 지났다면 자연 만료로 종료한다.
- 자체 유지 해제, 원복, Sleep 요청, OS의 실제 Sleep을 구분한다. 원복 실패는 저널을 남기고 재시도하며 이전 Sleep을 재실행하지 않는다. 소유자 상실·Sleep·보호·종료 뒤에는 옛 수동이 부활하지 않는다.
- AND 묶음/OR 그룹의 AC 규칙, 프리셋, 수동/PID·CLI 작업 이벤트와 공통 명령 진입점을 연결했다. 실제로 선택한 제공자만 관측한다. 기본 AC 모드와 자동 OFF에서 고급 제공자의 정기 조회를 만들지 않는다.
- F14 예행연습은 복사본만 평가한다. F15 업데이트 예약은 특정 패키지·현재 실행에 한정하고 교체 직전 재검사한다. F16 이력은 설정만 선택 복원한다. F17 만료 예고는 기본 OFF이며 요청별 한 번, 현재 승인 마감만 사용한다.
- 외장 화면의 검증된 native 위임을 새 실행 경로에도 연결했다. 열린 덮개에서만 시도하고, 조회 중 신규 전역 쓰기를 보류한다. 시도 뒤 만료·권한·열 조건이 바뀌면 이전 관측만으로 재획득하지 않는다. 읽을 수 없던 자체 원복이 나중에 확인되면 타사 충돌로 오인하지 않는다.
- 메뉴와 설정3탭을 승인된 컴팩트 구성으로 연결했다. 첫 설정의 AC 자동과 덮개 허용은 별개이며 새 설치에서는 둘 다 OFF다. 본문만 스크롤하고 제목/완료 조작을 고정한다.

## 자동 검증 근거

[최종 자동 판정](../.build/verification/v4-implementation-20261015/automated-accepted-v4/summary.json)은 **49단계 통과, 실패0, 실행 중 소스 변경0**이다. 이 실행에는 실제 XCUITest 조작이 포함되지 않는다. `ui-native-runner`는 실행기 판정 도구의 회귀 검사다. 이전 실패와 수정 전 재현은 같은 검증 폴더에 보존했고 최종 수에 중복 합산하지 않았다.

| 검증 | 결과와 근거 |
|---|---|
| Swift 소스 | 1,127개 중 기본 실행1,125개 통과·2개 사전조건 skip. 두 CLI 통합 검사는 아래 최종 패키지 실행에서 모두 보완했다. [원본](../.build/verification/v4-implementation-20261015/automated-accepted-v4/source-tests.log) |
| 패키지 앱·CLI | 선택 실행19개 통과·실패/skip0. 기본 실행에서 건너뛴 CLI2개를 포함하며 소스 수와 별도 합산하지 않는다. 실제 명령 코드는 승인 뒤에만 실행하고 거절 시 미시작 자식만 정리한다. [원본](../.build/verification/v4-implementation-20261015/automated-accepted-v4/packaged-app-cli.log) |
| 패키지 도우미 | 기존 실행기105사례와 v4 추가14사례 통과. 분리 소비·일회 종료·연장 준비/커밋/롤백·이전 요청 비부활·타사 값 보존·일반 작업 독립성을 확인했다. OS 쓰기는 dry-run이다. [기존](../.build/verification/v4-implementation-20261015/automated-accepted-v4/packaged-v3-helper.log) · [v4](../.build/verification/v4-implementation-20261015/automated-accepted-v4/packaged-v4-helper.log) |
| 격리 통합 | 서비스·공통 작업·충돌·GUI 권한·전원/화면 관측·native 위임·이관·종료·복구·기기 분기·수집/분석 도구를 모두 통과했다. 모의 센서·private IPC이며 물리 결과가 아니다. [49단계별 로그](../.build/verification/v4-implementation-20261015/automated-accepted-v4/summary.json) |
| 설치·이관 모의 시험 | 63사례와 실제 이전56 도우미를 사용한 격리 이관10사례 통과. schema4 보존, 이전 배터리 자동의 AC/OFF 이관, 비부활, 실패 원복, 로그 경로 권한을 포함한다. 실제 시스템 설치는 아니다. [63사례](../.build/verification/v4-implementation-20261015/automated-accepted-v4/upgrade.log) · [이전56](../.build/verification/v4-implementation-20261015/automated-accepted-v4/upgrade-build-56.log) |
| 패키지 | 후보58·arm64·최소macOS26·개발용 ad-hoc 서명 검증 통과. App Intents2개/Shortcuts4개 메타데이터 추출. [정체성·해시](../.build/verification/v4-implementation-20261015/final-package-identity.json) |
| 실제 시간 도우미 타이머 | 최종 패키지3/3 통과. 직접 배터리 수동 마감2.182초, AC 분리·첫 원복 실패 뒤 유한 재시도5.156초, 배터리 수동 permit 마감2.157초. 기다리는 동안 IPC 없이 상태 파일만 조회했으며 각 원복·Sleep 요청1회·receipt 소비를 확인했다. 짧은 마감은 시험 wire이며 UI 최소60초와 구분한다. [원본](../.build/verification/v4-implementation-20261015/lid-recovery-timers-final.log) |
| 실제 유한 assertion | 이 호스트에서 생산 idle driver의 명시적30초 건강성 허가가 시험 자식 정지 중에도 OS에서 만료되는 것을 관측했다. 독립 caffeinate 요청은 생존했다. 최초 비활성 표본은 기한+0.087초, 표본 간격0.121초다. 전역 SleepDisabled 원복·root watchdog 상한·실제 Sleep 증거는 아니다. [원본](../.build/verification/v4-implementation-20261015/native-expiry/result.json) |
| Sparkle | 임시 키·localhost·실행되지 않는 합성 앱으로 서명/변조·채널·버전13사례 통과. 실제 배포 업데이트는 아니다. [원본](../.build/verification/v4-implementation-20261015/native-sparkle-run.log) |
| 시각 검수 | 메뉴·설정3탭·펼침/끝 스크롤·밝은 외관·영어·시트 등34장 생성·검수. 새 확정 잘림은 발견하지 못했다. 당시 GUI의 동일성은 원본에 보존했다. 후속 변경은 private 시험 관측·읽기 전용 상태, UI 자식 식별자·접근성 컨테이너와 시험 코드에 한정되며 시각 배치·텍스트·액션·전원 정책은 그대로다. [검수](../.build/verification/v4-implementation-20261015/final-package-ui/render-review.json) · [후속 연속성](../.build/verification/v4-implementation-20261015/native-ui-containment-continuity.json) |
| 실제 UI 자동화 | **부분 통과, 수정9개 재검증 미완료.** 메뉴1/1과 나머지23개 중14개가 통과해 고유15/24 경로를 확인했다. 후속9개는 Mac 잠금으로 첫 앱 활성화가 실패해 중단했다. 한 번의24/24 통과가 아니며 처음의 자동화 초기화 차단·이후 실제 assertion 실패도 보존한다. [통합 현황](../.build/verification/v4-implementation-20261015/native-ui-acceptance-summary.json) · [잠금·중단 근거](../.build/verification/v4-implementation-20261015/native-ui-failed-retry/interruption.json) |

49단계 직후의 추가 실시간 시험3사례와 당시 동일성은 [원본](../.build/verification/v4-implementation-20261015/post-verification.json)에 보존했다. 이후 UI 재검증에서는 private 시험 경로와 접근성 메타데이터를 수정해 GUI 실행물이 달라졌다. Core·helper·recovery·CLI·Resources124개 입력 및 AppModel계열27개는 원49단계와 SHA가 같고 패키지의 도우미·복구·CLI도 같다. 따라서 기존 기능 근거를 해당 범위로 재사용하며 새49단계 전체 실행이라고 표시하지 않는다. [현재 후보 정체성](../.build/verification/v4-implementation-20261015/native-ui-current-package-identity.json) · [범위 대조](../.build/verification/v4-implementation-20261015/native-ui-containment-continuity.json).

### 실제 UI 재시도에서 확인한 내용

- [메뉴1/1](../.build/verification/v4-implementation-20261015/native-ui-menu-final/result.json): 실제 시작·종료·자동/모두 중지·재개, +15/+30분 클릭으로 같은 요청의 승인 마감이 각각900/1800초 늘고 다음 시간 선택이 현재 마감을 바꾸지 않는 것을 확인했다.
- [나머지23개](../.build/verification/v4-implementation-20261015/native-ui-remaining/result.json): 14통과·9실패, skip·expected failure·런타임 경고0. 한국어/영어 최소 창·3탭·스크롤·닫기/재열기, 포인터/키보드 포커스 유지, 배터리 선택만으로 미시작, 데스크톱 분기, 화면 유지 해제를 포함한다.
- 실패 캡처에서 시험 관측이15초 뒤 낡는 문제, 부모ID가 자식 버튼ID를 덮는 문제, 펼친 뒤 Triangle 대신 Group을 조회하는 문제를 확인했다. private 관측 타이머·자식 식별자·접근성 컨테이너를 보완했다. 관측 회귀6/6은 통과했으며 생산 경로의15초 신선도 제한은 바꾸지 않았다.
- 키보드 포커스 이동과 탭 선택을 별도로 검사하고, 비활성 화면에 불필요한 ‘모두 중지’를 요구하던 기대값을 수정했다. 시트/첫 설정의 자식ID 수정까지 빌드·서명·정적 검사는 통과했지만, **이9개 경로의 실제 재검증은 아직 통과하지 않았다.**
- 2026-10-16 01:20 KST경 읽기 전용 OS 조회에서 `CGSSessionScreenIsLocked=true`를 확인했다. 앱이 Background에 머물러 활성화되지 않았으므로 해당 실행을 중단하고 그 실행물만 정리했다. 원본 시험기의 `timed_out=true`는 이 수동 중단도 포함하며1800초를 모두 기다렸다는 뜻이 아니다. 잠금을 자동 해제하거나 정책을 바꾸지 않았다.

이 검사는 실제 macOS 컴포넌트를 조작하지만 고유 private Bundle ID·메모리 설정·모의 센서/assertion을 사용한다. 설치 앱·도우미·실제 클램쉘 결과와 구별한다. [고유 경로별 결과](../.build/verification/v4-implementation-20261015/native-ui-acceptance-summary.json).

검증 호스트는 Apple Silicon/macOS27.0.1/Xcode27이다. macOS26의 실제 기기·일반 사용자 설치/권한·Shortcuts 등록·알림 표시·원격/외장 화면 인수는 별도다. 정적 캡처는 메모리 설정과 가짜 실행 backend를 사용한다. 영어 캡처의 언어 Picker가 한국어를 선택한 fixture 불일치와 빈 이력/예약 설명 화면만의 범위도 검수 원본에 기록했다. 모든 동적 UI 상태를 검증한 것으로 해석하지 않는다.

실행 중 발견해 고친 주요 결함은 동일 보호 ACK의 갱신 루프, 기존 배터리 하한의 하향 이관, 옛 실행 허가의 분리 후 재생, 만료 수동을 근거로 한 종료 요청, GUI 관측 공백에서의 기존 유한 허가 처리, native 위임 누락·늦은 원복 오인·타사 전역값의 일반 작업 차단 전파다. 타사 전역 상태를 임의로 해제해 해결하지 않았다.

## 화면 자료

- [메뉴](../.build/verification/v4-implementation-20261015/final-package-ui/renders/menu-ko-dark.png)
- [작업 설정](../.build/verification/v4-implementation-20261015/final-package-ui/renders/general-ko-dark.png)
- [보호 설정](../.build/verification/v4-implementation-20261015/final-package-ui/renders/safety-ko-dark.png)
- [앱 설정](../.build/verification/v4-implementation-20261015/final-package-ui/renders/system-ko-dark.png)

## 남는 인수 범위

- Mac 잠금 해제 후 수정한 실제 UI9개 경로만 재검증. 나머지15개는 원래 통과 기록과 수정 범위 대조를 유지한다. 모든 동적 이력/예약·권한 UI 상태나 전 요소 정량 디자인 점수가 완료된 것은 아니다.
- 새 후보의 실제 설치/관리자 인증/일반 사용자 실행 및 기존 설치본 업데이트.
- 닫힌 상태 전원 분리→자체 원복→실제 Sleep, 열림 Wake, 배터리 만료와 AC 재연결의 물리 로그 대조.
- 원격 접속·외장 디스플레이·macOS26 대상 기기, 실제 권한·알림 표시와 장시간 내구성/성능 실측.
- 위젯/Controls 노출과 미검증 미디어/부분파일 자동 감지는 후속 범위다. 현재 UI에서 정상 지원처럼 선택시키지 않는다. 명령에 연결한 작업/PID 종료는 별도로 구현했다.

설치본과 시스템 전원·잠금 설정은 이번 작업의 검증 후보로 교체하지 않는다. 모의 센서, `--dry-run` 도우미, 정적 렌더와 private native UI를 실제 클램쉘 통과로 표시하지 않는다.

## 작업 기록 연결

GroundLine 학습 경계 연결은 `learning_native_artifact_changed`로 실패했다. 학습 성과를 임의로 등록하지 않았고, 이 별도 기록은 native 경계를 다시 확인한 뒤 재처리해야 한다. [원본](../.build/verification/v4-implementation-20261015/learning-boundaries.json). 구현·시험 판정은 위 실행 원본에 근거한다.
