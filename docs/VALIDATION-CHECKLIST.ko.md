# Tether 검증·직접 시험·결정 체크리스트

> **문서 분류 · 2026-10-21: 역사 자료 — 과거 후보별 검증 결과 모음.** 본문은 당시의 선택·근거로 보존한다. 현재 범위·기본값은 [기능명세서](PRODUCT-SPEC.ko.md), 새 수락 조건은 [현행 검증표](V5-VALIDATION-CHECKLIST.ko.md)를 따른다. 아래의 ‘현재·최신·최종’과 합격 수는 당시 대상에 한정하며 현재 전체 기능의 완료를 뜻하지 않는다.

차기 설계의 수락 항목은 [V5 체크리스트](archive/2026-10-21-spec-cleanup/V5-VALIDATION-CHECKLIST.ko.md)로 분리했다. 아래는 후보58의 기존 검증 기록이며 새 기능 통과로 이월하지 않는다.

**차기 조사 범위 변경 · 2026-10-16:** 사용자는 기존 유지 규칙을 새 조사·설계의 고정 제약에서 잠시 제외했다. [기능 수집·통합안](FEATURE-SYNTHESIS-20261016.ko.md)의 새 후보는 아래 후보58의 검증 통과를 승계하지 않는다. 이 체크리스트의 AC-only·120분·분리 전체 종료 검사는 현재 후보58을 설명하며 새 선택 정책의 검증은 새 계약 확정 뒤 추가한다.

## v4 인수 게이트 · 2026-10-16 · 후보58 자동 회귀 완료 / UI 재검증·전체 인수 미완료

최신 기준은 [기능 명세 v4](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md)다. 사용자 승인으로 후보58을 구현했고 **최종 자동49단계 통과·실행 중 소스 변경0**을 확인했다. 당시 동일 제품·패키지의 후속 자율 실시간 타이머3사례도 통과했다. 이후 UI 시험 경로·식별자만 수정했으며 전원 정책·도우미·CLI의 동일성을 대조했다. 상세 수·해시·실패 원본·정적34장과 한계는 [v4 구현·검증 결과](IMPLEMENTATION-V4-20261015.ko.md)를 따른다. 실제 UI는 **고유15/24 경로 통과**, 수정9개 재검증은 Mac 잠금으로 중단돼 미완료다. 아래 체크는 해당 층의 근거만 의미하며 G1~G4 전체 인수를 완료한 것은 아니다. 설치·물리 시험은 사용자 요청으로 보류했다. 과거 버전 수치는 이월하지 않는다.

| 근거 층 | 확인할 범위 | 대신할 수 없는 근거 |
|---|---|---|
| 자동 회귀 | 순수 정책·가짜 시계·모의 전원/센서·격리 IPC·실패 주입·시험용 호출 계수 | 실제 덮개·케이블·OS Sleep·설치본 동작·유휴 성능을 증명하지 않음 |
| 실제 native·설치 | 승인된 시안 적용 후 실제 앱 조작, 대상 빌드/설치본·도우미 식별, 설치/업데이트/종료 결과 | 화면·명령 ACK·설치 파일 존재만으로 실제 Sleep·원격 사용 가능을 증명하지 않음 |
| 필수 물리 | 실제 MacBook의 덮개·AC 분리/재연결과 OS Sleep/Wake, 배터리 수동의 전원 전이 | Fixture·모의 센서·dry-run·로그 공백을 물리 통과로 사용하지 않음 |

각 근거에는 대상 버전·소스/패키지/실행 식별·호스트 OS/기기·설정·관측 시각·실행/미실행 범위를 남긴다. 같은 근거를 여러 게이트에 연결할 수 있으나 통과 수를 중복 합산하지 않는다. 물리 시험은 사용자 방침대로 별도 단계에서 수행한다.

- [x] **정적 화면 · 검수:** 메뉴·설정3탭·펼침·끝 스크롤·밝은 외관/영어 등34장을 검수했다. native Glass/입력·설치본 검증은 아니다. 동적 복원·예약·첫 설정의 모든 실제 입력 상태는 미검증이다.
- [x] **private native UI · 고유15경로 확인:** 메뉴 시작/종료·연장·자동/중지 범위, 한국어/영어 최소 창·스크롤·재열기, 포인터 포커스, 배터리/데스크톱·열 보호 등의 실제 조작을 확인했다. 한 번의24/24 실행이 아니다. [경로별 원본](../.build/verification/v4-implementation-20261015/native-ui-acceptance-summary.json).
- [ ] **private native UI · 수정9경로 재검증:** 펼침 상태·키보드 탭 선택·진단 기록·예행연습·첫 설정·긴 경고의 수정 후 실제 조작. 최신 시도는 OS 잠금으로 첫 앱 활성화가 실패해 중단했다. 정상 잠금 해제 후 이9개만 재실행한다. 설치본·물리 시험과는 별개다.

### 편의 옵션 확장 · 2026-10-16 · 설계 범위, 아직 추가 구현하지 않음

사용자는 **핵심 규칙 유지·나머지 옵션 확장**을 선택했다. [v4 §14](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#14-편의-옵션-확장-요구--2026-10-16)의 O-01~08은 후속 구현/검증 범위이며 위49단계·UI15경로에 포함해 세지 않는다. 기존 AC 분리 전 요청 종료·배터리 최초120분은 그대로다.

- [ ] O-01~03: 다음 수동의 화면/덮개/유휴 선택, 대상 선택기, 프리셋 복제/정렬/선택 전송. 전역 상한·현재 요청/마감·기존 선택/중지·권한 경계 보존.
- [ ] O-04~05: 수동 만료/연결 작업 종료 알림 분리, 끔/1/5/10분 전 예고·액션 선택. 짧은 수동·선행 시간 변경·연장·옛 알림·상한 근처·권한 거부를 확인. 모든 알림 OFF에서도 보호/원복 수행.
- [ ] O-06~08: 연장/기한/설정 단축키, 자주 쓰는 시간 표시/정렬, 메뉴 기본/상세·짧은 시간/툴팁. 충돌·고정 폭·한국어/영어·긴 이름·키보드/포인터·최소 창/끝 스크롤·밝은/어두운 외관 확인.
- [ ] 새 필드 없는 이전 설정을 이관해 현행 기본값·선택·실행 중 요청 보존. 설정 되돌리기/가져오기로 만료 요청·원복 허가·보호 중지를 재생하지 않음. 미지원 미디어/다운로드 조건을 실험 ON만으로 실행하지 않음.

### V4-G1 · 전원 분리 신뢰성

연결: [§3 전원·세션](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#3-전원세션-계약), [§4 종료 동작](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#4-종료-동작과-우선순위), [§7 화면·잠금·원격·보호](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#7-화면잠금원격보호), [§12 기준안·추천값](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#12-채택한-기준안과-남은-결정). 기존 인수 ID: `V4-03~05`, `V4-08~10`, `V4-15~16`, `V4-20`, `V4-22~24`, `V4-27`, `V4-33`.

- [x] **자동 회귀 · 통과:** 닫힌 AC→배터리에서 기존 자동·수동·작업 이벤트 요청을 모두 소비한다. GUI/helper 관측 순서·연장/마감·센서 실패·늦은 ACK/heartbeat가 겹쳐도 기존 요청을 살리지 않는다. 배터리 수동→AC→재분리도 종료하고 열린 분리에는 강제 Sleep을 만들지 않는다.
- [x] **자동 회귀 · 통과:** 요청 소비, Tether 자체 원복, Sleep 요청 시도, 실제 Sleep 관측을 서로 다른 결과로 기록한다. 타사 유휴 요청 존재만으로 선택된 닫힌 분리 Sleep을 생략하지 않으며, 미소유 전역값·타사 assertion은 변경하지 않는다. 원복/권한 미확인·실패를 원복 완료나 Sleep 성공으로 바꾸지 않는다.
- [ ] **실제 native·설치 · 미실행:** 대상 앱·도우미에서 유지 출처/실행 상태·분리 결과·원복 제한을 현재 근거와 맞춰 확인한다. 재연결에서는 허용된 AC 자동만 새로 평가하고, 남은 시간이 있던 수동·소비한 작업 이벤트는 부활하지 않는다.
- [ ] **필수 물리 · 미실행:** 실제 닫힌 MacBook에서 AC 분리→기존 요청 종료→자체 원복→실제 OS Sleep/Wake를 각각 확인한다. 재연결의 수동 비복원과 배터리 수동→AC→재분리, 열린 분리도 구별한다. 실패/미확인은 그대로 남기며 명령 성공·검은 화면만으로 실제 Sleep 통과를 선언하지 않는다.

### V4-G2 · 조작 결과 명확성

연결: [§3 요청·조작 범위](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#3-전원세션-계약), [§7 허용·실행 범위](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#7-화면잠금원격보호), [§8 알림·상태·설정](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#8-알림상태설정), [§9 UI](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#9-ui와-사용성-요구), [§12 기준안](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#12-채택한-기준안과-남은-결정). 기존 인수 ID: `V4-01~02`, `V4-10`, `V4-19`, `V4-21~22`, `V4-24~25`, `V4-28~30`.

- [x] **자동 회귀 · 통과:** 자동+수동에서 ‘수동만 종료’는 자동을, ‘자동 OFF’는 수동을 보존하며 ‘모두 일시 중지’는 기존 요청을 모두 끝낸다. 재개는 종료한 수동의 복원이 아니다. 명령 재전송은 원래 결과와 현재 요청 상태를 함께 반환하고 옛 승인·미확인·부분 적용을 현재 성공으로 표시하지 않는다.
- [ ] **실제 native·설치 · 미실행:** 메뉴·설정·CLI/Intent 등 해당 조작 뒤 추가 창 열기/수동 새로고침 없이 현재 결과가 반영되는지 확인한다. 수동만 종료/자동 OFF/모두 중지/재개의 범위를 구별하고 준비 중·거절·종료·남은 유지 이유를 현재 상태에 맞게 보여준다. ‘즉시 표시’는 명령 결과 반영을 뜻하며 OS 실행·Sleep의 즉시 완료 보장이 아니다.
- [x] **첫 설정 자동 회귀 · 통과:** AC 자동/덮개 허용의 독립4조합·수동 미시작·새 OFF 기본값·저장 실패의 기존 선택 보존을 source에서 확인했다. 실제 화면 입력·관리자 인증 결과는 아래와 별개다.
- [ ] **실제 native·설치 · 미실행:** 첫 설정에서 AC 자동 OFF/ON × 덮개 유지 허용 OFF/ON의 네 조합을 독립적으로 선택한다. 도우미 준비·인증 완료만으로 두 선택을 켜지 않으며, 전역 허용 ON/OFF·요청의 선택·현재 일반/화면/덮개 실행을 구별한다. MacBook의 필수 도우미 준비 완료와 실제 덮개 실행 확인을 나누고 필수 준비 전에는 첫 설정을 완료 처리하지 않는다. 데스크톱은 덮개 선택·도우미 설치 요구에서 제외한다. 새 설치 기본값과 기존 사용자 선택 보존을 각각 확인한다.
- [ ] **물리 근거 연결 · 미실행:** G1의 실제 전원 전이/실행 근거와 화면의 현재 결과를 대조한다. 모의 화면의 조작 성공을 실제 분리 종료·원복·Sleep 증거로 재사용하지 않는다. 별도 물리 조작 없이 공유한 근거는 G1의 대상·시각을 명시한다.

### V4-G3 · 설치·업데이트·종료 일관성

연결: [§3 중지·수동 수명](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#3-전원세션-계약), [§4 종료·교체 수명](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#4-종료-동작과-우선순위), [§7 보호·도우미](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#7-화면잠금원격보호), [§8 설정·업데이트](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#8-알림상태설정), [§12 후속 계약](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#12-채택한-기준안과-남은-결정). 기존 인수 ID: `V4-10`, `V4-15~18`, `V4-22~25`, `V4-29`, `V4-33`, `V4-38~44`.

- [x] **자동 회귀 · 통과:** 설치/업데이트/가져오기/되돌리기에서 사용자 OFF·전체 중지·보호·화면 선택을 보존한다. 확인/다운로드/예약·교체 전 취소·인증 거절만으로 정상 요청을 끝내거나 자동 ON/보호 해제를 만들지 않는다. 실제 종료/교체·Sleep·소유자 변경 뒤에는 옛 수동/명령/설치 승인을 재생하지 않는다.
- [x] **자동 회귀 · 통과:** 정상 종료·강제 종료·구버전/연결 실패·원복 실패를 구별한다. Tether 소유 변경만 정리하고 원복 원본·미완료 저널을 보존하며 타사 상태를 덮어쓰지 않는다. 이전 실행기 정리가 확인되기 전 새 실행기를 겹쳐 실행하지 않는다.
- [ ] **실제 native·설치 · 미실행:** 실제 설치/업데이트의 승인·취소·인증 거절·교체 전후 앱/도우미 식별과 보존된 설정을 기록한다. 일반 종료/재실행에서도 현재 OFF·중지·보호와 자체 원복·타사 상태 보존·옛 수동 비복원을 확인한다. 인증창 표시나 새 앱 파일 존재를 설치 완료로 세지 않는다.
- [ ] **필수 물리 연결 · 미실행:** 실제 설치/교체한 대상에서 G1의 닫힌 분리·재연결 인수를 연결한다. 종료/교체가 실제 작업과 겹친 경우 자체 해제·원복과 OS 결과를 별도로 남기고, 이전 빌드의 물리/격리 기록으로 새 설치본을 통과시키지 않는다.

### V4-G4 · 앱 자체 가벼움

연결: [§3 기본 AC/자동 OFF](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#3-전원세션-계약), [§5 선택한 자동 조건](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#5-ac-자동-규칙과-프리셋), [§7 필요한 보호 관측](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#7-화면잠금원격보호), [§8 기록](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#8-알림상태설정), [§12 관측·기록 한도](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md#12-채택한-기준안과-남은-결정). 기존 인수 ID: `V4-23`, `V4-31`, `V4-34`, `V4-36~37`, `V4-42`.

- [x] **자동 회귀 · 통과:** 설정/진단 창을 닫은 기본 ‘AC 연결 동안’ 모드와 자동 OFF에서, 비활성 앱/CPU/전송량/일정/미디어/다운로드/AI 제공자의 **정기 감시 호출이 0**인지 시험용 계수로 확인한다. 공통 보호·실제 활성 수동의 필수 관측, 사용자가 요청한 상세 조회와 이벤트 등록까지 모두 0이라는 뜻은 아니다. 필요한 관측과 꺼진 고급 제공자의 정기 감시를 구별한다.
- [x] **자동 회귀 · 통과:** 같은 관측원은 공통 경로 하나에서 공유하고 화면 재열기·재접속·동일 ACK·재전송으로 중복 감시/갱신 루프를 만들지 않는다. 비활성화·종료 때 해당 등록/타이머를 정리한다. 인수를 위해 새 상주 모니터나 필요 없는 사용자 옵션을 제품에 추가하지 않는다.
- [x] **격리 저장 자동 회귀 · 통과:** §8/§12의 기록 한도를 대조한다. 현재 추천은 결정128개/72시간, 상세15/60/240분(기본15분·최대4시간), 도우미2MB+이전3개 회전, 설정 이력20건/30일/1MiB 중 먼저 도달한 한도다. 회전/저장 실패는 제한·누락으로 표시하고 미완료 원복 저널을 일반 로그 한도로 삭제하지 않는다. 정상 회전 때의 약8MB를 모든 실패 상황의 엄격한 상한으로 표시하지 않는다.
- [ ] **실제 native·설치 실측 · 미실행:** 대상 앱/도우미의 기본 AC·자동 OFF에서 유휴 CPU·메모리·로그 증가와 관측/갱신 횟수를 측정한다. 측정 기간·호스트·활성 기능·창/상세 기록 상태·시작/종료 값·비교 기준을 함께 남기고 반복 ACK·중복 감시·지속 증가의 원인을 구분한다. 임의 CPU/RAM 숫자나 가짜 효율 점수를 합격선으로 만들지 않는다.
- [ ] **실기기·필수 물리와의 분리 · 미실행:** 성능 측정은 실제 실행 근거이며 G1의 덮개·케이블·Sleep 인수를 대신하지 않는다. 승인된 실제 기기에서 수집한 유휴 자료를 연결하되 성능 수집 때문에 전원/잠금 정책·타사 상태를 바꾸거나 추가 물리 조작을 요구하지 않는다. 새 근거가 없는 상태에서 아래 과거 ACK/CPU 수치를 v4 실측값으로 재사용하지 않는다.

## 과거 구현·검증 기록 · v4 인수와 분리

이하 날짜별 원문과 완료/미완료 표시는 **당시 후보·설치본·격리 실행의 역사적 근거**로 보존한다. ‘최신’·‘현재’라는 표현도 해당 기록 날짜의 상태이며, 아래 체크 완료나 검사 수를 위 v4 게이트의 통과로 이월하지 않는다. 특히 과거 배터리 자동·승계 등 구정책 검증은 새 AC-only·분리 전체 종료 계약의 완료 증거가 아니다.

## 디자인 재설계 · 2026-10-13 · 격리 검증본

[결과와 실제 화면](../.build/verification/design-redesign-20261013/RESULT.ko.md)에 이번 변경·검증 범위를 분리했다. 아래 설치본57의 이전 검사 수에 합산하지 않는다.

- [x] 세 페이지를 native sidebar로 재구성하고 고정 제목·본문 읽기 열·기본 닫기 버튼을 정리했다. 메뉴는 상태·자동 조건·수동 시작의 우선순위와 그래파이트·블루 색을 통일했다.
- [x] 재열기 때 빈 툴바가 복원돼 제목이 사라지던 회귀 수정. native 창을 닫았다 `⌘,`로 다시 열어 제목·닫기 버튼을 확인하고, 재현된 host 상태를 소스 회귀에 추가했다.
- [x] 최종 관련 Swift UI 회귀35개·실패0. 판정 도구30개와 검증 provenance 도구17개도 통과했다. 전체 기능 suite의 새 실행으로 표시하지 않는다.
- [x] Computer Use에서 세 페이지·본문 스크롤·키보드 사이드바 이동·설정 재열기·수동 시작/종료와 자동 보존을 확인했다. 센서·유지 요청·설정 저장은 메모리 기반이며 실제 전원 설정을 바꾸지 않았다.
- [x] 최신 정적 캡처4개 생성: 밝은 외관, 최소760pt, 넓은1240pt, 메뉴. 정적 sidebar는 평면 대체이며 native Glass의 증거로 사용하지 않는다.
- [ ] 최신 전체18경로 native XCUITest 실행. 첫 시도는 automation mode 초기화에서 막혔고, 후속 프로젝트는 중간 실행물의 build-for-testing만 성공했다. Computer Use 확인을18/18 통과로 표시하지 않는다.
- [ ] native 가장자리 resize·최소 창의 전체 입력 인수. 이번 가장자리 drag에서는 크기 변화가 확인되지 않았으므로 최소 폭 정적 렌더·소스 회귀와 구분한다.
- [ ] 새 디자인의 실제 설치·production MenuBarExtra·macOS26 인수. 이번 요청에서는 설치본57·도우미를 교체하지 않았다.

전원·잠금 정책과 실제 물리 시험은 별도다. 아래의 배터리 ACK 반복 결함도 디자인 변경으로 해결됐다고 표시하지 않는다.

## 후속 실제 환경 발견 · 2026-10-12 · 배터리 수동 유지 ACK 반복

[읽기 전용 실환경 진단](../.build/verification/live-sleep-influences-20261012T133504Z/RESULT.ko.md)에서 동일 배터리 영수증 ACK가 재갱신을 부르는 루프를 확인했다. 실제203.466초에4,912회, 약24.14Hz다. 기존 자동·UI 통과 기록은 유지하되 이 경로는 기존 fixture에 영수증이 없어 검증되지 않았다.

- [x] 실제 유지 소유자·전원/잠금 정책·OS Sleep/Wake·실제 CPU/로그 증가를 대조했다. 타사 전원 앱의 지속 차단 요청은 이번 표본에서 관측되지 않았다.
- [ ] 동일 영수증 처리의 멱등성과 ACK 갱신 루프를 수정한다. 이번 요청은 진단이므로 코드·설치본 수정은 하지 않았다.
- [ ] 실제 영수증이 있는 ACK로 정상 갱신·중단·만료·전원 전환 회귀를 검증하고 로그 증가·CPU를 재측정한다.
- [ ] 닫힌 전원 분리 등 물리 인수는 사용자 요청대로 나중에 진행한다. 현재 발견을 타사 앱 문제나 기존 물리 실패 원인으로 단정하지 않는다.

## 최신 기록 · 2026-10-12 · 로그 권한 수정·설치본57

[빌드57 결과](../.build/verification/helper-log-permissions-20261012/RESULT.ko.md)와 [기계 판정](../.build/verification/helper-log-permissions-20261012/verification-summary.json)을 따른다. 아래56 기록은 당시 결과이며 이번 수에 합산하지 않는다.

- [x] root 전용0700 로그 폴더 때문에 일반 사용자 진단·수집이 실패하던 결함 수정. 설치 전에 폴더0755·활성/기존 회전 로그0644를 준비하며 root 쓰기 소유권·활성 inode·기존 내용을 보존한다. 전원 제어 기록의 권한은 넓히지 않는다.
- [x] 로그 권한 회귀13개: 기존700/600 복구·umask077 새 설치·실패 원복·심볼릭/하드 링크·FIFO·디렉터리·확장 ACL·위험한 부모 권한을 확인한다. 위험한 경로는 서비스 종료 전에 거부한다.
- [x] 전체 자동49단계 모두 통과. Swift1,043개·설치61사례·패키지 v3 도우미105사례·실제56→57 및55→57 격리 이관 각각10사례를 포함한다. 실제 유한 IOKit 만료와 localhost 합성 Sparkle도 통과했다. 포함된 수를 별도 합산하지 않는다.
- [x] 패키지 실제 시간 타이머3개와 이전 계약 호환11개 통과. 모의 센서·dry-run OS 쓰기이며 실제 Sleep 근거로 사용하지 않는다.
- [x] macOS 관리자 인증 뒤 실제 앱·root 도우미57 설치. 실행 GUI·도우미·복구 실행기·CLI·설치 스크립트 해시가 동결 후보와 일치하고 기존 설정13개를 보존했다.
- [x] 일반 사용자UID501의 직접 파일 읽기와 진단 보고서 포함 검증. `Helper log` 절의 실제140줄 모두 설치 로그와 일치한다. [권한 증거](../.build/verification/helper-log-permissions-20261012/normal-user-log-proof.json).
- [x] 1분 읽기 전용 수집 정상 종료. 활성 로그3회 읽기 성공·PermissionError0, 표본20개·공백/무결성 오류0. 회전 파일 부재와 실제 읽기 오류의 집계를 구분한다. 물리 조작은 없었다.
- [x] 후속 수집 집계 회귀38개 통과. 없는 선택 회전 파일은 실패로 세지 않고 활성 로그 부재·실제 권한 오류는 보존한다. 원본 JSONL과 물리 판정 불변을 확인했다.
- [x] native UI **18개 고유 경로 통과**. [후속1/1](../.build/verification/helper-log-permissions-20261012/native-ui57-focused-guarded-20261012T091448Z/RESULT.ko.md)과 기존17개의 실제 테스트 식별자를 대조했다. 한 번의18/18 실행으로 표시하지 않는다. 기존 인증된 Runner·57 실행물·원래 assertion을 유지했다.
- [x] 남은 한국어 메뉴·General/Safety/System 전환·하단 스크롤·절전 영향 모달·최종 상태 복귀 확인. fail·skip·expected failure·런타임 경고0이다. 전면 복귀3회는 첫 입력 전에 끝났으며 이후 약69초1,239개 표본에 다른 전면 앱이나 추가 복귀 요청이 없었다. 원본17/18·첫 focused0/1을 보존했고 시험용 Fixture·관측 프로세스를 정리했다. 제품 자체의 외부 포커스 방어·전체 배치 정량 통과는 주장하지 않는다.
- [ ] 실제 덮개·닫힌 전원 분리 Sleep/Wake·배터리 만료·원격 입력·외장 화면·macOS26 실물 인수. 사용자 요청으로 나중에 진행한다. 공개 업데이트는 마지막 단계다.

검증 호스트는 Apple Silicon/macOS27.0.1이다. 수집기 프로세스와 UI 시험 프로세스는 종료됐고 불필요한 중복 Fixture 백업만 정리했다. 실제56 앱 복구 백업과 실패 원본은 보존했다. 제품 소스·설치 후보는 자동49단계 입력과 같으며 후속 수집 집계 수정은 관련 회귀로 따로 확인한다.

## 이전 기록 · 같은 날짜 · 종료·복구 수정 후보56

[종합 결과](../.build/verification/end-recovery-20261012/RESULT.ko.md)와 [자동 검증 원본](../.build/verification/end-recovery-20261012/automated/summary.json)을 따른다. 사용자가 할 물리 조작과 에이전트의 준비·판정은 [종료·복구 물리 체크리스트](END-RECOVERY-PHYSICAL.ko.md)에 분리했다.

- [x] 잠자기 집계를 실제 Sleep 횟수 대신 **요청 시도**로 정정. 기존 `forcedSleeps` 저장 키·이전 수치를 보존하고 CLI JSON에 `sleepRequestAttempts` 별칭을 추가했다. 열·배터리 보호는 중립 보호 사건으로 기록한다.
- [x] 원복 첫 실패 뒤 같은 분리 사건을 원래 승인 기한 안에서만 재평가한다. 새 작업·사용자 끄기·열림·재연결·소유자 상실·기한 종료·재시작은 이전 Sleep 승인을 취소한다. OS 요청 거절 뒤 반복 Sleep은 하지 않는다.
- [x] 실제 배터리 마감 전에 준비된 종료 승인은 고정 마감부터 최대30초 안에서만 소비한다. 짧은 heartbeat 만료를 배터리 종료로 오인하지 않고, 새 허가는 이전 종료 준비를 취소한다.
- [x] 살아 있는 GUI가 관측한 분리 사건은 종료 정리 전에 처리한다. 이미 종료된 GUI·로그아웃은 원복만 하며 새로운 Sleep 권한을 만들지 않는다.
- [x] 전체 자동 **48단계·소스1,043개** 통과. 실패·skip0, 실행 중 소스 변경0. 패키지 v3 도우미 **105사례**, 실제55→56 격리 이관10사례와 합성 Sparkle 업데이트를 포함한다. 이 수들을 별도 합산하지 않는다.
- [x] 최종 패키지 도우미의 실제 시간 타이머3개: 수동 마감2.146초·원복 재시도30.147초·배터리 마감2.144초. 센서와 OS 쓰기는 dry-run이며 실제 Sleep 근거가 아니다.
- [x] 후속 UI 실행기 판정 회귀21개. 화면 캡처 오류만 있는 완전한 실패 보고서를 환경 차단으로 구분하며 원본 실패·실행 시작 근거를 보존한다. assertion·런타임 오류가 섞이면 실패를 유지한다.
- [x] native UI 기능 **18개 고유 경로 통과**. [첫 실행](../.build/verification/end-recovery-20261012/native-ui-functional-all/result.json)의12개 통과와 [인증 뒤 동일 실행물 재시험](../.build/verification/end-recovery-20261012/native-ui-reuse-authorized-six/result.json)의6/6 통과를 조합했다. 후속 실패·skip·expected failure·런타임 경고0, timeout 없음. 한 번의18/18 실행이라고 표시하지 않는다. 메뉴·시간 저장·화면 유지·포커스·긴 경고 스크롤뿐 아니라 한국어/영어 최소760pt 창·페이지 전환·닫기/재열기·진단·열 보호까지 원래 assertion으로 확인했다.
- [x] UI 인증 간섭 뒤 정상 재검증. 새 Runner를 만든 재시도는 설정 탐색에서 실패해 원본을 보존했다. 인증을 요청했던 기존 Runner·embedded test·private fixture를 재빌드 없이 사용했고 전체 실행물의before/after fingerprint가 동일했다. 현재 제품/원본/생성 테스트·fixture 해시와 BundleID/expected path도 대조했다. 이 실행에는SecurityAgent 간섭 로그0이다. 전역 보안 정책을 자동 변경하지 않았다.
- [x] 대표 설정4장 시각 검토. 한국어800pt/760pt·영어760pt·앱 설정 하단 스크롤에서 확정 가능한 헤더 겹침·글자 짤림·정렬 결함은 발견하지 못했다. 정지 캡처 범위이며 모든 스크롤 시점과 전체 요소 통과의 대체 근거는 아니다.
- [ ] 전체 요소 배치 정량 인수. 최신 기능 실행은 모든 screenshot·AX·상태와 테스트별 핵심 배치 assertion을 유지하되, 비용 큰 bulk AX telemetry를 `measurementCompleteness=unavailable`로 분리했다. 전 요소 짤림·겹침 점수는 미측정이며 기능12개 통과를 디자인 전체 통과로 확대하지 않는다.
- [x] 후보56 실제 설치·설정 보존·실행 hash 확인. [설치 기록](../.build/verification/build56-install-20261012T054919Z/verified-installation.json)에서 실행 GUI와 root 도우미가 모두56이며 후보 hash와 일치한다. 기존 사용자 설정13개 항목을 보존했다.
- [x] 설치본56의 원격 조작 불필요 확인7개. AC 자동 유지 중 수동 무제한 시작·종료, 자동/화면 유지 보존, 수동 미부활, 설정 보존, 동일 실행 경로, 실제 자체 system/display assertion과 관측된 타사8개 PID/종류 보존을 [원본](../.build/verification/build56-installed-remote-review-20261012/result.json)에 기록했다. 배터리·실제 덮개·OS Sleep·원격 인증을 검증한 결과는 아니다.
- [ ] 실제 AC 덮개 유지·닫힌 분리 Sleep/Wake·배터리 만료·해당 원격/외장 화면·macOS26 실물 인수. 공개 배포와 실제 업데이트는 사용자가 정한 마지막 단계다.

제품 소스·패키지는48단계의 동결 입력과 같다. 이후 변경은 UI 실행기·그 회귀와 native 테스트의 관측 정정3건(메뉴 More actions의AXTitle, Preview의StaticText/AXValue, 메뉴/설정 시간 선택기의 서로 다른 viewport)이다. 원본 테스트55cecc…·제품 GUI698e741…을 유지한 같은 fixture에서18개 기능 경로를 확인했으며 기존 실패 결과와 timeout 원본은 덮어쓰지 않았다. 이후 사용자 요청으로 설치 GUI·도우미를55에서56으로 교체하고 기존 설정을 보존했다. 실제 검증 호스트는macOS27.0.1이며 macOS26 실물 검증을 대체하지 않는다.

사용자가 원격이라 물리 조작을 수행하지 못해 이번 수집은 정상 종료했다. [54개 표본](../.build/verification/physical-tests/20261012T060446Z-97007a63/analysis.json)은 모두 AC·열린 덮개이며 닫힘/분리/배터리 만료는 미실시다. 별도로 **도우미 로그 읽기 권한 결함**을 확인했다: root 소유 `/Library/Logs/Tether`가0700이라 일반 사용자 진단·수집이PermissionError다. live 상태와OS 로그 조회는 성공했지만 도우미 상세 사건을 읽었다고 표시하지 않는다. 이 권한 문제와 실제 닫힌 분리Sleep/Wake 인수는 남은 항목이다.

## 이전 기록 · 같은 날짜 · 후보55 / UI 인증 전

[이번 재검증 결과](../.build/verification/ui-function-retry-20261012/RESULT.ko.md)와 [기계 판정 기록](../.build/verification/ui-function-retry-20261012/verification-summary.json)을 따른다. 아래 날짜별 기록은 당시 상태이며 현재 완료 수에 합산하지 않는다.

- [x] 전체 자동46단계·소스1,037개 통과. 실패·제외0, 실행 중 입력 변경0.
- [x] 격리 도우미79사례, 전원16·충돌51·수동34·작업50·이관48사례 통과. 자동46단계에 포함한다.
- [x] 실제 유한 OS 요청 만료·타사 시험 요청 보존 및 dry-run 실제 시간 타이머2개 통과. 실제 잠자기/덮개 증거와 구별한다.
- [x] 후속 view/model27개·UI 판정 도구18개 회귀, 최종 release 패키지·서명 및18개 native UI 테스트 컴파일 성공.
- [ ] 최종 native UI 실행. macOS가 `Enable UI Automation` 인증을 요구해 Runner 초기화에서 시간 초과됐다. raw xcresult 실패1개는 실제 UI 메서드 실행 실패 수로 합산하지 않는다.
- [ ] 최신 후보 GUI 설치. 현재 설치본은55지만 후보 GUI hash와 다르며 이번에는 교체하지 않았다.
- [ ] 실제 덮개·분리 Sleep/Wake·배터리 예외·원격 입력·macOS26 인수. 배포·실제 업데이트는 마지막에 확인한다.

전체 suite 이후의 변경은 private Fixture 포커스 식별자/새 관측과 UI 도구 분류뿐이며 관련27·18개와 패키지·native build-for-testing으로 후속 확인했다. 시스템 전원·잠금 정책과 설치 도우미를 바꾸지 않았다.

## 추가 부족 검토 · 2026-10-12 · 읽기 전용

[추가 검토 결과](GAP-REVIEW-20261012.ko.md)에 새 확정 기록 오류2개, 의도된 종료 예외3개, 사용성 공백2개와 업데이트 인수·문서 정리 항목을 구분했다. 이 리뷰에서 제품 코드를 수정하거나 새 검사를 실행하지 않았다. 정상 자동 검증 통과를 예외 경로의 실제Sleep 보장으로 확대하지 않는다.

## 이전 기록 · 2026-10-11 · 당시 후보55 / 설치본53 / 소스·격리 검증 완료

[최종 결과 요약](../.build/verification/clamshell-quality-20261011/summary.json)에 이번 검증과 미실시 항목을 기록한다. private Fixture 잔여 프로세스는0으로 확인했다.

| 이번 검증 | 결과 | 범위·근거 |
|---|---|---|
| 최종 소스 | 총1,034개(Core690·앱344), **1,025개 통과·9개 제외·실패0** | [source-final.log](../.build/verification/clamshell-quality-20261011/source-final.log). live IOKit을 의도적으로 비활성화한 검사이며 제외9개를 통과 수에 넣지 않음 |
| 후보55 격리 도우미 | **79사례 통과·실패0** | [helper-after.log](../.build/verification/clamshell-quality-20261011/helper-after.log). 실제 private IPC·모의 센서·dry-run OS 쓰기, 추가 보호 회귀5개 포함 |
| 범위·전원·충돌·작업 세션 | 각각 **19·16·51·50사례 통과·실패0** | [범위](../.build/verification/clamshell-quality-20261011/final-scope.log) · [전원](../.build/verification/clamshell-quality-20261011/power-fixes.log) · [충돌](../.build/verification/clamshell-quality-20261011/conflicts.log) · [작업 세션](../.build/verification/clamshell-quality-20261011/work-session.log). 중복되는 근거를 합산하지 않음 |
| 실시간 타이머 | **2사례 통과** | [recovery-timers.log](../.build/verification/clamshell-quality-20261011/recovery-timers.log). 수동 마감2.145초·원복 재시도30.129초 관측, 센서·OS 효과는 dry-run |
| 최종 패키지·격리 앱/CLI | release 빌드·플랫폼·서명 통과, 격리 앱/CLI17개 통과·skip0 | [package-final.log](../.build/verification/clamshell-quality-20261011/package-final.log) · [packaged-cli.log](../.build/verification/clamshell-quality-20261011/packaged-cli.log). 후보55 패키지이며 실제 설치·관리자 승인 시험이 아님 |

후보55에서 두 후속 결함을 수정하고 위 소스·격리 실행 경로로 회귀 검증했다.

- [x] 만료된 작업 허가가 이후 열·배터리 보호의 새 Sleep 사건을 만들지 않도록 guard 보완. 이전54의 격리 도우미 `expiredLeaseAtProtection`에서 모의 Sleep1회로 실패를 재현하고 후보55 회귀에서 차단을 확인했다. 실제 OS Sleep 시험은 아니다.
- [x] 시스템 시계 ±1시간 보정 때 자동 배터리 잔여 시간·진행률이 왜곡되지 않도록 표시 날짜를 보정. 도우미 ACK의 마감 단축이 동시에 발생해도 시작·종료 표시를 함께 조정하며 연속 시간 마감·시간 예산은 불변. 최종 소스 회귀 통과.

설치본은53이며 후보55의 최신 수정은 미설치·미게시다. 이번에 live IOKit·native UI·물리·인증된 원격·관리자 설치·공개 업데이트 인수는 실행하지 않았다. 사용자가 다른 작업 중 UI 자동화를 직접 껐으므로 이 요청에서 재시작하지 않는다.

[이전 후보54의 자동 기록](../.build/verification/lock-fix-20261011/automated/summary.json)은 소스1,032개·skip0·자동47단계 통과다. 당시 `physicalSleepProven`, `authenticatedRemoteProven`, `administratorInstallProven`, `liveAppInstalled`는 모두 `false`이며 선택적 `native-sparkle`은 미실시였다. 아래 날짜별54·53·52·51 기록과 설치 hash는 당시 근거이며 현재 후보의 완료 여부나 검사 수에 합산하지 않는다.

## 이전 화면 유지 옵션 기록 · 당시 후보55 / 후속 확인 항목

`작업 중 화면 유지`는 후보54에서 추가한 선택으로, 현재 후보55에서도 유효한 자동·수동 작업 유지 중 모든 화면의 유휴 display sleep을 억제한다. 열린 덮개에서의 유휴 화면 꺼짐에 대응하며 종료·전체 중지·보호 시 자체 화면 요청을 해제한다. 선택만으로 새 세션을 시작하지 않는다. 새 설정과 기존 설정 이관의 기본값은 꺼짐이다. 사용자는 이번 설치에서 켜짐을 선택했지만 후보55는 아직 미설치이며, 실제 설치·저장 확인 전에는 적용 완료로 표시하지 않는다.

수동 잠금과 macOS의 전역 암호 요구 정책은 유지한다. 이미 꺼진 화면의 재점등, 실제 화면 꺼짐과 무잠금의 동시 유지, 닫힌 덮개·화면 보호기 잠금 방지는 이 선택의 보장 범위가 아니다. 암호 요구를 자동으로 낮추거나 사용자 활동 신호를 반복 입력하지 않는다.

- [x] 설정 기본 꺼짐·이관 보존, 선택과 실제 요청 활성·요청 오류·미확인의 분리 표시 소스 회귀.
- [x] 자동·수동·겹친 유지에서 유효 기간에만 화면 요청 생성, 종료·일시 중지·보호·프로세스 종료 시 자체 요청 해제 및 타사 요청 보존의 소스 회귀. 실제 화면·잠금 상태는 아래 별도 항목.
- [x] 화면 유지 요청 생성·해제 실패의 오류 표시와 재시도, 일반 시스템 유지와 오류 범위 분리의 소스 회귀.
- [ ] 한국어·영어 native 설정 토글 조작과 식별자 `keep-display-awake-toggle`, 작은 창·오류 안내의 표시 확인.
- [ ] 후보55 실제 앱·CLI 설치, 실행 파일 hash·빌드·저장된 화면 유지 켜짐·현재 요청 활성 확인.
- [ ] 열린 화면의 유휴 display sleep 억제와 해제 뒤 macOS 정책 복귀를 실제로 확인. 요청 활성만으로 화면·잠금 상태를 통과시키지 않음.
- [ ] macOS26 Apple Silicon에서 닫힌 덮개·외장 화면 조건, 화면 보호기, 암호 Immediately, 수동 잠금과 정상 잠금 해제의 실제 상태를 별도 관측.
- [ ] 원격을 사용하는 경우 인증·프레임·입력·재접속을 별도 확인. 화면 유지 선택이나 `pmset` 요청만으로 원격 사용 가능을 판정하지 않음.

## 이전 추가 검수 · 2026-10-08 · 당시 수정 후보53 / 해당 수정 미설치

- [x] 추가 제품 결함8건 수정: 원복 재시도 누락, 이유별 전원 허가 혼용, lock 경합 중 분리 사건 유실, 비활성 자동 이유의 잘못된 수동 허가, 재개 버튼·정책 불일치, Sleep 뒤 중지 표시 누락, 데스크탑 저장 조건 복구 부재, 자동 배터리 만료 안내 부재.
- [x] 관련 전체 소스939개(앱301+Core638) 단일 실행 실패0. UI24개는 이 수에 포함. 배포·업데이트 관련4그룹 제외.
- [x] 최종 release 패키지 도우미74개와 추가 IPC 없는 실제 시간 타이머2개 통과. 시스템 쓰기는 dry-run이며 실제 Sleep 증거로 합산하지 않음.
- [x] private Fixture 진입 가드3개·native runner 판정15개 통과. runner 초기화 오류의 실제 UI 미실행을 구별하고 최초 실패 근거 보존.
- [x] release 패키징·arm64/최소26·deep strict 서명 통과. 기존 설치 앱·root helper hash, 저장 설정, pmset 값 보존·시험 프로세스0.
- [ ] 당시 새 데스크탑 조건 복구 버튼과 메뉴 중지·재개의 실제 native 클릭: Mac 잠금으로 runner 초기화 실패해 미확인. 현재 UI 자동화 재시작을 기다리는 상태로 해석하지 않음.
- [ ] 위 클릭 검사 후 수정 후보의 실제 앱·관리자 도우미 설치 및 hash·연결·설정 보존 확인. 현재 설치본에는 이번 수정 없음.
- [ ] 실제 닫힌 AC 유지·분리 Sleep/Wake·배터리 예외·원격·macOS26 인수. 배포·업데이트 시험은 마지막.

[결함별 수정·근거·후속 위치](/Users/jukqaz/dev/codex-chat/2026-09-28/d/outputs/TETHER-DEEP-FINAL-AUDIT-20261008.ko.md) · [종합 검사와 소스 hash](../.build/verification/deep-final-audit-20261008/verification-summary.json). 당시 후보 GUI SHA는 `6f18fef7…`, 설치 GUI SHA는 `d197b7ff…`다. 같은build53 번호와 실제 교체 여부를 구별한다.

## 이전 확인 · 2026-10-08 최종 디자인·기능 · 당시 설치본53

- [x] 최종 수정 후 native 캡처6장 재검토. 캡처 범위에서 추가 확정된 잘림·정렬·중복 결함 없음. 실제 설치본 픽셀·대비 수치·물리 덮개 합격과 구별.
- [x] 업데이트 관련 그룹을 제외한 고유 소스928개 확인. 첫 실행1개 실패는 바뀐 재개 안내 문구의 옛 기대값이었고, 해당 UI binding17개 후속 검사에서 통과했다. 단일 일괄 통과로 표시하지 않는다.
- [x] 현재 설치된 CLI·도우미의 격리 IPC17개와 v3 helper70개 통과. 모의 전원·덮개·Sleep이며 실제 잠자기 증거가 아니다.
- [x] 실제 열린 덮개·AC에서 수동1분 시작·재요청 마감 보존·약60.5초 만료 관측·AC 무제한 시작·명시 종료 확인. 자동 유지는 계속 활성 상태였다.
- [x] 앱 설정·root control·시스템 전원 설정 보존, 앱 PID17684·도우미53 연결, doctor·화면 관측·진단·deep strict 서명 확인. 이번에는 제품 코드나 설치 파일을 다시 교체하지 않았다.
- [ ] 실제 닫힌 AC 유지·닫힌 분리 Sleep/Wake·배터리 예외·다른 기기의 원격 입력·macOS26 인수.
- [ ] 배포·실제 업데이트 경로는 사용자 결정대로 마지막에 시험.

당시 설치 GUI SHA는 `d197b7ff99a1b514d77ad9e6ce4ae4e8bd25058afd9848854a004126b536ed4c`다. 아래 후보·설치 상태는 각 이전 시점의 기록이며 현재 설치 상태와 혼합하지 않는다. [당시 결과](/Users/jukqaz/dev/codex-chat/2026-09-28/d/outputs/TETHER-FINAL-DESIGN-FUNCTIONS-20261008.ko.md) · [소스 실패와 후속 판정](../.build/verification/final-design-functions-20261008/source-reconciliation.json) · [당시 설치본](../.build/verification/final-design-functions-20261008/installed-live-result.json).

## 이전 후보 · 2026-10-08 사용자 승인 간소화 · 당시 설치 미실시

- [x] 수동 시간 선택을 메뉴바로 통합. 설정의 두 배터리 시간 picker와 마지막 수동 선택 보존 확인.
- [x] 종료 예고·시간 만료 알림 UI/발송 제거. 열·관측 실패·잔량 알림과 timer·기록 보존, legacy 시작 전 사건 재생 회귀 확인.
- [x] 별도 사용법 창 제거. 첫 설치 준비·도우미 확인과 명시적 알림 권한 회귀 확인.
- [x] 관련 소스138개, 실제 native UI3/3, release 빌드 통과. native 경고0·검사 프로세스0.
- [x] 새 화면4개에서 보이는 행의 중대 겹침/잘림을 발견하지 못함. 새 정량 점수는 미산출.
- [ ] 이 후속 후보의 실제 설치·덮개/전원·원격·macOS26 실물 인수. 기존 설치 기록과 구별.

[결과와 화면](../.build/verification/essential-cleanup-20261008/RESULT.ko.md) · [고유 검사/증거](../.build/verification/essential-cleanup-20261008/verification-summary.json)

당시 2026-10-08 · 설계v3 / 최소macOS26·Apple Silicon. 설치 파일은2026.10.1 Beta 1·build53이며 GUI SHA `2d7da124…`였다. 시간 옵션 정리 후보는 같은build53·SHA `9e6fbcea…`로, 당시 설치하지 않았다. 앱 아이콘6번·메뉴바1번을 유지한다. 후보별 UI·기능 검사와 설치·물리 기록을 구분하며, 이전 단계의 검사 횟수를 합산하지 않는다.

사용자는 케이블·덮개·다른 기기의 원격 클라이언트와 필요한 인증만 조작한다. 성공/실패 판단·시각 메모·로그 비교는 에이전트가 한다. September 수집/heartbeat를 이번 후보의 시험으로 다시 쓰거나 재시작하지 않는다.

## 1. 자동으로 완료한 검증

### 이전 후보 · 시간 옵션 정리 · 당시 설치 미실시

[결과·새 화면](../.build/verification/preset-simplification-20261008T071529Z/RESULT.ko.md) · [검증 요약](../.build/verification/preset-simplification-20261008T071529Z/verification-summary.json)

- [x] 직접 입력창·입력 sheet/popover·문자열 파서·입력 안내 제거. 메뉴·설정은15분·30분·1시간·2시간, 전원 연결 중 수동 무제한을 제공한다.
- [x] 관련 소스 회귀88개(Core62+앱26), 실패0. 유효한 기존 임의 시간·설정 복원·상한·선택만 저장·진행 중 마감 고정 확인.
- [x] native 배터리 메뉴1개, 한국어 전체 화면1개, 시간 설정1개가 각각 후속 실행에서 통과. 선택지의 전체 순서·정확한 저장값·시작/종료·Esc·입력창 부재 검사. 단일3/3 통과로 표시하지 않으며 실패 원본을 보존한다.
- [x] 마지막 단독native1/1·skip/expected failure/런타임 경고0. 관련 검사 실행의 GUI SHA는 모두 새 후보와 같다. 시각 확인4개이며 이번 정량 디자인 점수는 미산출이다.
- [x] release 빌드·서명, 후보/설치 GUI hash 구별, 임시 UI 앱·검사 프로세스 잔여0.
- [ ] 새 후보 설치·production 화면과 실물 덮개·분리 Sleep/Wake·원격·macOS26 인수. 이번 UI 검사로 통과시키지 않는다.

### 이전 후보 · 정보 구조·기능 체크 · 설치 미실시

[결과](../.build/verification/ui-review-20261008T054559Z/RESULT.ko.md) · [화면25장](../.build/verification/ui-review-20261008T054559Z/SCREENS.ko.md) · [검증 요약](../.build/verification/ui-review-20261008T054559Z/verification-summary.json)

- [x] 관련 nonlive 소스292개, 실패0. 최종 문구/콜백 뒤 중복되는UI15+controller73=88개 후속 통과.
- [x] 분리해 두었던 실제 유한 IOKit·다른 테스트 요청 보존·IOPS observer3개 후속 통과, 실패/skip0. 실제 Sleep은 요청하지 않음.
- [x] 실제 격리 helper·IPC70그룹 통과. 센서·OS 쓰기는 모의/dry-run.
- [x] 자동/수동/전체 중지·직접 입력·3탭·한국어/영어·최소 창·데스크톱·보호·긴 오류·복구의native12개 경로 성공 근거. 전체12개 실행의11통과/1실패를 보존하고 acceptance2개, sheet2개, viewport1개 후속 통과. 단일12/12 통과로 표시하지 않음.
- [x] 최신 후속native skip·expected failure·런타임 경고0. 최종11개 캡처 중대 결함 검출0·측정 범위50.45%, 평가기 회귀28개 통과. 전체 미적 점수/Glass 대비는 미측정.
- [x] release 빌드·서명, 후보/설치 파일의GUI hash 구별. 시험 UI 프로세스 모두 종료.
- [ ] 이번 후보 설치·production Settings/메뉴 화면 확인. 기존 설치본을 새 후보의 화면으로 대체하지 않음.
- [ ] 실제AC 덮개120초·닫힌 분리Sleep/Wake·배터리 마감/미부활·인증된 원격/잠금·macOS26 실물 인수.


### 이전 단계 · 2026-10-08 DESIGN.md 적용·최종 UI 설치

[최종 결과](../.build/verification/design-repair-20261008T111403/RESULT.ko.md). 당시 GUI SHA-256은 `55d72ce36991dbfe9f4d9a50c050053c2b2230522504793fbe885313156c0b90`다. 디자인 기준은 [DESIGN.md](archive/2026-10-21-spec-cleanup/DESIGN.md)를 따른다.

- [x] 최종 소스989개(Core679+앱/업데이트310), 실패·skip0. 유한 native assertion gate 활성화.
- [x] 최종 후보 실행 입력의 공유 Settings·MenuBarExtra Scene UI9/9. 한국어 실제760pt·영어·3탭·재열기·메뉴 조작·sheet·Return/Escape·보호·데스크톱·긴 오류. skip·expected failure·런타임 경고0. private bundle과 모의 전원 경계다.
- [x] UI runner 회귀13개. 변경 없는 helper/전원 소스의47통합 단계·11시간 경과 검사는 근거 재사용이며 최종 GUI 재실행으로 표시하지 않는다.
- [x] 13:09:59 새 GUI53 설치·PID72785·도우미 연결·기존 AC 자동 유지 복원. 도우미/CLI/복구/아이콘·login agent 보존.
- [x] 기능 선택과 나머지 설정 도메인 보존. main/backup의 자동 활성화 식별자만 정상 갱신됐다.
- [ ] 설치본 실제 픽셀·마우스/키보드: Computer Use 정확한 app 조회가 -10005 시간 초과. 공유 Scene UI 통과를 이 항목의 통과로 대체하지 않는다.
- [ ] 실제 덮개·분리 Sleep/Wake·원격 인증/입력·macOS26 실물·공개 배포. 최종 UI 검사 환경은 macOS27.0.1이다.

### 이전 단계 · 2026-10-08 실제53 설정 툴바 후속 수정

[현재 설치·검사 결과](../.build/verification/installed-ui-qa-20261008T105132/RESULT.ko.md). GUI SHA-256은 `2e6852bdb9c3d086ddc499400226de8946d3a3143f5410c678191b610d65943d`다. 이전 결과와 합산하지 않는다.

- [x] 설치 앱의 실제 유지·해제·독립 수동1분·만료61.031초·자동 복원7개. 탭 수정 전 GUI에서 확인했으며 전원 로직/도우미는 동일하다.
- [x] OFF와 만료 때 테스트용 타사 idle 요청 보존2개. 테스트용 프로세스 정상 종료.
- [x] 실제 Settings의 탭 제목/아이콘 겹침 재현, Text 탭으로 수정·설치. UI22개·release·strict 서명 통과.
- [x] 교체 뒤 GUI hash·새 프로세스·도우미53·native idle 요청1개·소유권·감시 장치 확인. 기능 선택·기존 시작 job·도우미/CLI/복구/아이콘 보존.
- [ ] 수정 후 production Settings3탭·MenuBarExtra·키보드/마우스. 교체 후 창이 닫혀 Computer Use 조회가 시간 초과다. 실제 창이 열려야 검사를 이어갈 수 있다.
- [ ] 닫힌 덮개·전원 분리·실제 Sleep/Wake·잠금/원격 입력·macOS26 실물.

### 이전 UI 단계 · 2026-10-08 실제53 재설치와 최종 UI 배치

[재설치 결과](../.build/verification/reinstall-20261008T093839/live-verification-final.json)와 [UI 적용 결과](../.build/verification/ui-layout-20261008T095542/RESULT.ko.md)를 구별한다. 전원 기능·도우미는 동일한53이며 UI 변경은 아래22개 표적 검사로 다시 확인했다. 이전985개 전체 검사를 새 UI에서 재실행한 것으로 표시하지 않는다.

| 검증 | 결과 | 경계 |
|---|---|---|
| 관리자 설치·이관 | 앱·도우미53 적용, 현재 버전/hash/응답 확인. 기능 선택 보존, 오래된 Sleep 명령 재실행 없음 | 현재 Mac의 승인된 실제 설치. 취소·실패 원복·macOS26 인수는 별도 |
| 설치 앱·CLI 실제 실행 | **7개 통과**. OFF 자체 해제, ON AC 자동, 자동OFF와 전체ON 분리, 독립 수동1분, 실제 만료60.726초 뒤 해제, 자동ON 복원 | 열린 덮개·AC, 실제 IOKit/도우미 상태. 덮개·실제 Sleep 통과 아님 |
| 최종 UI 회귀 | **22개 통과**, 실패·skip0 | 실제 view/model binding, KR/EN·기종·작은 창/메뉴·오류/보호 조합 |
| UI 패키지·적용 | release 빌드·deep strict 서명, 새 GUI SHA `6a918431cd1d38977fb911a28018c18c022cd7d39a35e9e3fa85949235240267`, 새 프로세스/도우미 연결·AC 자동 유지 확인 | 도우미·CLI·복구·아이콘은 그대로. 사용자 기능 선택 보존; 정상 OFF→ON 활성화 식별자/backup 갱신 |
| native UI | 최소760×600pt General·System 탐색과 스크롤 초기화, 메뉴 배치·Tab 포커스 관측 | shipping view를 쓰는 private Preview. production MenuBarExtra와 마지막 보호/영어/버튼 활성화는 미확인 |
| 최종 보호 배치 | 한국어·영어 정적 렌더에서 두 관측값의 정렬·안내 줄바꿈 확인 | 모의 상태·Liquid Glass OFF. 실제 탭/Glass 합격 아님 |

- [x] 설치된 앱·도우미53의 현재 응답과 자체 유지·감시 장치를 확인했다.
- [x] 최종7개 UI 파일 변경 뒤 UI22개와 release 빌드를 확인했다. 추가 기능 정책 변경은 없다.
- [ ] production UI와 마지막 native 조작: 앱 조회 시간 초과와 마지막 OS 잠금으로 남았다. 잠금 해제 우회나 시작 설정 변경은 하지 않았다.
- [ ] 물리 시험: 수집기는 디자인 요청에 따라 `stopped_for_design_review`로 정상 종료했다. 덮개·케이블의 새 실물 인수는 미실시다.

### 이전 단계 · 2026-10-08 Goal 보완 후보53

[이번 범위와 완료 기준](../.build/verification/goal-completion-20261008/scope.json)에 기능·디자인 개선과 설치본 구별을 기록했다. 전원 분리와 유한 덮개 허가/수동 마감의 경계에서 GUI가 먼저 읽는 경우와 도우미가 먼저 읽는 경우를 같은 계약으로 맞췄다. 만료된 허가는 자체 원복만 허용하며 새로운 분리 Sleep을 승인하지 않는다. 아직 유효한 자동 이유가 남은 경우의 정상 분리 Sleep 집행은 유지한다.

화면 절전 진단은 현재 닫힘·전체 깨움·자체 소유권·앱 연결·30초 미만 관측을 확인한다. 열린 덮개에 옛 재시도 중단 기록을 경고로 표시하지 않고, 가상/외장 화면은 현재 OS 화면 관측을 사용한다. 원래 JSON 기록은 디버깅용으로 보존한다.

Sparkle 실제 엔진의 시작·초기 KVO·잘못된 키·네트워크 이전 구성 실패를 private bundle/suite로 검사했다. 자동 확인이 OFF일 때 Sparkle의 자동 다운로드 setter가 무시되어 예전 선택이 남는 경로를 수정했다. 이후 확인을 ON으로 바꿔도 자동 다운로드를 되살리지 않는다.

이 Goal 단계의 설정은 native 탭·그룹형 Form·Section footer, 메뉴는 표준 조작과 Liquid Glass 버튼을 사용했다. 최소760×600pt·한국어/영어·360pt 패널과 상태별18×20pt 아이콘을 검사했다. 당시 실제 화면 조작은 Mac 잠금으로 미확인이었다. 이후 native 부분 확인과 실제53 설치 결과는 위 최신 항목에 둔다. offscreen 렌더는 정적 배치와 모의 데이터 증거이며 Liquid Glass와 production 메뉴바 호스트의 픽셀 합격 증거가 아니다.

- [x] 화면 진단 Core 회귀 38개, 실제 UI binding·Workbench·아이콘·접근성 회귀 36개, 실제 Sparkle 시작/종료 회귀 13개 통과. 서로 겹치는 항목을 전체 수에 더하지 않는다.
- [x] 현재 debug 도우미의 격리 v3 집행 70그룹 통과. OS 쓰기·센서는 모의이며 실제 Sleep을 요청하지 않았다.
- [x] 최종 소스·패키지·통합·실제 유한 IOKit·native Sparkle·이전 51/52 바이너리 이관을 확인했다. [최종 종합 결과](../.build/verification/goal-completion-20261008/verification-summary.json)는 원본 실패와 후속 재검사를 구별한다. 제품·검사 입력 hash는 일괄 실행 및 후속 검사 동안 동일하다.

| 검증 층 | 최종 결과 | 근거와 한계 |
|---|---|---|
| 전체 소스 | **985개**, Core679 + 앱/업데이트306, 실패·skip0 | [로그](../.build/verification/goal-completion-20261008/final-automated/source-tests.log). 새 Sparkle 실제 startup3개·현재 UI 회귀도 포함하며 별도 수치와 합산하지 않음 |
| 격리 통합 | **30개 그룹** 통과 | [일괄 기록](../.build/verification/goal-completion-20261008/final-automated/summary.json). 작성자·권한·복구·수동·충돌·이관·물리 수집/분석 회귀. OS 쓰기·센서는 모의 |
| 현재 release 패키지 | v3 도우미 **70그룹**, 실제 앱/CLI 연결 **14개** 통과 | [도우미](../.build/verification/goal-completion-20261008/final-automated/packaged-v3-helper.log), [앱/CLI](../.build/verification/goal-completion-20261008/final-automated/packaged-app-cli.log). 버전53·실제 IPC와 private dry-run 효과 |
| 일반 OS 요청의 유한 기한 | 90초 뒤 최초 미활성 관측 **+0.032초**, 관측 간격0.127초. 정지한 자체 자식·타사 역할의 요청은 살아 있음 | [native 결과](../.build/verification/goal-completion-20261008/final-automated/native-expiry/result.json). 실제 이 Mac의 IOKit·powerd 관측, 물리 Sleep/잠금·root watchdog·macOS26 지연 상한은 아님 |
| 실제 이전 helper 교체/원복 | **51→53·52→53 각각10개**, 총20개 통과 | [51](../.build/verification/goal-completion-20261008/final-automated/upgrade-build-51.log), [52](../.build/verification/goal-completion-20261008/final-automated/upgrade-build-52.log). 실제 이전 바이너리 복사본·임시 설치 루트. 관리자/production 설치는 별도 |
| 실제 Sparkle 교체 | **13개** 통과 | [재검사](../.build/verification/goal-completion-20261008/sparkle-recheck.log). 같은 입력·Sparkle2.10.0·임시 키·localhost·가짜 앱; 변조/채널/버전/build 경계. 실제 배포 키·게시 피드·앱 UI 교체는 별도 |
| 메타데이터·서명 | arm64·최소26·버전2026.10.1/build53·deep strict 서명 통과 | [platform](../.build/verification/goal-completion-20261008/final-automated/packaged-platform.log), [서명](../.build/verification/goal-completion-20261008/final-automated/packaged-signature.log). ad-hoc; 실제 macOS26 실행·Gatekeeper 허용·공개 배포의 증거가 아님 |
| 설치본 보존 | 앱·도우미52 hash 유지, 전원/세션·언어·채널·알림 선호 변화 없음 | [전후 비교](../.build/verification/goal-completion-20261008/installed-after.json). 마지막 업데이트 확인 시각의 1초 미만 직렬화 차이만 관측했고 저장값을 되쓰지 않음. 현재 전체 유지 `enabled=false`도 임의로 재개하지 않음 |

최초 전체 실행은 구버전49 fixture가 새 달력 버전을 쓰는 문제로 앱의 3개 테스트/12 assertion이 실패했다. fixture의 실제 구버전 식별자와 현재 식별자를 분리하고, build49에 다른 version을 붙인 경우의 거절도 확인한 뒤 전체985개가 통과했다. [최초 기록](../.build/verification/goal-completion-20261008/automated/summary.json)을 보존한다.

최종 일괄 실행은 **46단계 중45개 통과**였고 native Sparkle에 `bin`을 도구 루트로 잘못 전달해 `bin/bin/sign_update` 조회가 실패했다. 올바른 루트에서 해당13개만 재검사해 통과했고 다른 단계는 반복하지 않았다. 원본 `summary.json`의 실패를 덮지 않았으며 [종합 결과](../.build/verification/goal-completion-20261008/verification-summary.json)가 후속 근거를 연결한다. 시험 전후 source 입력 변경은 없다. task Preview/임시 서버·helper 프로세스도 남지 않았다.

- [x] 후보53의 실제 관리자 도우미 설치는 이후 재설치 단계에서 완료했다. production UI·물리 덮개·최소OS 인수는 [직접 조작 체크리스트](MANUAL-ACCEPTANCE.ko.md)에 미완료로 둔다.


### 이전 빌드52 · T형 아이콘 생성·적용 (최종 6번 채택 전)

[후속 결과](../.build/verification/tether-identity-20261007T084355Z/RESULT.ko.md). 내장 이미지 생성기로 T와 케이블 끝을 만든 뒤, 같은 형태를 모든 메뉴바 상태에 연결했다.

- [x] 실제 투명 RGBA 전경·생성 원본과 프로젝트 리소스 SHA 일치, 기존 미사용 고리 리소스 제거.
- [x] Icon Composer 컴파일과 16px·32px·128px·256px 앱 아이콘 확인.
- [x] UI binding·접근성·bitmap **22개 통과**, 실패·skip 0. 18×20pt, 1×/2× 투명 가장자리·상태 차이·활성 상태의 공통 T·긴 payload 무영향을 포함한다. 이전 검사 수에 추가 합산하지 않는다.
- [x] release/preview 빌드·deep strict 서명, native 모의 팝오버의 새 헤더·자동·수동 표시와 정상 종료 확인.
- [x] 설치 GUI52의 새 프로세스·파일7개 SHA·서명·도우미52 연결·AC 자체 유지 확인. 저장 선호 변경 없음, 도우미·CLI·복구 바이너리 동일.
- [ ] production 메뉴바 전체 픽셀·macOS26 실물·물리 덮개 동작은 이번 그래픽 검사에서 미확인이다.

### 빌드52 · 상태별 메뉴바 구분 후속

[후속 결과](../.build/verification/menu-state-20261007T081350Z/RESULT.ko.md). 메뉴바는 확인된 자동 유지·꺼짐·수동·보호·오류·확인 중을 서로 다른 모양으로 표시한다. 상태에 따른 크기 변경과 원격 배지는 없다.

- [x] UI binding·접근성·bitmap 21개와 기존 세션·절전 표시 회귀 20개 통과, 실패·skip 0. 이전 전체 검사 수에 추가 합산하지 않는다.
- [x] 모든 이미지와 label은 18×20pt. 1×/2×의 투명 가장자리·일곱 상태의 서로 다른 실루엣·긴 기존 text/ring/countdown 무영향을 확인했다.
- [x] 자동 OFF/수동 지속, 수동 종료, 전원 분리, 보호 중지, 실행 미확인→확인 전이에 실제 모델과 controller를 사용했다. OS 효과는 모의다.
- [x] release/preview 빌드·deep strict 서명 통과. native 프리뷰 NSPopover에서 자동·수동·자동 OFF/수동 지속·꺼짐 표시와 정상 종료를 확인했다.
- [x] 설치된 GUI52 교체, 일곱 파일 SHA 일치, 새 프로세스·도우미 연결·AC 자체 유지 확인. 저장된 선호 변화 없음. 도우미·CLI·복구 바이너리 변화 없음.
- [ ] production MenuBarExtra 전체 메뉴바 픽셀과 macOS26 실물 화면은 미확인이다. 앱의 상태별 bitmap 검사를 OS 공간 부족으로 status item 전체가 숨겨지는 문제의 검증으로 간주하지 않는다.

### 필수 기능만 유지 · 빌드52 후속

[후속 결과](../.build/verification/minimal-scope-20261007T064444Z/RESULT.ko.md). CPU 분석·전역 단축키·작업 유지 화면의 중복 잠금 안내를 제거했다. 기존 전원·시간·보호·언어·알림 선호는 보존했다.

- [x] 소스973개 중966 통과·native7 제외·실패0. 제외된7개는 별도 실제 IOKit 검사에서 통과.
- [x] 새 패키지 도우미67개 그룹, 실제 이전51→52 격리 이관10개 통과. 관측·OS 쓰기는 모의.
- [x] 패키지 arm64/최소26·deep strict 서명·최종 설치본의 네 바이너리와 아이콘/카탈로그/Info.plist SHA 일치.
- [x] native 프리뷰 설정 옵션 제거·진단 기본 접힘/펼침/재점검/ESC·메뉴 자동/수동·정상 종료 확인.
- [x] 앱·도우미52 실제 적용. 도우미 설치 완료 뒤 GUI를 정상 종료·교체하고, 기존 선호 보존·앱 연결·자체 소유권을 확인했다. 사용자가 요청한 덮개 유지 옵션만 최초 설치 때 ON으로 적용했다.
- [x] 새 연결 고리 아이콘: 내장 이미지 생성기 → alpha 원본 보존 → Apple Icon Composer 컴파일. 16/32/64/128/256px 시각 확인, 18×20pt 메뉴바 1×/2× 고정 폭·투명 가장자리 포함 UI 회귀16개 통과.
- [ ] 실제 닫힘·전원 분리 Sleep/Wake와 무잠금/인증된 원격 동시 사용 인수.

아래52 초기 및51 기록은 이 검사 수에 합산하지 않는다.


### 빌드 52 · 절전 영향 표시와 원격 앱 없이 덮개 유지

[이번 결과](../.build/verification/sleep-influences-20261007T054828Z/RESULT.ko.md)에 현재 근거와 설치 상태를 기록한다. 아래 빌드 51 기록은 이전 검사이며, 이번 검사 수에 더하지 않는다.

| 검증 | 결과 | 근거와 한계 |
|---|---|---|
| 전체 소스 | **995개 중 988 통과·native opt-in 7개 제외·실패 0** | [소스 로그](../.build/verification/sleep-influences-20261007T054828Z/source-tests.log). 앱이 먼저 보낸 배터리 상태, 유지 조건 변경, OFF·수동 중지·배터리 예외 회귀 포함 |
| 제외된 native 일반 절전 요청 | **7개 후속 통과·실패·skip 0** | [native 로그](../.build/verification/sleep-influences-20261007T054828Z/native-assertion-tests.log). 실제 IOKit 생성·조회·해제와 유한 기한, 실제 Sleep 아님 |
| 실제 패키지 v3 도우미 | **67개 그룹 통과** | [패키지 로그](../.build/verification/sleep-influences-20261007T054828Z/packaged-v3-helper.log). 원격 앱·외장 화면 없는 조건, 자체 원복과 한 번 Sleep 집행은 모의 OS 효과 |
| 실제 이전 도우미51→52 이관 | **10/10 통과·실패 0** | [이관 요약](../.build/verification/sleep-influences-20261007T054828Z/upgrade-51-to-52-v3-summary.json). 보존된51 바이너리·격리 설치 루트. OFF·동작 중·분리·등록 누락·실패 원복, 실제 관리자 설치 아님 |
| 마지막 화면 설정 링크 보완 | **UI·진단 17개 통과**, 최종 패키지 재빌드·서명·arm64/최소 OS 확인 | [후속 로그](../.build/verification/sleep-influences-20261007T054828Z/desktop-link-ui-tests.log). 데스크톱은 화면 설정, 휴대형은 배터리 설정으로 연결 |
| native 진단 UI | 진단 열기·기본 접힘·펼침·스크롤·다시 점검·정상 종료 확인 | [UI 기록](../.build/verification/sleep-influences-20261007T054828Z/native-ui-qa.json). 실제 view/controller와 격리 센서. production 메뉴바·물리 덮개 성공의 근거 아님 |

- [x] 앱별 일반·화면·네트워크 요청과 앱 열기·Finder 위치를 표시한다.
- [x] macOS 전원별 유휴 잠자기·화면 대기 시간, 최근 입력의 확인된 PID와 시스템 요청을 구별한다. 입력 원문·창 제목·대화 내용은 표시하거나 내보내지 않는다.
- [x] 최근 입력·시스템 요청은 기본 접힘이며, 명시적 점검에서만 시스템 설정을 조회한다. 원격 접속이나 최근 입력은 Tether 세션을 생성·연장하거나 종료를 막는 허가가 아니다.
- [x] 앱이 먼저 전원 분리를 읽어도 직전 실제 AC 덮개 허가의 종료를 도우미가 보존한다. OFF·수동 중지·유효한 배터리 유지에 불필요한 Sleep을 요청하지 않는다.
- [x] 후속 필수 기능 정리에서 앱·도우미52 교체와 덮개 유지 ON 적용을 완료했다. [최종 설치 근거](../.build/verification/minimal-scope-20261007T064444Z/design/ai-installation.json).
- [ ] 원격 앱을 사용하지 않는 실제 닫힌 AC 유지·분리 Sleep/Wake를 확인한다.

### 이전 빌드 51 · 전체 검증과 발견한 결함

근거는 [이번 결과 요약](../.build/verification/full-validation-20261007T050520Z/verification-summary.json)에 모았다. 최초 실행의 실패 기록도 보존한다. 제품 소스 수정은 메뉴 루트의 최대 높이 제한이며, 전원·잠금 설정을 바꾸는 수정은 없다.

| 검증 | 이번 결과 | 근거와 한계 |
|---|---|---|
| 전체 소스 | **982개, 실패·skip 0** · Core 671 + 앱 311 | [소스 로그](../.build/verification/full-validation-20261007T050520Z/final-automated/source-tests.log). 정책·시간·이관·IPC·UI·native 자체 assertion 포함 |
| 격리 통합·패키지 | **30개 통합 그룹**, 현재 패키지 v3 도우미 **49건**, 실제 패키지 앱/CLI **14건** 통과 | [일괄 기록](../.build/verification/full-validation-20261007T050520Z/final-automated/summary.json). 작성자·복구·설치·충돌·수집기의 OS 쓰기와 센서는 모의 |
| 실제 이전 도우미 | **49→51·50→51 각각 10건**, 총 20건 통과 | [후속 이관 요약](../.build/verification/full-validation-20261007T050520Z/upgrade-regression-summary.json). 실제 보존 바이너리와 격리 설치 루트, 승인·production 설치는 별도 |
| Sparkle native | **13건** 통과 | [로그](../.build/verification/full-validation-20261007T050520Z/final-automated/native-sparkle.log). 변조·정식/베타 채널·버전 역행·교체; 임시 키·localhost·가짜 앱 |
| 실제 시간의 구버전 타이머 | **11/11**, 최장 **290.217초**, 전후 호스트 설정 동일 | [요약](../.build/verification/full-validation-20261007T050520Z/legacy-wallclock-scenarios/summary.json). 1분·3분 타이머 및 전원 왕복의 **v1/v2 호환 재생**, v3·실제 Sleep 증거 아님 |
| native 일반 요청 만료 | 90초 기한 뒤 최초 미활성 관측 **+0.659초**, 관측 간격 **0.120초** | [결과](../.build/verification/full-validation-20261007T050520Z/final-automated/native-expiry/result.json). 멈춘 자체 자식·타사 역할의 유한 요청은 살아 있음. 실제 Sleep·root watchdog 시간 상한 아님 |
| UI 크기·스크롤 | focused 회귀 **3개** 통과; KR/EN × 휴대형/데스크톱 × 5상태 × 202/360/560pt **60조합** | [회귀 로그](../.build/verification/full-validation-20261007T050520Z/ui-regression-repair.log). native Preview에서도 360pt 본문 스크롤·고정 헤더/하단·수동 시작/해제·정상 종료 확인. production `MenuBarExtra`는 별도 |
| 설치본 읽기 전용 점검 | 실제 앱 PID 15208·앱/helper 51·현재 연결·감시 장치 정상 | [전후 상태](../.build/verification/full-validation-20261007T050520Z/host-after.json). 설정·control bytes·`pmset custom`·설치 바이너리 보존. 실제 화면 절전·잠금·덮개 유지 성공은 미확인 |

이번 자동 체크리스트:

- [x] 자동 ON/OFF·전원/배터리 조건과 수동 유지의 독립성, 선택만으로 시작하지 않음.
- [x] AC 무제한·배터리 최대 120분·최초 분리 예외, 전원 왕복·재연결·Wake·재시작의 마감 연장/부활 방지.
- [x] 닫힌 분리의 자체 원복 → 최종 재조회 → 한 번 Sleep **집행 계약**. 명령 수락을 물리 Sleep으로 표시하지 않음.
- [x] 심각한 열 상태·잔량 하한·OS 배터리 경고·센서 누락, GUI stall에도 보호 우선·명시적 재개.
- [x] 타사 실제 요청 유형/PID와 외장·가상 화면·원격 후보의 증거 구별, 타사 요청 자동 종료 없음.
- [x] 일반 assertion 공존·자체 해제·정지한 실행기의 유한 기한 만료.
- [x] 변경 journal·원복 실패·crash·watchdog·stale/late ACK·소비된 요청 미부활.
- [x] 설치 취소·필수 파일 누락·이관·rollback, 기존 OFF·보호·선택 보존과 구버전별 인증 경계.
- [x] 업데이트 변조·채널·역행·같은 버전의 다음 build·패키지 서명·arm64·최소 OS 메타데이터.
- [x] UI binding·직접 입력·키보드 동작·KR/EN·작은 화면·고대비/투명도 감소. VoiceOver 전용 지원은 사용자 요청으로 제외.
- [x] 물리 기록 수집·재분석의 손상·공백·시계 역전·다른 부팅·권한·개인정보·용량·timeout 경계.
- [x] 시험 후 production 설정 보존 및 Preview 앱·도우미·임시 폴더 정리.

최초 소스 검사에서 옛 348pt 기대값과 실제 361pt 높이 초과를 발견했다. 기대 폭을 현재 360pt 계약에 맞추고, 높이는 루트에서도 제한해 본문이 스크롤로 흡수하도록 수정했다. 단순히 넘치는 내용을 숨겨 통과시키지 않았다.

후속 일괄 실행은 **46단계 중 45단계 통과**였으며 `upgrade-build-49`가 실패했다. 검사에서 GUI 소유권을 저장하지 않던 49를 인증된 소유권을 저장하는 50과 같게 취급한 것이 원인이었다. 검사 전제를 수정해 **49는 새 인증 전 유지 해제, 50은 같은 인증된 GUI만 연속성 유지**, 이후 둘 다 명시적 v3 인계에서 권한 없는 자체 유지가 없음을 확인했다. 수정 후 49/50 전체 20건을 다시 통과했다. 원래 `summary.json`의 실패를 덮어쓰지 않으며, [통합 결과 요약](../.build/verification/full-validation-20261007T050520Z/verification-summary.json)은 해당 단계의 후속 근거를 따로 연결한다. 이관 검사 스크립트 외 제품 소스는 후속 실행 동안 동일하다.

당시 설치본51에서는 일반 작업 유지만 활성이고 덮개 지원은 `inactive`였다. `displayRecovery=stopped/requests=0`, 가상 화면만 관측됐으며 화면 절전 진단은 경고였다. 열린 덮개에서 이 값만으로 클램쉘 실패나 원격 앱의 방해를 단정하지 않는다. `screenLocked=null/notCollected`도 잠금 해제의 증거가 아니다. production 메뉴 UI는 창 응답 timeout과 빈 화면 캡처로 자동 조작을 확인하지 못했다. 이후 위 후속52 설치에서 높이 수정과 덮개 유지 ON을 적용했으며, 물리 덮개·잠금·원격 입력 인수는 여전히 별도다.

### 이전 접근성·도우미 복구 보완

VoiceOver 전용 처리와 검증은 사용자 요청으로 제외했다. 키보드·글자·여백·고대비·투명도 감소·동작 감소를 보완했다. [최신 통합 검사](../.build/verification/accessibility-clamshell-20261007T000514Z/automated/summary.json)는 **41단계 통과**, 소스 입력 변경 없이 완료했다. 실제 보존된 50→51 이관·원복 **10개**, 누락된 daemon 등록 복구의 성공·watchdog 실패·bootstrap 실패를 포함한다. 이번에 49 바이너리 검사를 다시 실행하지 않았다.

최종 UI 범위 조정 후 [소스 검사](../.build/verification/accessibility-clamshell-20261007T000514Z/without-voiceover-source-tests.log)는 **982개(Core 671 + 앱 311), 실패·skip 0**이며 [최종 패키지 앱/CLI 검사](../.build/verification/accessibility-clamshell-20261007T000514Z/without-voiceover-packaged-app-cli.log)는 **14개 통과**했다. 도우미·복구 바이너리는 위 41단계 검사 패키지와 hash가 동일하다. 키보드 Tab·Space·Return·Escape, 직접 입력 오류·취소, 360pt 패널 스크롤·포커스, 실제 macOS 고대비·투명도 감소·동작 감소 옵션을 native preview에서 확인하고 시스템 옵션을 원복했다. 모의 센서 UI 확인을 실제 클램쉘 성공으로 표시하지 않는다.

당시 설치 전 앱 GUI가 꺼져 있었고, 실행 중인 50 도우미의 재시작 등록 plist가 디스크에서 빠져 있었다. 이제 응답·버전 외에 필수 설치 파일까지 확인하여 이 상태를 준비 완료로 표시하지 않는다. 앱 50의 정상 종료와 자체 전원 원복, 검증된 앱 51 교체·서명을 확인했다. 도우미 설치·연결은 위 최신 점검으로 완료됐고 실제 덮개 시험은 남아 있다.

### 이전 실행 기록

환경은 Apple Silicon / macOS **27.0.1 (26A434)** / Swift 6.4다. HEAD `ad46bbaf587a35d2578d589600960f766bd731d3`와 미커밋 변경을 사용했다. [이번 일괄 실행](../.build/verification/completion-20261007T151509Z/automated/summary.json)은 소스 입력 hash를 고정해 **42단계 모두 통과**, 실행 중 변경 없음으로 기록했다. 시험 자료는 저장소 `.build/verification`에 두며 Desktop에 저장하지 않는다.

| 완료 | 대상 | 결과·근거 | 확인 범위 |
|---|---|---|---|
| ☑ | 전체 소스 단위·회귀 | **967/967**, Core 671 + 앱/업데이트 296, 실패·skip 0. [로그](../.build/verification/completion-20261007T151509Z/automated/source-tests.log) | 정책·시간·이관·권한·실제 UI binding·KR/EN bitmap·native 자체 assertion 공존 |
| ☑ | 작성자·복구·설치·충돌 통합 | **26개 통합 그룹**. [전체 단계](../.build/verification/completion-20261007T151509Z/automated/summary.json) | 격리 프로세스·임시 설치 루트·mock 시스템 쓰기. v1/v2 호환과 현재 v3를 구별 |
| ☑ | 현재 패키지 v3 helper | **49/49**. [로그](../.build/verification/completion-20261007T151509Z/automated/packaged-v3-helper.log) | GUI stall·전원 분리·열·OS 배터리 경고·관측 누락·최종 재조회·원복·늦은/유실 ACK·소비된 요청 미부활. 실제 Sleep 아님 |
| ☑ | 실제 패키지 앱/CLI→controller→helper | private Workbench·CLI 연결 통과. [로그](../.build/verification/completion-20261007T151509Z/automated/packaged-app-cli.log) | 실제 빌드 51 실행 파일과 IPC, 센서·OS 쓰기는 모의 |
| ☑ | 멈춘 일반 실행기의 OS 기한 | 90초 유한 요청 만료, 자식·foreign 요청 계속 살아 있음. 기록 마감 대비 **−0.035초**, 관측 간격 **0.121초**. [결과](../.build/verification/completion-20261007T151509Z/automated/native-expiry/result.json) | production IOKit idle driver의 이 Mac 관측. 실제 Sleep·root watchdog 원복 상한·macOS 26 지연 보증 아님 |
| ☑ | 실제 이전 helper 이관/rollback | **49→51·50→51 각각 7건**, 14/14. [49](../.build/verification/completion-20261007T151509Z/automated/upgrade-build-49.log), [50](../.build/verification/completion-20261007T151509Z/automated/upgrade-build-50.log) | 실제 이전 바이너리 복사본·격리 설치 루트. OFF·선택·보호 보존, 옛 요청 미부활. 실제 관리자 설치 아님 |
| ☑ | Sparkle native 업데이트 | **13/13**. [로그](../.build/verification/completion-20261007T151509Z/automated/native-sparkle.log) | Sparkle 2.10.0·가짜 앱·임시 키·localhost. 변조·채널·역행·교체. 실제 키/게시 피드/실행 앱 교체 아님 |
| ☑ | 네이티브 UI 조작 | 현재 빌드 51에서 자동/수동·직접 입력·만료·열 중지/회복·다시 시작·접힌 요청 종류·데스크톱 분기·정상 Cmd-Q 확인. [기록](../.build/verification/completion-20261007T151509Z/native-ui-qa.ko.md) | native UI + production controller/private helper. 전원·열 센서와 OS 효과는 모의. production 메뉴바·VoiceOver 전체·원격 클라이언트·알림 표시는 별도 |
| ☑ | 접근성 보완 뒤 최종 패키지 | 남은 시간을 접근성 Value에도 제공. 전체 소스·release·서명·최소 OS·패키지 앱/CLI를 다시 확인. [후속 검증](../.build/verification/completion-20261007T151509Z/accessibility-followup/summary.json) | 전체 42단계 이후 변경은 UI 파일 한 곳이며 helper hash는 동일. 이전 통합을 새 실행인 것처럼 표시하지 않음 |
| ☑ | 메뉴·설정 배치 후속 보완 | UI 회귀 **13개 실패·skip 0**, 한국어/영어 **40개 패널 조합**, release/preview 재빌드. [UI 검토](DESIGN-REVIEW.ko.md#2026-10-07--메뉴-패널과-설정-배치-수정) | 화면 높이에 따른 본문 스크롤·고정 동작, 760pt 세 설정 페이지·진단 펼침을 native preview에서 확인. 실제 status item 사용, host는 `NSPopover`; production `MenuBarExtra` 호스트와 실물 전원은 별도 |
| ☑ | 메뉴·설정 시각 재구성 | 전체 소스 **962개 통과·7개 skip·실패 0**, 최종 UI·충돌 표시 **16개 통과·skip 0**. [최종 기록](../.build/verification/design-improvement-20261007/summary.json), [화면](DESIGN-REVIEW.ko.md#2026-10-07--메뉴와-설정-시각-재구성) | native 탭·조건 선택·수동 시작/종료·일시 중지/재개·상세 펼침·360pt 메뉴 확인. 이전 통합 42단계의 새 실행이 아니며 실제 센서/전원은 모의. 설치본·control·pmset 보존, 임시 앱/helper/폴더 종료 확인 |
| ☑ | 전후 상태와 정리 | 설치본 50·control bytes·pmset custom 보존, 시험 앱/helper 정상 종료. [전후 상태](../.build/verification/completion-20261007T151509Z/host-after.json) | 설치·게시하지 않음. 기존 설정이나 실행 상태는 새 후보의 실물 합격 증거가 아님 |

일괄 재현 명령과 도구 준비는 [자동 검증 안내](AUTOMATED-TESTING.ko.md)에 있다. 검사 수는 서로 겹치며 기능 개수·신뢰도 점수·사용자 만족도가 아니다. 120분은 제품 상한이지 기기 수명 보장이 아니다. 90초는 일반 assertion 건강성 기한이며 분리 Sleep 재시도 시간이 아니다. 로컬 통과와 원격 GitHub Actions 실행은 구별한다.

이번에 실제 결함을 수정했다. GUI가 첫 배터리 전환을 놓친 뒤 옛 ACK가 늦게 오거나 새 ACK가 유실돼도 최초 마감만 사용한다. ACK와 종료 통지가 같은 응답이거나 역순이어도 끝난 배터리 구간을 재생하지 않는다. helper는 GUI 응답 없이 OS 배터리 경고를 직접 보호에 적용하고, 회복·재시작만으로 중지를 풀지 않는다. 분리 후 예외 시간도 직접 입력을 제공하며 선택만으로 시작하지 않는다.

이전 [951개·28개 후보 기록](../.build/verification/v3-20261006T102138Z/supporting-features/verification-summary.json), [v3 초기 기록](../.build/verification/v3-20261006T102138Z/verification-summary.json), [이전 50 기록](../.build/verification/20261006T093651Z/verification-summary.json)은 당시 근거로 보존하며 이번 수치와 합산하지 않는다. `.build` 정리 후 로컬 증거 링크는 사라질 수 있다.

## 2. 연결한 기능과 제외한 경로

- [x] 자동 ON/OFF·조건과 수동 시작·고정 마감을 분리. 선택만으로 시작하지 않음.
- [x] AC 무제한·배터리 최대 120분·최초 분리 예외, AC 왕복/IPC/재시작으로 연장·부활 없음.
- [x] 일반 assertion은 helper 유무와 분리, 덮개는 준비된 유한 권한만 사용.
- [x] 닫힌 분리에서 자체 원복 확인 → 최신 재조회 → 한 번 Sleep. 명령 수락과 실제 Sleep을 분리.
- [x] `serious`/`critical`, 잔량·OS 경고·조회 실패 보호, durable 중지와 명시적 재개.
- [x] 구버전 OFF·조건·하한·보호·원본 백업 보존, 옛 임시 요청·ledger는 새 실행으로 가져오지 않음.
- [x] 자동 밝기 0·재점등 loop·가짜 입력·원격 시간 연장·원격 메뉴 배지·실행 중 연장 제거/미사용.
- [x] 미지원 잠금 토글 숨김. OS 정책 조회·설정 링크 유지, 자동 unlock 없음.
- [x] 설치/실행/실제 충돌 요청 구별. 요청 종류·PID·조회 시각·영향·조정 방법은 기본 접힘. 앱 열기/Finder, 자동 삭제·종료 없음.
- [x] 사용하지 않는 연장·종료 예약 화면 삭제, 정상 설정의 메뉴 미리보기와 중복 진단 버튼 제거. 화면·원격은 접힘. CPU 분석·전역 단축키의 UI와 실행 경로, 작업 유지 화면의 중복 잠금 정책 카드는 제거.
- [x] 보호 알림을 각각 선택. 종료 예고·시간 만료는 2026-10-08 사용자 승인으로 제거. OS 권한 상태 조회와 명시적 허용만 제공하며 이전 보호 알림 OFF를 보존.
- [x] 접힌 최근 동작에서 종료 사유·남은 유지 범위 표시. 첫 설치 안내는 유지하고 별도 사용법 창은 2026-10-08 사용자 승인으로 제거.
- [x] MacBook 필수 도우미 준비·구버전/취소/조회 누락 완료 차단, 데스크톱 설치 생략. 일반 실행 책임은 앱에 유지.

[기능 효용 평가](FEATURE-UTILITY-REVIEW.ko.md)는 사용자 요구와 부작용을 객관적 근거로, 반복 조작에서의 효용은 주관적 판단으로 구분한다. 사용자 만족도·소모 전력·비교 앱 성공률은 아직 측정하지 않았다.

## 3. 자동 결과로 대신할 수 없는 항목

- [ ] macOS 26 실제 설치 승인·거부·업데이트·원복, 실행 helper/앱 버전 일치.
- [ ] 실제 닫힌 덮개 유지와 케이블 분리의 **실제 OS Sleep/Wake**.
- [ ] 실제 화면 절전·OS 잠금과 다른 기기의 인증된 원격 프레임/입력/재접속.
- [ ] 실제 사용 환경의 외장/독/데스크톱 및 접근성 최종 확인. 필요한 환경만 추가.
- [ ] 알림을 사용하는 경우 OS 허용·거부·표시 꺼짐/집중 모드와 실제 보호 알림을 확인. 이 승인은 보호 실행의 조건이 아님.

사설 배포여도 실제 앱 교체와 사용자 승인·이관은 별도 게이트다. 개발 후보를 일상 사용·배포 합격으로 표시하지 않는다.

## 4. 직접 조작이 필요한 최소 시험

실행부 연결·원복 재조회·한 번 Sleep 기록·GUI stall 시 전원/열 집행은 모의 입력과 private helper로 확인했다. **시험 직전 후보 hash와 설치본을 대조하고 준비·소유권을 읽은 뒤 에이전트가 수집을 준비해 한 단계씩 안내한다.** 이미 설치된 도우미의 관리자 인증을 다시 요구하지 않는다. 지금 자동 결과만으로 실물 조작을 완료했다고 표시하지 않는다. macOS 26 Apple Silicon MacBook이 주 대상이며 현재 macOS 27의 시험은 보충 근거로 기록한다.

| 완료 | 시험 | 사용자 조작 | 에이전트의 합격 판정 |
|---|---|---|---|
| ☐ | M1 · 기본 AC 닫힘·분리 | 안내 때 덮개 닫기 → 전원 빼기 → 덮개 열기. 열린 상태의 전원 분리도 한 번 추가 | 닫기 전 준비, 닫힌 AC에서 120초 연속 실행·Sleep 없음, 분리 후 자체 원복과 **실제 OS Sleep**, 열린 분리에는 Sleep 요청 없음 |
| ☐ | M2 · 수동 3분 + AC 자동 | 배터리 수동 시작 → 닫기 → 안내 때 AC 연결 → 원래 마감 후 분리 → 깨우기 | 3분에 수동만 만료, AC 자동은 유지, 최종 분리 때 만료 수동 부활 없이 실제 Sleep |
| ☐ | M3 · 유효한 배터리 예외 | AC에서 수동 무제한·3분 배터리 예외를 선택한 뒤 시작 → 닫기 → 분리 → 만료 후 깨우기 | 최초 분리에서 마감 생성, 유효한 동안 유지, 만료 뒤 해제·실제 Sleep. AC 왕복은 마감 변경 없음 |
| ☐ | M4 · 잠금·Sleep·Wake | 안내 때 필요한 로그인/깨우기만 수행. 시험 잠금·macOS 메뉴 Sleep·Tether Sleep은 에이전트가 조작 | 잠금과 Sleep 구별, 전역 덮개 유지의 native Sleep 차단 여부 기록, Tether 자체 원복 후 한 번 Sleep 및 실제 FullWake 확인 |
| ☐ | M5 · 원격 접속·입력·재접속 | 평소 쓰는 다른 기기에서 정상 인증 → 빈 시험 창에 지정 문자 입력 → 재접속. 연결된 채 M1 분리 반복 | 인증·프레임·입력 각각 확인, 타이머/종료 불변, 실제 화면 절전·OS 잠금 별도 판정 |

에이전트가 시간과 상태를 관측해 다음 조작을 안내한다. 사용자가 성공/실패를 결정하거나 시각을 적을 필요는 없다. Sleep 명령 성공·표본 공백·`SleepDisabled=false`만으로 실제 Sleep을 통과시키지 않는다. 화면 절전 관측도 패널 전력 0의 측정으로 표시하지 않는다. 원격 서버 PID·연결 로그만으로 클라이언트 프레임이나 입력을 통과시키지 않는다.

추가 확인은 **실제로 사용하는 환경만** 수행한다.

- [ ] 외장 화면/독/가상 화면을 사용하는 경우 그 조합에서 M1·M5를 반복.
- [ ] macOS 26에서 첫 관리자 승인·거부·helper 설치·업데이트 후 기존 꺼짐/보호 보존. 관리자 인증만 사용자에게 맡기고 나머지는 에이전트가 진행.
- [ ] 데스크톱 Mac도 사용하는 경우 일반 유지·화면 절전·종료를 확인하고 덮개/내장 배터리 옵션이 나타나지 않는지 확인.
- [ ] 안전한 후보의 실물 원복이 검증된 뒤 GUI stall·helper crash 시험. 장애 주입·로그 판정은 에이전트, 물리 깨우기만 사용자.
- [ ] 실제 production 메뉴바 배치와 여러 배경·화면에서의 Liquid Glass 최종 확인. 고대비·투명도 감소·동작 감소는 현재 Mac의 native preview에서 확인했다. VoiceOver 전용 검증은 사용자 결정으로 제외한다.

수면 중 전원 재연결만으로 자동 깨우기, 실제 과열/가방 속 장시간 시험, 배터리 완전 소진은 요구나 합격 조건에 넣지 않는다. 짧은 덮개 통과를 장시간 기기 내구성의 증거로 쓰지 않는다.

## 5. 결과를 보고 결정할 항목

| 아직 결정하지 않을 항목 | 필요한 결과 | 결정 기준 |
|---|---|---|
| Tether를 계속 주력으로 쓸지 | 같은 기기·OS·원격 앱에서 Tether 후보와 Keepresso의 M1/M5 | 둘 다 충족하면 기능 수가 아닌 원하는 조작 수·이유 설명·이관/원복 안정성으로 선택. Tether 우위가 확인되지 않으면 우위라고 홍보하지 않음 |
| 덮개 backend 채택 | macOS 26의 실제 닫힘 유지·분리 Sleep·원복·native Sleep 영향 | `SleepDisabled`는 전역 차단임을 전제로 선택. macOS 메뉴 Sleep 보존이 필수이면 해당 부작용을 숨기고 채택하지 않음 |
| 화면 절전·무잠금·원격 조합 지원 범위 | M4/M5에서 세 상태를 동시에 관측 | 확인된 조합만 지원. 잠금 OFF나 밝기 0만으로 실제 화면 꺼짐+무잠금을 주장하지 않음. 전역 암호 정책을 자동으로 낮추지 않음 |
| 분리 시 종료와 계속 작업의 선택 | M1/M3/M5에서 실제 Sleep 및 원격/타사 작업 영향 | 분리 종료가 우선이면 추천 Sleep 정책. 계속 작업은 명시적 배터리 예외. 자동 감지로 종료 의도를 바꾸지 않음 |
| 사설 업데이트 가능 여부 | 실제 사용 키·게시 피드·실행 중 앱 교체·관리자 승인·v3 이관 | synthetic 서명/교체만 통과하면 로컬 시험 후보. 실제 승인·기존 중지 보존까지 검증 후 사설 배포 |
| v3 일상 사용/배포 승격 | 새 계약, 최소 OS 실물, 원격, 설치·원복 게이트 | 남은 게이트가 있으면 개발 후보로 유지. 자동 검사 통과를 실물·원격 승격 근거로 대체하지 않음 |

macOS 26 이상·Apple Silicon, 자동/수동 분리, 배터리 최대 120분, 심각한 열 보호, 케이블만으로 수면 중 깨우기 제외는 이미 정한 범위다. 위 표 때문에 다시 선택할 필요는 없다. 구체적인 환경 결과가 나와 새로 생긴 선택만 결정한다.


## 6. v3 인수 항목별 기록된 진행 상태

52개 중 **26개는 기재된 검증 층 확인**, **25개는 부분 확인**, **1개는 미실행**이다. 실제 화면·무잠금·원격 입력을 함께 확인하는 R3-029는 자동 시험으로 대체할 수 없다. 확인된 항목의 개수는 제품 전체 합격률이 아니다. 실물 층 24개·원격 층 8개는 일부 같은 조작의 근거를 공유하며 32회의 별도 시험을 요구한다는 뜻이 아니다.

[원본 JSON](REDESIGN-FAILURE-CASES.json)은 층별 결과·실행 로그·scope를 저장한다. 아래 ☑는 그 항목에 **기재된 자동 층만** 확인했다는 뜻이며 OS26 실물 보증이 아니다.

| 상태 | 항목 | 남은 근거 |
|---|---|---|
| ◐ 부분 확인 | R3-001 · macOS26 지원 바닥과 능력 기반 기능 | 실물 |
| ☑ 자동 층 확인 | R3-002 · 일반 실행기와 기종별 필수 준비 분리 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-003 · 새 설치는 전역 덮개 변경을 자동 실행하지 않음 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-004 · 100%·충전중 아님도 AC 조건 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-005 · 열린 AC에서 덮개 실행을 미리 준비 | 실물 |
| ◐ 부분 확인 | R3-006 · 깨어 있고 이미 닫힌 Mac의 AC 연결 | 실물 |
| ☑ 자동 층 확인 | R3-007 · 수면 중 AC 재연결 자동 깨움은 요구에서 제외 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-008 · 닫힌 AC분리에서 자체해제 뒤 한 번 Sleep | 실물 |
| ◐ 부분 확인 | R3-009 · 열린 전원 분리는 Sleep 요청 없음 | 실물 |
| ☑ 자동 층 확인 | R3-010 · 자동 배터리 구간이 유효하면 분리 Sleep하지 않음 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-011 · macOS에 맡기기에서는 자체해제와 실제수면을 구별 | 실물 |
| ◐ 부분 확인 | R3-012 · 추천 Sleep의 타사 작업 영향은 명시하며 원격을 예외로 삼지 않음 | 실물·원격 |
| ☑ 자동 층 확인 | R3-013 · AC 수동 기본범위는 전원 분리에서 종료 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-014 · AC에서 선택한 분리 후30분은 최초 실제전환부터 시작 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-015 · 배터리수동2시간 상한과 실행중기본값변경 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-016 · 수동3분 만료는 AC자동유지까지 끝내지 않음 | 실물 |
| ☑ 자동 층 확인 | R3-017 · 수동배터리마감은 AC왕복·IPC재연결에 불변 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-018 · 자동 배터리 만료가 같은조건에서 즉시재시작하지 않음 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-019 · 둘다 모드 AC를 거쳐도 만료된 자동배터리시간이 부활하지 않음 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-020 · 수동만 종료·자동만 끄기의 범위 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-021 · 전체 일시중지는 재시작·Wake·업데이트로 부활하지 않음 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-022 · 시계변경과 수면은 기간을 연장하지 않음 | 실물 |
| ◐ 부분 확인 | R3-023 · 명시적 잠금과 실제 OS 수면 통지는 다르게 처리 | 실물 |
| ☑ 자동 층 확인 | R3-024 · fair와 serious/critical 보호를 구별 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-025 · 잔량하한·OS저전력 경고는 수동배터리예외에도 적용 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-026 · 전원·열·잔량 조회 실패는 정상으로 위조하지 않음 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-027 · OS즉시암호 정책과 앱잠금OFF의 의미를구분 | 실물 |
| ◐ 부분 확인 | R3-028 · OS잠금관측 unknown은 unlocked가 아님 | 원격 |
| ☐ 미실행 | R3-029 · 실제화면절전·무잠금·원격입력은 동시 별도실증 | 실물·원격 |
| ◐ 부분 확인 | R3-030 · 전체 displaySleep 명령을 내장전용으로 자동사용하지 않음 | 실물·원격 |
| ◐ 부분 확인 | R3-031 · 원격 감지는 작업 수명·아이콘 폭을 바꾸지 않음 | 원격 |
| ◐ 부분 확인 | R3-032 · 외장 화면과 virtual 화면으로 자체 종료를 조기위임하지 않음 | 실물·원격 |
| ◐ 부분 확인 | R3-033 · 외부 SleepDisabled를 자기소유로 채택하지 않음 | 실물 |
| ◐ 부분 확인 | R3-034 · 동일 bool을 타사가 쓰면 완전 소유자 식별은 불가능 | 실물 |
| ☑ 자동 층 확인 | R3-035 · 변경 전 journal과 crash 시점별 복구 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-036 · 원복 실패·오염된 자료를 삭제하지 않음 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-037 · 앱 정지·helper crash는 종료와 원복을 구별 | 실물 |
| ◐ 부분 확인 | R3-038 · 분리 종료 마지막 검사 전 상태 변경·late response | 실물 |
| ☑ 자동 층 확인 | R3-039 · root는 자동트리거를 시작하지 않는 좁은 실행기 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-040 · 이전 설정의 off/보호/선택만 이관 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-041 · legacy 원복 실패 때 일반기능과 새전역쓰기를 분리 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-042 · 설치 cancel/rollback은 최신 사용자 설정을 보존 | 기재된 층 확인 완료 |
| ☑ 자동 층 확인 | R3-043 · 설치 수명 mutex와 복구 lock의 교착 방지 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-044 · 사설 SMAppService 등록·승인·실행을 구별 | 설치·실물 |
| ☑ 자동 층 확인 | R3-045 · 진단 저장은 제한하며 사용자가 요청할 때만 내보냄 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-046 · 메뉴바·다크·작은창의 가독성 및 조작 상태 | UI·실물 |
| ◐ 부분 확인 | R3-047 · 전역 덮개 유지의 native Sleep 한계와 자체 잠자기의 해제 순서 | 실물 |
| ☑ 자동 층 확인 | R3-048 · 자체 잠자기 미확인·재실행에서 자동 획득 부활 방지 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-049 · GUI가 응답하지 않아도 닫힌 AC 분리의 허가 해제와 Sleep 집행 | 실물·원격 |
| ☑ 자동 층 확인 | R3-050 · 자동 ON/OFF는 조건과 수동 요청을 보존하고 전체 중지를 해제하지 않음 | 기재된 층 확인 완료 |
| ◐ 부분 확인 | R3-051 · 닫힌 AC 무제한 유지 중 열 보호는 GUI stall·자동 ON보다 우선 | 실물·원격 |
| ◐ 부분 확인 | R3-052 · 닫힌 배터리 예외가 유효해도 심각한 열 상태에서는 보호 종료 | 실물 |
