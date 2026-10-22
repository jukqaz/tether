# 모든 Mac의 작업 유지와 원격 앱 협력 계약

2026-10-06: **아래는 이전 설계·구현의 기록이다. 다음 구현의 계약·근거로 사용하지 않는다. 현재 기준은 [새 기능 정의](PRODUCT-SPEC.ko.md), [실행 설계](ARCHITECTURE-REDESIGN.ko.md), [새 조사](COMPETITOR-DEEP-RESEARCH.ko.md)다. 과거 검증 결과를 v3 합격으로 재사용하지 않는다.**

2026-09-30 · macOS 15 이상을 실행하는 Apple Silicon Mac 전체가 대상이다. [기능 정의](PRODUCT-SPEC.ko.md)·[아키텍처](ARCHITECTURE-REDESIGN.ko.md)·[기기별 지원](APPLE-SILICON-SUPPORT.ko.md)을 구체화한다. 이 문서는 구현 계약과 현재 미배포 후보의 범위를 구분하며 설치본의 데스크톱·원격 호환 시험 완료를 뜻하지 않는다.

## 현재 후보에 적용한 부분

빌드 50 소스에 `RemoteInteropContext`·metric별 `RemoteObservation`과 공개 번들 기반 `RemoteProviderProbe`를 추가했다. 제품·host/viewer·설치/실행/클라이언트 버전을 분리하고, 접속·프레임·입력·인증은 지원되는 관측이 없으면 `nil/unavailable`로 둔다. 현재 Probe는 실제 원격 성공을 생성하지 않는다. 각 성공은 자기 출처·시각·scope·확인된 버전이 모두 유효해야 하며 힌트·설치 정보·과거 물리 시험을 현재 성공으로 승격하지 않는다. 화면·GUI 세대 변경과 수집 뒤 실제 inventory 재대조로 오래된 context를 폐기한다.

작업 유지 화면의 원격 상세와 사용자 요청 진단 보고서에 이 구분을 적용했다. 공급자별 공식 설정 안내는 현재 설정 읽기 결과가 아니며 TCC·공급자 비공개 설정·계정·접속 주소를 읽지 않는다. Splashtop의 [read-only API](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/52521431405467-Read-only-APIs)는 Enterprise 자격을 필요로 하고 RustDesk의 [audit API](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/audit-logs/)는 Server Pro 경로이므로 무료 공통 기능의 필수 의존성으로 삼지 않는다. 현재 빌드는 이 API들을 연결하거나 자격증명을 저장하지 않는다.

화면 재연결은 이미 소진한 회복 횟수나 재시도 간격을 초기화하지 않는다. 추가/가상 화면과 조회 불명은 화면 명령만 보류하고 작업 lease·수동 마감·배터리 예산을 보존한다. 공통·이전 경로의 수정 전 4건 재현 뒤 포장 화면 17개·원격/가상 정책 27개가 통과했다. 전체 Swift 654개에는 새 원격 계약 7개·Inspector 7개·회복 4개가 포함된다. [Preview·포장 확인과 한계](COMMON-SESSION-PREVIEW-20261001.ko.md).

2026-10-02 추가 수정은 가상/외장 화면 때문에 내장 화면 관측 안내가 숨는 경계를 보완했다. 현재 30초 이내 내장 화면 관측으로 절전/켜짐/미확인을 표시하며 이전 화면 구성의 recovery phase를 현재 성공으로 쓰지 않는다. 작업 유지와 시간 한도는 그대로다. [Apple의 CGDisplayIsAsleep](https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep%28_%3A%29)은 화면 절전 관측이며 패널 소비 전력 0이나 원격 입력·무잠금의 증거가 아니다. Apple [고성능 화면 공유의 가상 화면](https://support.apple.com/en-mn/guide/mac-help/mchl1883115d/mac)은 원격 렌더링에 사용될 수 있으므로 가상 화면을 끄라는 일반 안내를 하지 않는다. 전체 Swift 792개·실제 격리 helper를 통한 현재 표시 회귀의 범위는 [설계 재검토](ARCHITECTURE-REVIEW.ko.md)를 따른다. 위 654개는 이전 검증 시점이다.

아래 `RemoteInteropPlan`·공급자 실시간 adapter·MR-G-01~04 실기기 행렬은 남은 계약이다. 원격 실측, 자동 무잠금, 모든 원격 앱 호환 완료를 선언하지 않는다. 설치본 49와 시스템 잠금/전원 설정은 변경하지 않았다.

## 화면 절전과 자동 잠금의 기술 검증

공개 API와 공급자 공식 경로를 다시 대조한 결과, 현재 후보에 자동 무잠금을 보장할 수 있는 구현은 없다. 단순히 물리 시험만 남았다는 뜻이 아니다. 생산 `RemoteProviderProbe`는 프레임·입력·인증·실제 연결을 관측하지 못하고, 현재 잠금 정책이나 잠금 상태를 안정된 API로 읽는 경로도 없다. `RemoteProviderState.liveReady`는 네 원격 전달 metric의 유효성만 검사하므로 F-04의 무잠금 합격 판정으로 사용하지 않는다. 과거 `RemotePhysicalVerification`도 현재 상태나 자동 센서의 대체물이 아니다.

| 확인한 경로 | 확인된 동작 | 채택 결정 |
|---|---|---|
| Apple [시스템 유휴 절전 방지](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep) | 화면 유휴 절전을 허용하면서 시스템 유휴 잠자기를 방지 | 공통 작업 유지에 사용. 자동 잠금 면제를 주장하지 않음 |
| Apple [화면 유휴 절전 방지](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep) | 유휴 화면 꺼짐을 방지. 이미 꺼진 화면을 켜거나 잠금 면제를 보장하는 계약이 아님 | 실제 화면 절전과 무잠금을 동시에 달성한 것으로 취급하지 않음 |
| Apple [사용자 활동 선언](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity) | 화면을 켜고 유휴 화면 절전을 연기 | 실제 원격 공급자가 처리하는 입력과 별개. Tether가 주기적으로 가짜 활동을 만들지 않음 |
| Splashtop [read-only API](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/52521431405467-Read-only-APIs) | Enterprise 세션 로그·사건 조회 | 무료 공통 기능에 필수화하지 않음. 프레임·입력 성공이나 무잠금 증거로 확대하지 않음 |
| RustDesk [정식 1.4.9 내부 IPC](https://github.com/rustdesk/rustdesk/blob/1.4.9/src/ipc.rs) | `VideoConnCount`가 인증된 Remote 연결 수를 계산 | 외부 지원 API가 아니며 프레임·입력·무잠금의 증거도 아님. 내부 IPC 접근이나 master 전용 요청을 채용하지 않음 |

후보의 원격 점검 화면에는 기존 `AppModel.open(.lockScreen)`로 시스템 설정을 여는 버튼을 연결했다. 실제 설정명, Tether 밖에서도 적용되는 범위, 관리 정책 제한을 설명하며 현재 설정값을 읽었다거나 원인을 확정했다고 표시하지 않는다. Preview에서는 이 버튼을 비활성화한다. 설정값·암호 요구·원격 앱 설정은 변경하지 않는다. Apple의 [화면 꺼짐 후 암호 요구 안내](https://support.apple.com/en-mo/guide/mac-help/mchlp2270/mac)를 따른다.

따라서 다음 합격 근거는 지정한 원격 클라이언트에서 장시간 화면 절전 후 실제 프레임·입력·잠금 상태를 함께 확인한 결과다. 로컬 버튼 입력이나 모의 공급자 응답을 원격 왕복 성공으로 기록하지 않는다. 기존 정책에서 F-03/F-04가 함께 성립하지 않는다면 구체적인 설정 변경 범위를 사용자에게 제시하는 별도 단계가 필요하다. 전역 보안을 몰래 완화하는 코드나 새로운 추상화만으로 이 기술 검증을 완료하지 않는다.

## 1. 제품의 공통 부분과 기기별 부분

Tether의 공통 기능은 절전 방지 세션, 선택한 자동 유지, 시간 종료, 발열 보호, 다른 앱 요청과의 공존, 복구·업데이트·진단이다. 클램쉘과 배터리는 내장 배터리·덮개가 있는 기기의 추가 기능이다. 앱 전체를 MacBook 전용으로 판정하지 않는다.

| 구성 | 공통 작업 유지 | 추가 처리 | 기본 동작 |
|---|---|---|---|
| Apple Silicon 노트북 | 공개 idle assertion과 세션/시간 계약 | 지원이 확인된 덮개 실행기, 내장 배터리 시간·잔량 보호 | 기존 전원 선택 보존. 닫기 전 준비 상태 확인 |
| Mac mini·Mac Studio·Mac Pro | 같은 세션·시간·발열·원격 협력 계약 | 배터리/덮개는 해당 없음 | 설치 직후 유지 없음. 수동 시작 또는 사용자가 켠 자동 유지 |
| iMac | 같은 공통 계약, 내장 화면 절전 관측 | 내장 화면이 있어도 덮개가 있다고 해석하지 않음 | 배터리/클램쉘 UI 없음 |
| 화면 없는 데스크톱 | 같은 공통 계약 | 제어할 패널이 없다는 사실과 원격 화면 공급 실패를 구별 | 관리자 덮개 제어·전체 화면 절전 명령 없음 |
| UPS가 연결된 데스크톱 | 같은 공통 계약 | UPS는 외부 전원 관측. 노트북 내장 배터리로 변환하지 않음 | UPS 설정·자동 종료를 관리하지 않음 |
| 기기/센서 조회 일시 실패 | 이미 확인한 특성을 보존 | 기능별 관측 유효성으로 신규 작업을 제한 | 노트북을 데스크톱으로 바꾸거나 앱 전체를 차단하지 않음 |

기기 형태와 화면 구성은 독립적이다. 내장 화면이 없음은 미지원 증거가 아니고, 내장 화면이 있음은 노트북 증거가 아니다. 모델명·M 계열 문자열로 Apple Silicon 기기를 허용/거절하지 않는다. 필요한 API가 없으면 그 기능만 제한한다.

일반 작업은 관리자 설치 없이 자체 공개 assertion으로 유지한다. 데스크톱에 전역 SleepDisabled나 덮개 lease를 만들지 않는다. 사용자 잠자기·로그아웃은 존중하며 보통의 세션 종료는 자체 assertion 해제다. 열린 노트북과 데스크톱에 자동 sleepnow를 보내지 않는다.

## 2. 데스크톱의 세션·자동 유지·UI

- 수동 세션은 시간 제한 또는 명시적 종료까지의 유지를 선택할 수 있다. 배터리의 최대 시간·잔량 조건을 데스크톱에 억지로 적용하지 않는다. idle assertion의 건강성 만료는 무기한 선택에도 적용한다.
- 데스크톱 자동 유지는 초기값 off다. 사용자가 명시적으로 켠 경우 앱 시작·설정 변경·완전한 깨움에서 현재 전원 조건을 평가한다. 물리 케이블 edge만 기다리지 않는다.
- 데스크톱은 내장 배터리가 없으므로 배터리만/배터리 연속 사용을 숨기고 API 요청도 notApplicable로 거절한다. 자동 유지의 화면 문구는 실제 의미를 드러내는 '전원 연결 중 자동 유지'로 둔다. UPS·전원 조회 unknown을 AC로 위장하지 않는다.
- UPS 구성의 선택한 AC 조건이 끝나면 자체 요청만 해제한다. UPS 전원 여부를 읽지 못하면 자동 조건은 확인 필요로 두며 수동 공통 기능의 가용성과 분리한다.
- 동일 AC 관측 1,000회가 세션을 1,000개 만들지 않는다. 수동 종료는 현재 자동 활성화를 억제하고 앱 재시작으로 부활하지 않는다.
- 공통 시간 입력은 양쪽 기기에서 재사용하고, 배터리 추가 한도는 내장 배터리가 있는 경우에만 보여 준다. 여러 유지 이유가 있으면 유효한 이유가 모두 끝나기 전에는 작업 유지가 끝났다고 표시하지 않는다.
- 설정은 기존 작업 유지·기기 보호·앱 설정 세 화면을 유지한다. 없는 센서/기능을 오류 배너로 반복 노출하지 않는다.

## 3. 원격 앱과의 협력 방식

원격 앱을 설치하거나 실행한 사실만으로 접속·화면 수신·입력 성공을 판정하지 않는다. Tether는 원격 앱을 제어하는 플러그인 호스트가 아니라 공통 전원·화면 정책을 조정하는 앱이다.

| 영역 | 근거 | Tether의 처리 |
|---|---|---|
| 원격 사용 의도 | 선택적인 호환 확인·진단 정보 | 별도 원격 모드 선택 없이 기본 기능 사용. 화면 요청만 조정하며 새 유지 사유나 배터리 예산을 만들지 않음 |
| 실제 시스템 유지 요청 | 최신 IOKit assertion 종류·활성 수준·소유자 | 정상 공존. 자체 요청 종료와 Mac 전체 잠자기를 구별 |
| 화면 필요 요청 | 유효한 외부 display-idle 요청·활동 | 위험한 전체 화면 절전 요청을 보류. 접속 중의 확정 증거로 쓰지 않음 |
| 화면 구성 | CoreGraphics 관측과 검증된 물리/가상 분류 | 원격 가상 화면을 물리 클램쉘로 넘기지 않음 |
| 연결·프레임·입력 | 지원되는 공급자 관측 또는 실제 원격 시험 | 각각 별도 상태. PID·가상 화면·열린 포트로 대체하지 않음 |
| 앱/OS 잠금 설정 | 버전·제품군에 맞는 공식 지원 경로와 실제 설정 확인 | 필요한 설정으로 안내. 현재 값을 못 읽으면 원인 후보로 표시 |

원격 연결/해제는 그 자체로 시스템 유지의 새 시작/종료 사유가 아니다. 전원 조건·사용자 세션·배터리 예산·보호 정책이 작업 수명을 결정한다. 원격 앱의 요청이 남으면 Tether 종료 뒤에도 그 앱의 요청을 보존한다. 여러 원격 앱 중 하나가 끊겼다고 다른 연결의 화면 의도까지 지우지 않는다.

기본 협력은 앱 이름과 무관하게 적용한다. 첫 검증 대상은 실제 사용하는 Splashtop, macOS 화면 공유, RustDesk다. 그 밖의 원격 앱도 공통 assertion/화면 계약을 적용하되 앱별 호환 완료로 표시하려면 해당 버전의 실측 근거가 필요하다.

## 4. 관측과 조정 계약

다음은 전체 계약의 책임을 나타내는 개념 구조다. 위 현재 후보 타입과 필드가 완전히 같다는 뜻이나 공급자별 공개 실시간 API가 존재한다는 선언은 아니다.

~~~text
RemoteInteropContext
  remoteUseExpected
  providerCandidates, activeDisplayNeeds
  connection, frameDelivery, inputRoundTrip
  authenticationState, configurationIssues
  observedAt, source, freshness, displayRevision, generation

RemoteInteropPlan
  deferAllDisplaySleep, reason, notices, noticeKey
  verificationScope
  // power/session start, budget reset, unlock, process termination 없음

ProviderEvidence
  provider, productEdition, hostAppVersion, clientAppVersion
  source = publicAPI | providerReported | physicalVerification | hint
  availability = known | unavailable | notApplicable
~~~

RemoteInteropCoordinator는 관측을 정규화해 사용자 세션 조정자와 DisplayCoordinator에 전달한다. 별도 전원 작성자나 두 번째 assertion 소유자가 아니다. 공급자별로 확인 가능한 증거만 좁게 제공하고 일반 플러그인/스크립트 실행 API를 만들지 않는다.

OS 공유 서비스는 GUI 앱 PID가 없을 수 있으므로 NSRunningApplication 목록만으로 판정하지 않는다. 반대로 서비스 프로세스가 살아 있어도 실제 접속 성공이 아니다. 원격 앱만 공급할 수 있는 권한·접속 정보를 공개 경로로 받지 못하면 unavailable을 유지한다.

현재 구성의 미지원과 공급자 전체 API 부재는 구분한다. Splashtop은 Enterprise 구독과 토큰/OAuth를 사용하는 공식 세션 조회 API를 제공하므로 ‘공개 경로가 없다’고 일반화하지 않는다. 무료 기본 경로에서 해당 계정 연동을 추가하지 않으며 세션 기록을 프레임 수신·입력 성공으로 승격하지 않는다. [공식 API 자격·인증](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/16772899906459-Splashtop-Open-APIs) · [읽기 전용 세션 로그/이벤트 API](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/52521431405467-Read-only-APIs). RustDesk의 내부 연결 수 IPC는 외부 지원 계약이 확인되지 않았고 일부 통합 조회는 오류와 연결 존재를 같은 값으로 반환한다. 이를 기본 실측 adapter로 도입하지 않는다. [IPC 구현](https://github.com/rustdesk/rustdesk/blob/master/src/ipc.rs) · [updater 구현](https://github.com/rustdesk/rustdesk/blob/master/src/updater.rs).

Tether 자신의 화면 기록/접근성 승인 상태를 다른 앱의 승인 상태로 사용하지 않는다. 다른 앱의 TCC 데이터베이스나 비공개 설정을 우회 조회하지 않고 권한을 자동 부여·초기화하지 않는다. 안내에는 승인 대상 앱을 명시한다. 이 기능을 위해 Tether 자체에 불필요한 화면 기록·접근성 권한을 요구하지 않는다.

늦은 원격 관측에는 generation·화면 구성 revision·시각을 확인한다. 재연결·화면 변경으로 무효화된 성공을 현재 ready로 게시하지 않는다. 힌트의 사라짐이나 네트워크 지연으로 자체 전원 세션을 종료하지 않는다.

연결·프레임·입력·인증은 각각 별도의 Observation과 freshness를 갖는다. 연결 heartbeat가 도착했다고 오래된 입력 성공의 시각까지 갱신하지 않는다. 성공의 유효 범위는 현재 사용자 세션·공급자 제품군/버전·OS·화면 revision에 묶고 사용자 전환·업데이트·화면 변경 뒤에는 다시 확인한다. 공급자 보고는 지원되는 경로와 공급자 신원을 확인한 경우만 증거로 받으며 임의 외부 메시지를 접속 성공으로 인정하지 않는다.

## 5. 화면·잠금·입력의 충돌 처리

| 상황 | 시스템 유지 | 화면/원격 처리와 표시 |
|---|---|---|
| 원격 연결 중 화면 필요 요청 | 기존 유효 세션 지속 | 전체 화면 명령 보류. 실제 패널 절전 확인은 별도 |
| 네트워크 일시 단절·재접속 | 기존 전원·시간·보호 조건 유지 | 연결 확인 중. 잠금·잠자기 명령이나 예산 재충전 없음 |
| 화면은 보이지만 입력 실패 | 자체 유지 지속 | 대상 원격 앱의 입력 권한·설정 확인 안내 |
| headless 원격 화면 수신 실패 | 자체 유지 지속 | 공급자 화면 경로 확인 필요. CPU 활동을 화면 정상으로 계산하지 않음 |
| 원격 앱의 종료 후 잠금 설정 | 자체 요청 상태와 독립 | 버전별 설정 확인 안내. OS 자동 잠금 또는 Tether가 원인이라고 단정하지 않음 |
| 사용자가 직접 잠금·잠자기·로그아웃 | 명시적 의도 존중 | 자동 해제·가짜 입력 없음. 로그아웃 시 사용자 세션 복구 |
| 전원 조건 종료·배터리/발열 한도 | 자체 유지 종료 | 원격 연결은 보호 우회 사유가 아님. 외부 유지는 보존하고 실제 Sleep을 따로 확인 |
| 물리 모니터 분리/재연결·가상 화면 추가 | 최신 책임 범위를 재평가 | 검증 전까지 물리 위임·전체 화면 끄기 보류 |

실제 화면 절전과 무잠금·원격 입력을 함께 확인하는 요구는 유지한다. 개별 패널을 안정적으로 제어할 수 없는 구성에서 원격 framebuffer까지 반복해서 끄거나 밝기 0·가짜 사용자 활동으로 성공을 대신하지 않는다. 화면/원격 제한이 발생해도 정상 시스템 유지는 계속 제공한다.

자동 잠금의 원인은 OS 암호 요구 정책, 원격 앱의 세션 종료 설정, 조직 정책, 명시적 사용자 동작을 구별한다. 현재 설정의 증거 없이 한 원인으로 확정하지 않는다. 원격 공급자의 사생활 보호용 검은 화면 역시 패널 절전과 다른 기능이다.

## 6. 먼저 검증할 공급자와 공식 근거

| ID | 근거 | 설계에 적용할 내용 |
|---|---|---|
| C-01 | [Apple 화면 공유](https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac) | 화면 공유와 Remote Management의 동시 활성화 제한. 서비스 상태·사용자 허용·실제 접속을 분리하고 Tether가 두 설정을 자동 전환하지 않음 |
| C-02 | [Splashtop headless 화면 안내](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/360037225171-How-to-fix-black-blank-windows-when-establishing-a-remote-session-to-a-headless-Mac) | 모니터 없는 Mac의 빈 화면이 절전 방지 하나로 해결되지 않을 수 있음. 공급자/버전별 프레임 수신을 시험. 가상 화면 생성·dummy 장치를 Tether 기본 해법으로 추가하지 않음 |
| C-03 | [Splashtop Streamer 설정](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/360041097071-Streamer-Settings-Overview) | 세션 종료 후 잠금·세션 유휴 종료·화면 처리 설정이 별도로 존재. 제품군/OS/버전에서 실제 제공하는 설정인지 확인하며 값은 임의 변경하지 않음 |
| C-04 | [RustDesk macOS 권한](https://rustdesk.com/docs/en/client/mac/) | 화면 기록·접근성·해당하는 입력 모니터링을 구별. RustDesk의 승인과 Tether의 승인을 혼동하지 않음 |
| C-05 | [현재 앱 지원 판정](../Sources/TetherCore/System/SystemProbe.swift), [보호 입력](../Sources/TetherCore/Policy/SafetyPolicy.swift), [가상 화면 분류](../Sources/TetherCore/System/DisplayProbe.swift) | 배터리+덮개 전체 차단과 배터리 잔량 필수 조건을 기능별로 분리. 가상 공급자 hint는 실제 원격 접속 증거가 아님 |

공식 문서는 필요한 조건·알려진 제한의 근거다. 세 앱을 같은 기기에서 실행한 결과가 아니며 앱별 호환 성공 표를 대신하지 않는다. macOS 15와 실제 지원 최신 정식 버전, 원격 앱 제품군·호스트/클라이언트 버전을 고정해 별도 결과를 기록한다.

## 7. 로그와 사용자 흐름

메뉴바의 대표 상태는 작업 유지 여부다. 실제 조치가 필요하면 '원격 앱의 입력 권한 확인', '원격 화면 확인 중', '화면 끄기 보류'처럼 좁은 원인을 한 번 표시한다. 앱이 설치되어 있다는 이유만으로 충돌 경고를 띄우지 않는다.

원격 상세는 작업 유지 화면의 '원격 사용 확인'에 모은다. 공급자·버전·설정/관측 가용성·최종 시험 범위를 보여 주며 실제 접속을 관측하지 못하면 '접속 확인 필요'로 표시한다. 정상 공존은 배너가 아니고 상세 정보다. 원시 PID·프로토콜·화면 ID는 진단 상세에 둔다.

로그는 세션 ID, 사건 번호, 전원·화면 revision, 관측 출처·시각, 조정 결정, 적용 결과, 자체/외부 요청의 구분을 남긴다. 원격 암호·접속 주소·계정·화면 내용·키 입력·문서명은 기본 기록에 포함하지 않는다. 키 입력 성공 시험에는 내용 대신 비민감 시험 표식의 성공 여부만 저장한다.

## 8. 이관·배포·완료 기준

기존 노트북의 전원 선택·수동 종료·보호 차단은 보존한다. 다른 기기에서 설정을 가져올 때 원본 선택을 지우지 않고 현재 기기에 해당 없는 기능만 비활성화한다. 노트북의 배터리/덮개 선택을 데스크톱 무기한 자동 유지로 바꾸지 않는다.

사용자 로그아웃·FileVault 부팅 전 인증·원격 앱 자체 서비스는 사용자 앱이 실행 중인 세션과 별개다. Tether가 부팅 전 로그인을 우회하거나 원격 앱 서비스의 실행을 보장하지 않는다. 로그아웃/재부팅의 자체 원복과 원격 공급자의 재접속은 별도 결과로 기록한다.

같은 GUI 세션의 잠금과 다른 사용자로의 전환도 구별한다. 최초 버전은 OS가 확인한 제어 GUI 세션에 lease를 묶고, 다른 세션으로 바뀌면 옛 소유자의 갱신/새 획득을 막고 자체 유지 종료/복구만 수행한다. 잠금 자체를 사용자 전환으로 처리하거나 원격 서비스 UID에 소유권을 넘기지 않는다. 다른 사용자의 작업을 강제 잠자기로 끊지 않는다. [추가 집행 규칙](DESIGN-GAPS.ko.md#2-이번에-확정한-집행-규칙).

업데이트는 데스크톱에 덮개 열림을 요구하지 않는다. 현재 사용자 세션의 안전한 종료·자체 assertion 원복·도우미 호환성은 해당 기능에 맞게 검사한다. 일반 desktop idle 기능에 도우미 업데이트 실패를 전파하지 않는다.

QA-51~64를 [추가 장애 데이터](MAC-REMOTE-FAILURE-CASES.json)에 정의한다. 이는 기대값이고 실행 결과가 아니다. [기능 정의의 합격 표](PRODUCT-SPEC.ko.md#11-합격-시나리오)와 기존 I-01~18을 함께 적용한다.

- MR-G-01: Apple Silicon 데스크톱에서 도우미 없이 시작·시간 만료·중지·화면 절전·발열 모의 보호·자체 ID 해제를 확인한다.
- MR-G-02: Splashtop·Apple 화면 공유·RustDesk별 연결·프레임·입력·장시간 화면 절전·재접속을 열린/닫힌 노트북과 데스크톱에서 확인한다. 없는 표본은 미실측으로 둔다.
- MR-G-03: headless·물리 화면·가상 화면·미러링·독 변경을 구별하고 설정/권한/잠금의 원인과 실제 Sleep을 대조한다.
- MR-G-04: 여러 외부 요청·네트워크 단절·로그아웃·업데이트에서 자체 원복, 정상 외부 요청 보존, 예산/세션 부활 없음을 확인한다.

구현 순서는 기능별 지원과 공통 assertion → 데스크톱 세션/설정 이관 → 원격 관측/화면 협력 → 실제 기기·원격 시험이다. 미배포 빌드 50에 [공통 앱 정책](COMMON-SESSION-20261001.ko.md), [CLI 연결](USER-COMMAND-COORDINATOR-20261001.ko.md), [기존 설정 인계](SESSION-HANDOFF-20261001.ko.md), [실행 중 기기 재판정](CAPABILITY-REFRESH-20261001.ko.md), [배터리 전용 조작 제한](BATTERY-CAPABILITY-20261001.ko.md)을 통합하고 단계별 회귀를 확인했다. MR-G-01~04의 실제 기기·원격 공급자 행렬은 아직 미실시이며 일반 idle 시험과 fixture를 그 합격으로 확대하지 않는다.
