# Tether 추가 부족 점검 · 2026-10-12

후속: 아래는 수정 전 읽기 전용 리뷰다. 기록 오류와 종료·복구 예외는 후보56에서 보완했고, 현재 검증·미완료 상태는 [검증 체크리스트](VALIDATION-CHECKLIST.ko.md)와 [후속 결과](../.build/verification/end-recovery-20261012/RESULT.ko.md)를 따른다. 당시 코드 줄 번호와 후보55의 실행 경계를 현재 구현으로 해석하지 않는다.

정상 경로의 자동 검증 통과와 전체 실사용 합격은 구별한다. 현재 소스·기존 검증 기록·Apple 공식 문서를 읽기 전용으로 검토했다. 새 UI 자동화·물리 시험·설치·설정 변경·제품 코드 수정은 하지 않았다.

핵심 유지 기능의 새 실행 결함을 이 범위에서 확정하지는 못했다. 다만 **집계·보호 원인의 확정 기록 오류**, **실제 Sleep을 보장하지 않는 의도된 종료 경계**, **사용성 공백**, **최신 후보의 업데이트 인수 부족**이 남아 있다.

## 우선순위와 완료 기준

| 순서 | 항목 | 분류 | 최소 보완·완료 기준 |
|---|---|---|---|
| 1 | 잠자기 집계·보호 원인 기록 | 확정 표시·진단 결함 | 요청 시도/거절/OS Sleep 관측을 구분하고 thermal과 battery 보호 이유를 올바르게 기록. 실제 OS 잠자기를 일으키지 않는 회귀로 확인 |
| 2 | 원복 실패 뒤의 닫힌 전원 분리 종료 | 의도된 동작 경계·정책 검토 | 기존 사건을 무조건 재실행하지 않음. 새 유효한 승인·현재 덮개/전원/소유자/보호를 다시 검사하는 재시도 정책을 결정하거나, 원복만 보장한다는 제한과 필요한 조작을 분명하게 표시 |
| 3 | 배터리 예외 만료·GUI 종료와 분리 경합 | 검증 부족 | 결정된 정책의 격리 경합 회귀와 실제 닫힌 Mac의 Sleep/Wake 로그를 함께 확인 |
| 4 | 현재 상태와 다른 앱의 해결 안내 | 확정 사용성 공백 | 관련 상황에서만 잠금/화면 예외와 조정할 옵션을 바로 표시. PID·경로·원시 요청만 접힌 기술 정보로 유지 |
| 5 | 최종 UI·설치·macOS26/실물 | 알려진 미완료 검증 | UI18종은 인증 뒤 실제 실행. 최신 GUI 설치·실행 hash·설정보존, 닫힌 AC 유지/분리/배터리/원격 및macOS26 인수 |
| 6 | 이전 배포판→후보55 업데이트 | 검증 부족·배포 정책 | 실제 이전 helper→55와 실패 원복, 실제 앱 다운로드/재실행/설정 보존. 정식/베타 대상별 기대 결과 결정. 사용자 결정대로 마지막에 실행 |
| 7 | 사용되지 않는 화면·오래된 문서 | 정리 후보 | 필요한 경고를 실제 메뉴에 연결한 다음 미사용 StateModule 정리. 설치 상태·검사 수는 현재 검증 기록을 참조하도록 갱신 |

## 1. 확정 기록 오류

### 1.1. 거절된 요청까지 잠든 횟수로 표시

[Helper+LidExecution.swift:363](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherHelper/Helper+LidExecution.swift:363)은 `commandRejected`에서도 `recordForcedSleep()`을 호출한다. [DailyStats.swift:119](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCore/Usage/DailyStats.swift:119)가 무조건 count를 증가시키고, [CLI:57](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCLI/StatusCommand.swift:57)은 “잠재움 N회”, [진단:172](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCore/Diagnostics/Diagnostics.swift:172)은 “forced sleeps”라고 표시한다. CLI의 해당 출력은 일반 common-session 출력과 구별되는 fallback/호환 경로다.

[기존 거절 회귀:677](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/scripts/test-redesign-helper.py:677)는 거절된 요청이1회로 끝나는 것을 확인하지만 집계·표현은 확인하지 않는다. OS 명령 성공도 실제 Sleep의 증거가 아니므로 단순히 성공 때만 count를 올리는 것으로 실제 잠든 횟수를 증명할 수 없다. 기존 저장 포맷을 보존하면서 “요청 시도”로 정직하게 표시하고 실제 Sleep 관측은 별도 근거로 다루는 것이 최소안이다.

### 1.2. 배터리 보호를 전원 과열로 기록

같은 함수의 `.protection` 성공은 항상 `.overheatSleep`으로 기록된다([368](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherHelper/Helper+LidExecution.swift:368)). `power=battery`, `thermal=0`, `batteryProtectionActive=true`의 허용 경로는 [SleepRequestPolicy.swift:73](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCore/Policy/SleepRequestPolicy.swift:73)와 [회귀:70](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Tests/TetherCoreTests/LidExecutionTests.swift:70)에 있다. 결과적으로 [Texts.swift:147](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCore/Text/Texts.swift:147)의 “전원 연결 중 과열 → 잠자기 요청”이 잘못 사용된다.

확정 영향은 lastEvent·로그·CLI·진단이다. `note()`는 그 자체로 알림을 발송하지 않으므로, 실제 잘못된 알림 발송까지 주장하지 않는다. 보호 원인을 유지한 중립 사건 또는 원인별 사건으로 바꾸고 한국어·영어 기록 회귀가 필요하다.

## 2. 종료와 실제 Sleep의 경계

- **원복 첫 실패:** [320](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherHelper/Helper+LidExecution.swift:320)에서 사건을 `consumed / restoreUnverified`로 끝낸다. [409](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherHelper/Helper+LidExecution.swift:409)의30초 재시도는 원복만 한다. [회귀:646](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/scripts/test-redesign-helper.py:646)는 나중에 원복이 성공해도 Sleep0회를 명시한다. 코드와 기존 정책이 일치하는 의도된 동작이며 새 실행 버그로 단정하지 않는다. 다만 최초 요구인 “분리 후 실제 Sleep”의 예외다.
- **배터리 예외 만료:** 권한을 없애고 원복하며 새로운 Sleep 사건은 만들지 않는다. [회귀:575](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/scripts/test-redesign-helper.py:575)는 `ownsOverride=false`, `sleeps==0`을 확인한다. 실제 닫힌 Mac이 이후 잠드는지는 OS·주변기기·다른 요청과 함께 관측해야 한다.
- **GUI 종료가 분리보다 앞섬:** [disconnectApp:168](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherHelper/Helper+Ownership.swift:168)이 lease를 먼저 지운다. 종료된 GUI의 권한으로 새 Sleep을 하지 않는 정책이다. 정상 종료와 정상 분리는 각각 검증됐지만 이 순서 경합의 직접 회귀는 검토 범위에서 발견하지 못했다.

재시도 정책을 바꿀 때는 다른 사용자·새 수동 배터리 예외·덮개 열기·전원 재연결·새 부팅·만료된 권한을 먼저 제외해야 한다. 오래된 사건을 그대로 반복하는 변경은 제안하지 않는다.

## 3. 사용성 공백

- 실제 메뉴는 [TetherPanel.swift:72](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/Tether/Panel/TetherPanel.swift:72)에서 `WorkSessionStatus`→`WorkSessionHeading`을 표시한다. `DisplaySleepNotice`·`ClamshellLockNotice`가 들어 있는 `StateModule`은 현재 Sources/Tests에서 생성 참조가 없다. 잠금 정책은 [SystemPage:68](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/Tether/Settings/SystemPage.swift:68)의 접힌 진단 안에 있다. 관련 예외가 있을 때만 메뉴 상태 아래 한 줄과 점검 링크를 두는 것이 최소안이다.
- [ActivityReviewView:248](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/Tether/Settings/ActivityReviewView.swift:248)는 조정할 옵션과 앱별 가이드를 “기술 정보” 안에 둔다. 해결에 필요한 짧은 안내는 기본 행에, PID·종류·경로는 접힌 상세에 두는 것이 낫다.

이 내용은 코드로 확인한 배치·정보 구조다. 실제 픽셀·잘림·키보드 동작 합격을 뜻하지 않는다.

## 4. 업데이트와 문서

최신 자동 결과는 `native-sparkle`, `previous-helper-upgrade`를 미실시로 기록했다. 기존48개 이관 검사는 실제 배포 helper 바이너리를 제공하는 추가10개 시나리오와 다르다([test-upgrade.py:526](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/scripts/test-upgrade.py:526)). 이전53→54 결과를55 결과로 확대하지 않는다.

Sparkle 합성 번들은 실제 앱을 재실행하지 않으므로 다운로드·GUI 재실행·기존 사용자 설정 보존까지 증명하지 않는다. 최종 이전 배포판→새 배포판은 사용자가 정한 마지막 단계에서 확인한다.

후보55는 [Info.plist:67](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Resources/Info.plist:67)의beta1이다. 저장된stable 선택을 보존하는 [채널 정책](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/Sources/TetherCore/Policy/UpdatePolicy.swift:7)에서는 베타가 보이지 않는 것이 정상이다. 배포 전에 대상 채널을 명시해야 한다.

[PRODUCT-SPEC:3](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/docs/PRODUCT-SPEC.ko.md:3)의 설치본53 표기와 [AUTOMATED-TESTING:28](/Users/jukqaz/dev/codex-chat/2026-09-28/d/work/tether/docs/AUTOMATED-TESTING.ko.md:28)의 runner 회귀13개 표기는 현재 기록과 다르다. 기능 정의 문서에 변동하는 설치 상태를 반복해 쓰기보다 [현재 검증 체크리스트](VALIDATION-CHECKLIST.ko.md)를 참조하는 편이 혼선을 줄인다.

## 5. 공식 자료와 제품 한계

Apple의 [일반 idle-sleep 방지 API](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)는 덮개 닫힘·수동 잠자기·저전력 같은 다른 Sleep 이유까지 막는 기능이 아니다. [공식 외장 화면 안내](https://support.apple.com/en-us/102501)는 닫힌 노트북에서 전원·외장 키보드/마우스를 확인하도록 한다. 따라서 Tether의 외장 화면 없는 덮개 유지와 네이티브 외장 화면 모드를 같은 지원 근거로 취급하지 않는다.

[Apple 잠금 화면 정책](https://support.apple.com/en-ie/guide/mac-help/mchlp2270/27/mac/27)은 화면 보호기/화면 꺼짐 이후 암호 요구를 별도로 다룬다. 현재 Tether는 이 정책을 읽고 안내하며 “닫혀도 무잠금” 옵션을 보장하지 않는다. 이는 실제 잠금/원격 시험을 해도 모든 OS 정책에서 자동 해결되는 기능은 아니다.

[Apple 온도 안내](https://support.apple.com/en-la/102336)의 주변 온도·통풍 권고는 앱의OS thermal state와 다르다. 배터리2시간은 사용자 선택 상한이며 안전 사용 시간이나 기기 수명 보장이 아니다. 새로운 임의 온도 임계값·타사 앱 자동 종료·보안 정책 자동 완화 기능은 이번 보완 대상으로 제안하지 않는다.

## 다음 작업 권장 순서

기록 오류 수정과 원인별 회귀 → 종료 실패/만료/경합의 정책 결정 및 격리 회귀 → 상황별 메뉴·해결 안내 정리 → 인증 이후 실제UI/설치/물리 인수 → 마지막 실제 업데이트 검증.
