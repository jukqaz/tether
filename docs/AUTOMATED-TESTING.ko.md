# Tether 자동 검증 실행

## 전원·배터리 상세 검증 · 2026-11-05

- `PowerBatteryReadingTests`: 단위·부호·누락·ETA·어댑터 조회와 실제 미연결 구분, read-only 수집 smoke. 실제 수집 검사는 한 번의 조회와 유효성 확인이며 센서 보정 정확도나 물리 전원 전환을 증명하지 않는다.
- `PowerBatteryMonitorTests`: 숨김 시 무수집, 여러 패널의 조회 공유, 늦은 결과 폐기, 전원·깨움 invalidation, 10초 신선도, 조회 실패, fixture 격리, 현재 요청 ID·기한·저장 설정 불변.
- `PowerBatteryPresentationTests`: 한국어·영어의 독립된 배터리/충전기 의미, `0`과 누락, AC 방전, 작은 전력·긴 수치, 재조회·오래된 값 문구.
- 새 native UI 경로는 `testPowerBatteryDetailsKoreanLight`, `testPowerBatteryDetailsEnglishDark`, `testPowerBatteryExceptionsAndDesktop`다. 실제 MenuBarExtra에서 접힘/펼침, 우측 수치·영문 폭, 스크롤 끝·고정 하단 조작, 예외 문구와 데스크톱 생략을 확인한다. 메모리 fixture가 실제 collector를 호출하지 않았는지도 확인한다.
- private 번들의 native 화면 검사·예시 데이터와 설치본·실제 물리 잠자기 시험은 구분한다. 설치·배포·OS 잠금/전원 설정 변경 없이 실행한다. 실패나 차단 실행을 통과 개수에 합산하지 않는다.

전체 Swift 회귀에는 임시 Unix 소켓의 bind/listen 권한이 필요하다. 실행 환경이 AF_UNIX bind를 `EPERM`으로 거절하면 해당 IPC 실패와 이를 허용한 후속 검증을 별도로 기록한다. 제품의 endpoint 검증이나 권한 규칙을 완화해 테스트를 통과시키지 않는다.

## 같은 Mac을 쓰는 채팅 간 UI 제어 · 2026-11-04

동시 작업 중에는 Computer Use, XCTest, 테스트 앱 실행·활성화, 창을 띄우는 렌더를 한 작업만 수행한다. 터미널 빌드·정적 검사·전면 창을 바꾸지 않는 격리 검사는 병행할 수 있다. 현재 Mac의 공유 도구는 `/private/tmp/codex-cua-jukqaz/ui_lease.py`이며 제품이나 CI의 의존성은 아니다.

상대 작업과 순서를 맞춘 뒤 `acquire`로 소유권을 얻고, 각 UI 실행 묶음 직전 자신의 owner/token으로 `check`한다. 실행 중에는 `renew`하며, 기한이 지나도 다른 작업의 소유권을 탈취하거나 앱을 종료하지 않는다. 실제 UI 실행과 자신의 테스트 앱 종료를 확인한 뒤 `release`하고 상대 채팅에 반납을 알린다. 도구·소유권을 확인하지 못하면 새 UI 실행을 시작하지 않는다.

이번 잔여 검사에는 `.build/verification/native-ui-remaining-20261104/run-owned-ui.py`를 사용한다. 이 실행 경로는 XCTest 시작 전에 소유권을 갱신·확인하고, 실행 중 120초마다 갱신한다. `*-lease-checks.json`에 토큰을 제외한 확인 결과를 남긴다. 설치본·전원 설정·다른 앱은 변경하지 않는다. 다른 창이 검사 영역을 가린 캡처는 해당 UI의 정상·결함 증거와 구분하고, 제어권이 확보된 조건에서 해당 실패만 다시 검증한다.

## P0 구현 후보 검증 · 2026-10-21

현재 P0 결과는 [구현·검증 보고서](../../../outputs/tether-p0-implementation-20261021/RESULT.ko.md)에 연결한다. 아래 2026-10-16 결과는 과거 후보의 근거이며 현재 합격으로 일괄 승계하지 않는다.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p0-module-cache" \
  python3 scripts/test-p0-automated.py --out .build/verification/p0-<이번실행>
```

이 실행기는 기본적으로 실제 OS assertion 검사를 끄고 소스 회귀와 검토한 34개 격리 단계를 실행한다. 출력 디렉터리는 새로 만들고, 단계별 명령·원본 로그·실행물/입력 해시·실행 중 변경·설치본 불변 여부를 남긴다. `physical-*` 단계도 모의 로그·기록기 검사이며 물리 합격을 뜻하지 않는다. `--swift-filter`나 `--only`로 좁힌 실행은 선택 범위를 그대로 기록한다. 전체 실행이 실패했으면 후속 통과 범위와 재사용 입력을 명시하며 한 번의 전체 통과로 표현하지 않는다.

실제 IOKit 시험은 별도로 `TETHER_RUN_LIVE_ASSERTION_TESTS=1`과 명시적 테스트 필터를 사용한다. 시험이 소유한 유한 일반/화면 요청의 만료·해제만 검사하며 실제 Sleep이나 전역 설정을 변경하지 않는다. UI 시험은 아래의 private 복제본 경로를 쓴다. 소스·격리·IOKit·native UI·설치·물리 근거를 각각 판정한다.

2026-10-16 과거 기록 · 후보58/v4 · macOS26 이상 / Apple Silicon · 일반 사용자 권한으로 실행한다.

후보58의 [최종49단계](../../tether/.build/verification/v4-implementation-20261015/automated-accepted-v4/summary.json)는 통과·실행 중 소스 변경0이다. Swift1,127개 중 기본 실행에서 필요한 패키지 경로가 없던 CLI2개는 패키지 선택 실행에서 보완했다. 후속 private 관측·접근성 메타데이터 수정 뒤 전원 정책·도우미·CLI의 동일성을 별도로 대조했다. 실제 UI는 메뉴1/1과 나머지23개 중14개가 통과해 **고유15/24 경로 통과**다. 수정9개 재시도는 OS 잠금 때문에 앱 활성화가 실패해 중단했으며 통과로 세지 않는다. 정적34장·소스·격리 IPC·실제 UI·설치/물리의 근거는 [v4 구현·검증 결과](IMPLEMENTATION-V4-20261015.ko.md)로 구분한다. 과거57의 설치·UI18개 결과는 현재 후보의 합격으로 이월하지 않는다.

```sh
python3 scripts/test-automated.py --native-expiry
```

이 명령은 현재 소스를 빌드하고 소스 전체 검사, 작성자·복구·설치·이관·충돌의 격리 통합 검사, release 앱 패키지, 패키지의 v3 실행기·v4 추가 회귀·격리 앱/CLI 연결, 최소 OS·서명·입력 제한과 정지한 일반 실행기의 유한 OS 요청을 확인한다. 결과와 단계별 로그는 저장소 `.build/verification/automated-*`에 저장한다. 실패 단계·실행 중 소스 변경을 합격으로 표시하지 않는다.

도우미·설치 시험은 모의 관측과 임시 설치 루트를 사용한다. production 전원 설정 변경, 실제 잠자기, `/Applications` 교체, 관리자 인증은 실행하지 않는다. native idle 시험은 자신이 만든 일반 사용자 자식과 유한 `caffeinate` 요청만 종료한다. 이전 v1/v2 호환 시험과 현재 v3 실행 시험을 구별한다.

## 실제 macOS UI 자동화

전체 검증 실행기의 패키지 빌드가 끝난 뒤 별도로 실행한다. 동일한 출력 디렉터리를 덮어쓰지 않는다.

```sh
python3 scripts/test-ui-native.py --app build/Tether.app \
  --output .build/verification/native-ui-<이번실행>
```

Xcode의 `XCUIApplication`으로 실제 `Settings`와 `MenuBarExtra(.window)` Scene을 검사한다. 한국어·영어 제목의 공간과 겹침, 항목 클릭 후 페이지 전환, 최소 창 크기·닫기·재열기, 수동·자동·모두 일시 중지의 범위, 시간 프리셋의 실제 항목·선택 저장·Escape, 데스크탑에서 불필요한 선택 숨김, 열 보호와 긴 오류의 조작 도달성을 검증한다. 현재 최소 콘텐츠560×480pt와 native 창 프레임을 관측하고 실제 테두리 드래그·재열기를 검사한다. 크기 변화가 없으면 resize를 통과시키지 않는다. 본문 최소 높이와 native 제목·툴바를 포함한 창 프레임을 구분한다. PNG 생성 여부만 확인하던 SwiftPM 렌더 검사는 별도의 배치 smoke test다.

원본 앱의 실행 파일을 실행마다 고유한 private ID `io.github.jukqaz.tether.ui-tests.<32자리 UUID>`로 복사한다. private ID·Info marker·명시 환경변수가 모두 있어야 메모리 설정과 모의 assertion을 사용하며, private ID에서 조건이 빠지면 종료한다. 실제 실행한 Bundle ID와 실행 파일 경로를 현재 DerivedData 후보와 대조한다. 설치 앱의 ID에서는 이 경로에 진입할 수 없다. 실제 전원 설정·root 도우미·로그인 항목·업데이트 피드는 변경하지 않는다. 초기 창은 시험 전용이며 제품 UI에 표시되지 않는다.

모의 관측은 private 경로의 단일 common-mode 타이머로만 갱신하며 생산 경로의 관측 신선도 제한은 그대로 둔다. 버튼 부모 식별자가 자식 식별자를 덮지 않는지 실제 AX로 확인한다. 펼침 후 식별자가 Group으로 이동할 수 있으므로 상태는 고유한 native DisclosureTriangle에서 읽는다. 키보드 탭 검사는 포커스 이동과 Space로 선택한 페이지를 구분한다. 이 조건을 고쳐도 실제 재실행 전에는 통과로 표시하지 않는다. 화면이 잠겨 앱을 활성화할 수 없으면 해당 실행의 실패·중단 원본과 읽기 전용 잠금 근거를 보존하고 같은 조건의 반복 실행을 멈춘다.

시험 전용 앱은 다른 앱의 Services 메뉴를 제외한다. 전체 AX 조회가 AppKit의 Services/Data Detectors 초기화를 유발해 OS 내부 QoS 경고를 만드는 경로를 분리하기 위해서다. 제품 앱의 Services 메뉴는 유지한다. 따라서 이 검사는 타사 Services 연동을 검증하지 않으며, 설정과 MenuBarExtra의 실제 컴포넌트·모델 연결에 한정된다. [Apple의 Services 명령 그룹](https://developer.apple.com/documentation/swiftui/commandgroupplacement/systemservices)을 사용한다.

`result.json`과 `NativeUI.xcresult`에 실제 실행 결과, 앱·테스트 코드 해시, 실패한 접근성 트리와 해당 창의 스크린샷을 남긴다. `xcodebuild` 성공, xcresult 전체 통과, 실행 항목 존재, skip·expected failure·런타임 경고 0을 모두 만족해야 통과다. SwiftUI의 `Publishing changes from within view updates`도 실패로 판정하며 경고 원문과 로그를 보존한다. 판정기의 허위 통과와 후보 혼선을 막는 `scripts/test-ui-native-runner.py`의21개 회귀 검사는 기본 일괄 실행에 포함한다. 권한 제한·잠금·필수 요소 누락·시간 초과·prepare-only를 통과로 처리하지 않는다. 모든 실패가 동일한 image creation 오류인 완전한 보고서는 `blocked`로 구분하며 원본 실패 수와 실제 실행 시작 여부를 유지한다. 일반 assertion·crash·런타임 오류가 섞이면 `failed`를 유지한다. 캡처를 생략해 시각 검증을 통과시키지 않는다. OS의 UI 자동화 권한이 필요하면 사용자가 정상 인증 경로로 허용해야 하며 시험기가 보안 설정을 자동 변경하지 않는다. 다른 앱이 앞에 떠 있으면 설정 조작 직전에 시험 앱을 활성화한다.

최소 창 검사는 현재 Settings 창의 식별자·창 번호·활성/키 상태·실제 frame·본문·min/max·resizable 속성을 읽기 전용 fixture JSON으로 기록한다. 모델과 독립적으로 갱신하며 실제 창 프레임을 강제로 설정하지 않는다. 제목막대로 해당 창을 활성화한 뒤 native 테두리를 드래그하고, 일반 설정 재열기의 마지막 페이지 보존과 경고 해결 링크의 지정 목적지를 각각 확인한다.

시간 선택은 native 메뉴의 15분·30분·1시간·2시간으로 검사한다. 직접 입력 항목·전용 편집창이 없고 무제한은 전원 연결 중에만 표시되는지 확인한다. 수동 시간은 메뉴바에만 있고 설정에 시간/배터리 승계 선택이 중복되지 않음, 선택만으로 시작되지 않음, 과거 임의 시간 보존·명시 선택 뒤 임시 항목 제거를 별도 검사한다. 메뉴는 Escape로 닫으며 시스템 입력 소스를 바꾸지 않는다.

각 실제 캡처에 같은 창의 leaf·native parent·스크롤 viewport 프레임을 JSON으로 남긴다. 유형별 AX 수집에서 읽지 못한 요소는 `unmeasuredElements`로 기록하며, 수집이 `partial`이면 배치·조작 통과를 보류한다. 창 프레임이 바뀌거나 AX의 부모 관계가 불명확한 경우 단정하지 않는다. [UI 품질 측정](DESIGN-QUALITY.ko.md)은 이 자료와 같은 GUI의 실행 결과·OCR를 대조해 확인 점수와 미측정 범위를 출력한다. 평가기26개와 자료 준비16개 회귀를 기본 일괄 실행에 포함한다. 위 실행기 판정21개 회귀와 별도로 집계한다. 이 회귀는 실제 화면이 좋아졌다는 증거가 아니며, 새 native 전후 캡처와 별도로 기록한다.

2026-10-12 후속 검사는 기능 실행과 전체 배치 자료 수집을 분리했다. 기존 전체 수집 실행은1,200초에 중단돼 전체 통과가 아니다. 별도 generated [기능 실행](../../tether/.build/verification/end-recovery-20261012/native-ui-functional-all/result.json)은 screenshot·raw AX·상태·모든 원래 assertion과 핵심 배치 검사를 유지했고, bulk 수집만 `unavailable`과 이유를 남겼다. **18실행/12통과/6실패**이며 실패6건은 설정 탐색 직전의SecurityAgent 인증창 간섭과 함께 보존한다. 기능 결과·캡처 생성·전체 정량 배치 인수는 별도 판정이며, 이 자료로 전 요소 디자인 점수를 통과시키지 않는다. 내장 화면으로 private 창을 옮긴 generated gesture는 해당 Mac의 재검사 조건이며 제품 창 정책을 수정한 것이 아니다.

인증 완료 뒤에는 기존 같은 실행물을 재빌드하지 않고 `test-without-building`으로 실패6경로만 다시 검사해 **6/6 통과**했다. 따라서 같은 제품/원본 테스트/생성 테스트/private fixture에서 **18개 고유 기능 경로**가 통과한 근거를 얻었다. [재시험 결과](../../tether/.build/verification/end-recovery-20261012/native-ui-reuse-authorized-six/result.json)와 전체 실행물의before/after fingerprint를 보존하며, 이전 일괄 실행의실패를 덮어쓰거나 새18/18 실행으로 표시하지 않는다.

실행물을 재사용할 때는 현재 제품·원본 테스트·generated 테스트·최종 signed fixture 해시와 private BundleID/expected path가 기록과 같아야 한다. before/after 실행물 fingerprint도 같아야 하며, 다른 소스를 지난 바이너리로 시험하지 않는다. 재사용은 [Apple의 정상 XCTest 흐름](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)이며 기존 권한 정책을 변경하지 않는다. 이 재시험은같은 입력의 부분 경로 검증에 사용했다. 새로운 코드나 서명이 만들어진 실행의 인증 상태까지 보장하지 않는다. `DevToolsSecurity`의 debugger 정책과 UI Automation 인증은 별개로 기록한다.

실행 중 소스나 시험 코드를 바꾸지 않는다. 실제 센서는 모의값이므로 이 검사로 물리 덮개·실제 잠자기·원격 입력·패널 소비 전력을 입증하지 않는다.

업데이트 도구와 이전 바이너리가 준비된 환경에서는 다음 검사도 실행한다.

```sh
python3 scripts/test-automated.py --native-expiry \
  --sparkle-cli "$SPARKLE_TEST_CLI" --sparkle-tools "$SPARKLE_TOOLS_DIR" \
  --previous-helper "49:$TETHER_PREVIOUS_49" \
  --previous-helper "50:$TETHER_PREVIOUS_50"
```

- `SPARKLE_TOOLS_DIR`은 `bin/sign_update`를 포함하는 **도구 루트**다. `bin` 디렉터리 자체를 전달하지 않는다. 현재 SwiftPM 의존성의 예시는 `.build/artifacts/sparkle/Sparkle`이며, 실제 `bin/sign_update` 존재와 실행 권한을 먼저 확인한다.
- Sparkle CLI는 고정된 현재 Sparkle 의존성의 공식 소스로 빌드한 시험 도구를 사용한다. 업데이트 시험은 임시 키·localhost 피드·실행하지 않는 가짜 앱만 교체한다. 실제 배포 키를 읽지 않는다.
- 이전 바이너리는 보존한 실제 앱 패키지의 도우미 복사본이다. 정상 교체·기존 OFF 보존·임시 요청 미부활·교체 실패 원복·정지한 이전 도우미를 시험한다. 실행 중인 이전 도우미의 daemon 등록 파일이 빠진 경우도 성공·watchdog 실패·bootstrap 실패로 나누어 시험한다. 같은 GUI가 살아 있는 동안의 기존 AC 자동 선택 보존과, 종료된 임시 타이머 부활을 구별하며 새 v3 handoff 뒤 권한 없는 자체 유지가 해제되는지 확인한다. 이전 바이너리를 production 경로에서 실행하지 않는다.
- 도구나 이전 바이너리를 지정하지 않은 검사는 `optionalGatesNotRun`에 남긴다. 생략한 검사를 실행한 것처럼 표시하지 않는다.
- CI에도 패키지의 v3 전원 분리·보호 실행과 native 유한 기한 검사를 연결했다. 로컬 실행 통과와 원격 GitHub Actions 실행 통과는 별개다.

아래 v1/v2 타이머 재생은 구제품의 역사적 호환 도구다. 배터리 자동·승계 등 폐기 계약을 포함하므로 현재 v4 인수에 사용하지 않는다. 현행 시작/종료 거절과 이관 검증은 기본 일괄 실행의 work-session/service/upgrade를 따른다.

```sh
python3 scripts/test-manual-scenarios.py \
  --helper build/Tether.app/Contents/Resources/tether-helper \
  --out .build/verification/<이번실행>/legacy-wallclock-scenarios
```

이 명령의 11개 사례도 private dry-run 도우미에 전원·덮개를 모의 입력한다. 실제 시간이 흐르는 타이머 검증이며, 현재 v3 실행이나 물리 Sleep 증거로 합산하지 않는다. 전후 production control·실행 상태·`pmset -g custom` 보존을 결과에 남긴다.

최종 `summary.json`의 `completed`, `passed`, `sourceChangedDuringRun`, `optionalGatesNotRun`과 각 Swift 단계의 `swiftSkipped`를 함께 확인한다. 프로세스 종료 코드가 정상이더라도 환경 때문에 skip한 항목은 통과로 기록하지 않는다. 검사 수는 중복 실행을 포함하므로 고유 기능 개수나 제품 합격률이 아니다.

v3 종료·복구의 실제 시간 타이머는 최종 패키지 도우미로 별도 확인한다. IPC 조회가 타이머 실행을 대신하지 않으며 센서·OS 쓰기만 모의 처리한다.

```sh
TETHER_TEST_HELPER=build/Tether.app/Contents/Resources/tether-helper \
  python3 scripts/test-lid-recovery-timers.py
```

직접 배터리 수동 마감·종료 승인창30초 안의 원복 재시도·배터리 허가 고정 마감의 실시간3사례를 별도 검사한다. 짧은 wire 마감은 시험용이며 UI의 최소60초/고정 시간 선택 검증과 구분한다. 실제 덮개·OS Sleep/Wake·잠금과 원격 입력·관리자 승인에는 [v4 설치·물리 체크리스트](V4-PHYSICAL-CHECKLIST.ko.md)를 사용한다. API 성공·검은 화면·표본 공백만으로 실제 잠자기를 합격시키지 않는다.

개발용 [물리 시험 기록](PHYSICAL-TEST-LOGGING.ko.md)의 수집·분석·관측 CLI 회귀 검사도 통합 실행기에 포함한다. 실제 물리 시험은 사용자의 조작을 연속 기록한 뒤 보관 파일로 판정하며, 자동 회귀 검사의 모의 센서 결과와 구분한다.
