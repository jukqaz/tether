# Tether 차기 기능 수집·통합안

> **문서 분류 · 2026-10-21: 역사 자료 — 2026-10-16 41묶음 기능 수집 이력.** 본문은 당시의 선택·근거로 보존한다. 현재 범위·기본값은 [기능명세서](PRODUCT-SPEC.ko.md), 새 수락 조건은 [현행 검증표](V5-VALIDATION-CHECKLIST.ko.md)를 따른다. 아래의 ‘현재·최신·최종’과 합격 수는 당시 대상에 한정하며 현재 전체 기능의 완료를 뜻하지 않는다.

2026-10-16 · 조사·설계 문서. 현재 앱 코드·설치본·전원·보안·네트워크 설정은 변경하지 않았다.

**후속 설계:** 사용자가 기능명세·충돌/기본값·메뉴/설정 시안을 요청해 [V5 명세](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V5.ko.md), [검증 체크리스트](archive/2026-10-21-spec-cleanup/V5-VALIDATION-CHECKLIST.ko.md), [디자인 계약](archive/2026-10-21-spec-cleanup/DESIGN-V5.ko.md)으로 구체화했다. 이 문서의 후보를 채택 형태별로 연결했으며 앱 구현·설치는 하지 않았다.

## 1. 이번 사용자 지시와 판단 기준

사용자가 **‘기존에 유지하라고 했던 규칙들 잠시 무시하고 다른 앱들 다 찾아서 장점들만 싹다 가져올 것’**을 요청했다. 직전의 ‘핵심 규칙 유지·나머지 옵션 확장’ 결정은 **이번 기능 조사·차기 설계의 제한으로 사용하지 않는다.**

따라서 AC 전용 자동·배터리 최초2시간·분리 때 전 요청 종료·배터리 승계 제외뿐 아니라 직접 시간 입력·반복 알림·밝기/활동/팬·예약 깨우기·GUI 종료 후 작업 유지 등의 기존 제외 결정도 재검토 대상이다. 무료/유료·본체 공개 여부·오래된 버전·작은 프로젝트 때문에 기능 아이디어를 미리 제외하지 않는다. 유지보수·근거의 강도는 별도 표시한다.

현재 후보58의 실행 계약과 과거 검증은 [v4 명세](archive/2026-10-21-spec-cleanup/PRODUCT-SPEC-V4.ko.md), [구현·검증 결과](IMPLEMENTATION-V4-20261015.ko.md)에 보존한다. 이번 조사를 이유로 기존 사용자의 동작을 바꾸거나 새 기능을 구현 완료로 표시하지 않는다. 앱에 적용할 새 정책·기본값과 UI 시안은 다음 설계 단계에서 확정한다.

### 조사 범위와 근거

- 공식 제품·개발자·App Store·GitHub 자료로 **34개 제품/도구**를 분류했다. 대표 앱15개·공개소스/레거시13개·인접 도구6개다. 전 세계 앱의 누락 없는 전수조사라는 뜻은 아니다. OS 기본 `caffeinate`·Shortcuts는 별도 기준이다.
- `코드`는 공개 구현 확인, `출시 설명`은 현재 공식 기능/변경 기록, `레거시`는 오래된 구현/UX 참고, `인접`은 전원 유지 외 전문 도구라는 뜻이다. 코드 열람도 실물 시험은 아니다.
- 릴리스·개발 브랜치·대상 OS·플랫폼을 구분한다. 별점·별 수·다운로드 수를 안정성/활성 사용자 수로 환산하지 않는다. 구체적 수치를 확인하지 않은 앱을 인기 앱으로 표현하지 않는다.
- 경쟁 앱의 장점은 사용자 흐름·정책·복구 원리를 뜻한다. 소스 직접 편입은 이번 작업에서 하지 않았다. 공개 저장소도 본체 전체·배포판과 같다는 뜻이 아니며 파일별 출처/라이선스가 다를 수 있다.

## 2. 앱별로 가져올 장점

### 대표 절전방지·메뉴 앱

| 제품 | 확인 기준 | 가져올 장점 | 적용할 때 구분할 것 |
|---|---|---|---|
| [Keepresso](https://github.com/gyorgysh/keepresso/blob/v1.27.0/README.md) | 정식1.27.0·기존 고정 코드·GPL-3.0 | 광범위 조건·프리셋·AI hook/MCP lease·상태/결정 기록·메뉴 사용자화·화면/팬/네트워크 모듈 | 평면 any/all과 중첩 그룹 구분. 선택 모듈의 실제 권한·유지·원복은 독립 인수 |
| [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) | 공식 최신5.3.2(2023-11-10)·본체 비공개 | 기간/시각/무제한·앱/다운로드 수명·트리거·작업별 화면/덮개·Drive Alive·빠른 세션 조작 | 현재 Store metadata 최소10.13과 오래된 소개의10.11이 다름. 옛 Enhancer/Power Protect를 현재 본체 코드로 간주하지 않음 |
| [Lungo](https://sindresorhus.com/lungo) | Store2.8.3·현재macOS26+·출시 설명 | 좌/우 클릭 선택·저장된 기본시간·색 외 활성 badge·잠금/전원 변화 선택·Shortcuts/URL | 기본모드의 한 클릭성과 고급 기능을 분리. 사용자 시간/시각 직접 입력은 제공하지 않음 |
| [Caffeinated](https://apps.apple.com/us/app/caffeinated-anti-sleep-app/id1362171212?mt=12) | Store3.2.0·macOS15+·출시 설명 | 클릭 정책·사용자 시간·알림·accent/Graphite·자동화 액션 | 최신3.2.0의 덮개 유지 추가와 기존 [FAQ](https://caffeinated.app/helpcenter/)의 불가 설명이 충돌. 새 기능은 실제 인수 필요 |
| [Theine](https://appahead.studio/apps/theine/) | 공식4.3·2026-10·macOS15.6+ | 발표/집중 프로필: 유지+Hide Desktop+Focus Dim, 시간 메뉴·기본시간·동작 줄이기 | 부가 화면 정리와 전원 유지를 독립 토글로 구성 |
| [Owly](https://apps.apple.com/us/app/owly-prevent-display-sleep/id882812218?mt=12) | Store2.5·출시 설명 | 시간 grid·전원/앱/overnight 일정·잔량 하한·메뉴/Dock 남은 시간·modifier 조작 | Store의 Display Only와 [Help](https://support.fiplab.com/owly/duration-modes)의 Allow Display Sleep 설명이 반대. 명확한 시스템/화면 선택으로 재설계 |
| [One Switch](https://fireball.studio/oneswitch) | 현재 공식 배포 확인·최신 버전 미확정 | 유지·화면보호기·바탕화면 숨김·관련 기기 조작을 선택형 한 패널에 모으는 UX | 다른 스위치를 묶어 실행하지 않음. 과거1.19 기록을 최신 버전으로 표시하지 않음 |
| [Wimoweh](https://apps.apple.com/us/app/wimoweh/id610341008?mt=12) | 1.1.68(2020-01-08)·레거시 | 방해 앱/이유 설명·평균 작업량·LAN 서비스 존재 조건·modifier click | LAN 도달 가능은 실제 원격 작업 중이라는 증거가 아님. 최신OS 실행 미확인 |
| [Jolt of Caffeine](https://apps.apple.com/us/app/jolt-of-caffeine/id1437130425?mt=12) | 1.1(2018-10-15)·레거시 | 빠른 시간+사용자 시간·카운트다운·아이콘·AppleScript 호환 | 정확한 배터리 옵션은 근거 부족. UX만 참고 |
| [Insomniacs](https://apps.apple.com/us/app/insomniacs/id1445351220?mt=12) | Store2.0.0·출시 설명 | 드래그 가능한 countdown ring·가운데 중지·상태를 한눈에·시작/기한 보기/종료 단축키 | 드래그의 마감 교체와 가산 연장을 구분. sandbox/덮개 설명만으로 실제 무외장화면 지원을 확정하지 않음 |
| [NoDecaf](https://apps.apple.com/us/app/nodecaf/id6762029386?mt=12) | Store1.4.0·출시 설명 | 시간/전면/전체화면 조건·날짜 범위/휴일 제외·shot 연장·긴 목록 스크롤·앱 선택기·간결한 상태 | 활성 규칙 편집과 현재 작업 교체 구분. URL 오타를 무제한으로 바꾸지 않는 검증 원리 |
| [Clamshell / clamshell.dev](https://clamshell.dev/) | 공식1.4.23(2026-10-12)·[변경 기록](https://clamshell.dev/changelog) | Option-close 일회성 의사·한 번 닫을 때만/지속 모드·도킹과 독립·열 보호·복구 안내 | 동명 App Store 제품과 다름. gesture는 lid-angle 센서 기종 제한. 닫힌 원격 화면/열림 잠금은 제품 선택이며 범용 무잠금 보장이 아님 |
| [Clamshell / Alexander Kovrazhkin](https://apps.apple.com/us/app/clamshell/id6477896729?platform=mac) | Mac2.3·iOS companion별도 | 덮개 사건별 동작·외장 화면 정책·선택적 iCloud 상태 공유·원격 상태 보기 | 위 clamshell.dev와 다른 앱. Mac/iOS 버전 구분. 원격 상태 동기화는 지연/마지막 확인 시각 필요 |
| [KeepAwake / keepawakeapp.com](https://www.keepawakeapp.com/) | 현재 개발자 기능 설명·구현/정식버전 미확정 | 가상 모니터+실제 모니터 연결 시 양보, 활동 방식·idle 조건·잔량 하한 | 개발자 비교표의 타사 평가는 채택하지 않음. privacy shield는 로그인 잠금이 아닌 앱 화면 가림, 가상 모니터만으로 덮개 유지가 보장된다는 주장은 실물 확인 필요 |
| [Sleep Control Centre / 3bitlab](https://apps.apple.com/us/app/sleep-control-centre/id946798523?mt=12) | 정식2.27(2025-01-30)·macOS11+·[Help2.24](https://prevent-mac-from-sleeping.3bitlab.com/prevent_mac_sleep_help.html) | 유휴 시작/입력 리셋 타이머·Hot Corners·Wi-Fi 복구 유예·Sleep 전 디스크 eject·AppleScript/deep link | 유휴 기한과 고정 기한 분리. unmount 실패 때 강제 eject하지 않음. Help와 현재 배포판 차이는 인수 필요 |

### 공개소스 구현에서 가져올 원리

| 제품 | 공식 기준 | 가져올 장점 | 그대로 옮기지 않을 부분 |
|---|---|---|---|
| [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | 정식1.6.8·고정main 별도·MIT | 편집 가능한 시간 목록·기본시간·외부 화면 자동·잔량/저전력·PID 수명·사용자 전환 일시 해제 | main1.6.9는 미출시. 덮개 우회 기능으로 확대하지 않음 |
| [Caffeine / domzilla](https://github.com/domzilla/Caffeine) | 정식1.6.4·main 별도·MIT | 클릭/상세 메뉴 분리·수동 Sleep 시 해제·Wake 때 실제 마감 재평가 | 활동 시뮬레이션은 독립 선택. 미출시 VoiceOver 변경을 정식으로 표시하지 않음 |
| [Open Caffeine](https://github.com/sapsaldog/open-caffeine) | 정식1.0.2·MIT | native Glass·직접 시간·화면 옵션·단축키·실제 assertion 성공 뒤 활성화 | 옵션 재적용 실패 처리 참고. 옵션 변경만으로 원래 마감을 재시작하지 않음 |
| [OpenLid](https://github.com/openlid/openlid) | 정식2.4.0·Apache-2.0 | 요일/시간표·자정 넘김·이동 추정·GUI/CLI 공통 설정·helper 승인/연결/복구 상태 구분 | 2.4.0은 도우미 미작동을 유지 중으로 표시하던 문제 수정. 이동 추정은 별도 오탐 검증 |
| [Amped](https://github.com/gustaferiksson/amped) | 정식0.3.7·MIT | 작은 상태 아이콘·시스템/덮개 분리·Intent·Controls·연결 없는 helper30초 뒤 종료 | 외부 화면 예외·잠금은 사용자 선택으로 통합. 지원되는 상태와 실제 적용 확인 분리 |
| [ecc521/keepawake](https://github.com/ecc521/keepawake) | 정식0.3.0·main 별도·MIT | 명령/PID 수명·동시 세션·잔량/열 hysteresis·종료 직렬화·복구 잠금 | 외부 전역 유지까지 해제할 수 있다는 자체 한계. 정식 이후 main 보안 수정을 배포판에 귀속하지 않음 |
| [Liddy](https://github.com/bygelo/liddy) | 정식0.1.0·main 별도·MIT | 순수 안전 판단·우선순위·heartbeat/소유자 상태·정책/실행 분리 | 정식/HEAD 차이·복구 실패 기록 수명은 별도 확인 |
| [Sleepless](https://github.com/Aboudjem/Sleepless) | 정식1.2.7·MIT | 세 상태를 형태로 구분·잔량 슬라이더/저전력·저장값보다 실제OS값 우선·배포 checksum/provenance | 광범위 sudo 권한이나 성공 코드만으로 적용 상태 확정하지 않음 |
| [Foldwake](https://github.com/thavguard/foldwake) | 정식release 미확인·공개 코드·MIT | 설정 명령 뒤 실제 OS 값 재조회·덮개/전원 분리 관측 | 배포·설치·복구 인수 없이 안정된 실행기로 간주하지 않음 |
| [Vigil](https://github.com/dbuskariol/vigil) | 정식0.2.2·코드/설명 | GUI 종료·업데이트와 기능 실행 수명 분리, 독립 작업의 타이머/알림·잔량 설정, 복구 제한 표시 | ‘30초 간격2회 재시도’ 설명과 main 구현의 최초+1회 재시도 차이. 정확한 기한/횟수는 새 계약으로 검증 |
| [CaffeineMate](https://eddmann.com/CaffeineMate/) | 정식1.0.2·MIT | 작은 native 패널·시스템/화면 선택·직접 시간·키 캡처형 단축키·카운트다운/툴팁 | assertion 실패 뒤 활성 표시·매초차감 타이머의 수면/지연 처리 경계는 그대로 재사용하지 않음 |
| [NoSleep / integralpro](https://github.com/integralpro/nosleep/) | 원저장소가 DEPRECATED·유지보수 중단 명시 | 닫힘 유지의 초기 구현 비교 자료 | 새 고유 기능은 확인하지 못함. 옛 kext를 Apple Silicon/macOS26 실행기로 채택하지 않음 |
| [InsomniaX / semaja2](https://github.com/semaja2/InsomniaX) | archived·abandonware·추가 배포 없음 명시 | 필요한 기간에만 적용하고 끝나면 영향을 제거하는 원칙·작은 기본 메뉴/고급 설정 분리 | 기능/UX 원칙만 참고. 옛 kext 구현을 현재 하드웨어에 이식하지 않음 |

고정 checkout 목록은 [기존 소스 모음](../../power-app-reference-sources/README.ko.md)에 보존했다. 새로운 공식 저장소를 열어 조사한 것과 로컬 clone/코드 편입은 구분한다.

다음은 실제 통합 전에 읽을 **작은 코드 단위**다. 직접 재사용 시 정확한 commit·파일 라이선스·저작권 고지를 고정하고, 기능 아이디어를 자체 구현하는 경우와 구분한다. Keepresso의 GPL-3.0 코드를 MIT 등으로 임의 전환하거나 Amphetamine의 비공개 본체를 공개 보조 저장소와 같은 라이선스로 취급하지 않는다.

| 참고 단위 | 가져올 원리·확인한 한계 |
|---|---|
| [KYA의 PID·시간 수명](https://github.com/newmarcel/KeepingYouAwake/blob/2be93dd7f390b23fbca934ff3b1ac03468a80077/Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/KYASleepWakeTimer.m#L95) | `caffeinate`를 부모 PID·기간과 연결. 고정main 근거이며 출시1.6.8과 차이를 확인하고 사용 |
| [Caffeine의 Wake 마감 평가](https://github.com/domzilla/Caffeine/blob/f938edb3aa76c3332584c2975b0bac4dec1837e7/src/Caffeine/Classes/ViewModels/CaffeineViewModel.swift#L173) | Wake 뒤 이미 지난 마감 평가. 매초 차감만으로 남은 시간을 결정하지 않음 |
| [Open Caffeine1.0.2 세션](https://github.com/sapsaldog/open-caffeine/blob/v1.0.2/OpenCaffeine/Services/CaffeineSession.swift#L26) | 획득 성공 뒤 활성화, 화면 요청 재적용 실패와 원마감 보존 처리 |
| [OpenLid2.4.0 복구](https://github.com/openlid/openlid/blob/v2.4.0/crates/app/src/recovery.rs#L146) | 미등록·승인 대기·재접속과 실제 실행 상태 구분 |
| [Amped0.3.7 도우미 수명](https://github.com/gustaferiksson/amped/blob/v0.3.7/Helper/HelperService.swift#L41) | 클라이언트 없는 옛 도우미 종료. 업데이트 뒤 구/신 실행기 중복 방지 참고 |
| [Liddy 순수 보호 정책](https://github.com/bygelo/liddy/blob/main/Sources/LiddyKit/Safety/SafetyGovernor.swift#L26) | 관측과 판정을 분리해 격리 검증. main의 기능을0.1.0 정식 완료로 이월하지 않음 |
| [Foldwake 실제값 재조회](https://github.com/thavguard/foldwake/blob/main/Sources/FoldwakeHelper/main.swift#L93) | 종료 코드·조회 성공·요청값 일치가 각각 필요. 아직 정식 릴리스 근거 없음 |
| [Vigil 실행/복구](https://github.com/dbuskariol/vigil/blob/main/Sources/vigil/Features.swift#L389) | GUI 독립 수명·정확한 마감·중복 종료 억제. README의 재시도 횟수는 실제 코드와 대조 |
| [CaffeineMate 실행기](https://github.com/eddmann/CaffeineMate/blob/main/CaffeineMate/PowerAssertionManager.swift#L27) | 실패 후 `isActive=true`와 초 차감 타이머는 정적 결함 후보. UI만 참고하고 해당 실행 로직 직접 편입은 보류 |

위 결함·한계는 정적 검토와 공개 변경 기록의 근거다. 경쟁 제품에서 직접 실패를 재현한 시험 결과가 아니다.

### 인접 전문 도구

| 도구 | 공식 근거 | 가져올 장점 | 차기 Tether에서의 위치 |
|---|---|---|---|
| [Power Manager / DssW](https://www.dssw.co.uk/powermanager/) | 현재 공식 제품·[사건 모델](https://www.dssw.co.uk/powermanager/guide/creating-events/) | **trigger→condition→action** 분리·반복/유휴/전원 사건·작업 순서·일정 편집·조건 비용 관리 | 자동화 모델의 참고. 시스템 wake/종료·로그인 전 작업은 별도 실행 권한/수명 |
| [Shortery](https://apps.apple.com/ie/app/shortery/id1594183810?mt=12) | 현재 공식 Store | 시스템 사건을 Shortcuts로 연결·자동화 그룹/검색·앱/전원/덮개/Focus/화면 사건 | 새 행동을 계속 자체 구현하기보다 공개 명령/Shortcuts 접점을 재사용 |
| [Hammerspoon](https://www.hammerspoon.org/docs/hs.caffeinate.html) | 공식 모듈 문서·공개 소스 | assertion 조회·전원/세션 watcher·활동 선언·스크립트 조합 | 자동화 API 설계 참고. 문서 자체가 오래된acAndBattery/private 경로 한계를 명시하므로 최신OS 덮개 보장으로 사용하지 않음 |
| [BetterDisplay](https://github.com/waydabber/BetterDisplay) | 현재 공식 배포·26/27용5.1.1 표기 | 물리/가상 화면 구분·연결/해제·다중화면·원격 HiDPI·프로필·복구 | 화면 전문 모듈 또는 외부 연계. 공개 GitHub 랜딩/이슈를 본체 오픈소스로 부르지 않음 |
| [Lunar](https://lunar.fyi/) | 공식 제품/공개 코드 링크 | BlackOut/Auto BlackOut·이전 밝기 복원·DDC와 소프트웨어 dim 구분·단축키/CLI | 원격/외장 화면 프로필. 밝기0·black overlay·실제 화면 전원 끄기를 별개 결과로 표시 |
| [AlDente](https://apphousekitchen.com/aldente-overview/features/) | 공식 기능 설명 | 보호의 hysteresis·기능 종료 원복·상태별 Shortcuts·충전/공급/잔량 분리 | 충전 제어는 독립 전문 모듈/연계 후보. 환경 온도를 배터리 센서 임계값으로 복사하거나 배터리 수명을 보장하지 않음 |

추가 발견 후보에는 Potoo·PleaseSleep·SleepLess/ALXsoftware가 있다. Potoo/PleaseSleep은 읽을 수 있는 공식 본문을 충분히 확보하지 못했다. [SleepLess 개발자 원문](https://alxsoft.com/?p=14)은 직접 조회 timeout이며 검색 색인의2.9·10.8~10.12·Safe Sleep 설명만 확인했다. 이들은34개 확인 목록에 포함하지 않는다. 최대 절전 quick action은 독립 검토 아이디어로만 남기고 최신 Mac 지원/제품 기능으로 확정하지 않는다.

## 3. 중복을 합친 차기 기능 묶음

아래는 **통합할 후보 목록**이다. 수집했다고 신규 기능을 구현/출시한 것은 아니다. 같은 기능의 앱별 이름·토글을 중복 구현하지 않는다.

| ID | 통합할 기능·선택 | 주요 참고 | 통합 방향 |
|---|---|---|---|
| N01 | 간단 시작·기본시간·클릭/우클릭/modifier·Hot Corners | Lungo·Caffeine·Jolt·Sleep Control Centre | 빠른 기본모드, 명령의 범위를 툴팁에 설명. 화면 모서리 동작은 다른 OS/앱 설정과 별도 확인 |
| N02 | 고정/사용자 시간·종료 시각·무제한 | Amphetamine·Keepresso·NoDecaf | 기간과 벽시각 입력의 의미/다음날·시간대 처리 분리 |
| N03 | 가산 연장·지금부터N분·정확한 새 종료 시각 | Keepresso·NoDecaf | ‘연장’과 ‘마감 변경’ 조작을 분리, 실행 전 새 마감 표시 |
| N04 | 시간 grid·countdown ring·키보드 제어 | Owly·Insomniacs | ring은 선택 가능한 입력 방식. 숫자·프리셋·키보드도 유지 |
| N05 | AC/배터리/둘 다·각각 시간 상한/무제한 | Amphetamine·Keepresso·Lungo | 기존 전역AC-only/2h를 탐색 제약으로 두지 않음. 프로필별 선택 후보 |
| N06 | 분리 시 종료/자동만 종료/유효 수동 계속 | Keepresso·Owly·Lungo·Clamshell | 분리 정책을 명시 선택하고 숨은 승계는 만들지 않음 |
| N07 | 화면/덮개/시스템 요청별 옵션 | Amphetamine·Keepresso·Amped | 요청별 요구와 전역 실행 허용을 구분 |
| N08 | 덮개 한 번만/지속·Option-close·열림 후 행동 | clamshell.dev·Clamshell App Store | 센서 미지원 기기에 메뉴/단축키 대안. 열림과 전원 변화는 별도 사건 |
| N09 | 자동+수동 공존/수동 우선·복수 작업 | Amphetamine·Keepresso·Vigil | 요청별 소유자와 종료 범위. 복수 작업의 합집합을 한 실행기로 관리 |
| N10 | GUI 닫기/업데이트와 작업 실행 수명 분리 | Vigil·Keepresso | ‘창 닫기/메뉴 앱 종료’와 ‘모든 유지 종료’ 구분. 영속 실행은 명시적 선택 |
| N11 | 보호·Sleep·재시작 뒤 재개 방식 | Amphetamine·Keepresso·Lungo | 종료/일시중지/원기한 재개/남은시간 보존을 서로 다른 정책으로 검토 |
| N12 | AND/OR 묶음·조건 조합·유예/지속/복귀시간 | Keepresso·Amphetamine·Power Manager | 사건과 상태 조건을 분리하고 조건 깜빡임/중복 시작 억제 |
| N13 | 앱·전면·프로세스/PID·전체화면 | Amphetamine·Keepresso·NoDecaf | 앱 picker·실행경로 선택, ‘앱 실행’과 ‘실제 작업 중’ 구분 |
| N14 | 요일/overnight·날짜 범위·휴일 제외·Focus | Owly·NoDecaf·Shortery | 일정은 벽시계, 기간은 연속시계. 놓친 일정 정책을 명시 |
| N15 | Wi-Fi/VPN/IP/DNS/LAN 서비스 | Keepresso·Wimoweh·Shortery | 도달 가능/연결 상태와 실제 활동 구분, 권한·타임아웃 표시 |
| N16 | USB/BT/컨트롤러·볼륨·외장 화면 | Keepresso·Amphetamine | 연결/분리와 일시 끊김 유예, 물리/가상 식별 |
| N17 | CPU/GPU/전송량·작업량 지속 조건 | Keepresso·Wimoweh | 비용·평활·최소 지속·종료 hysteresis. 미관측을 작업 완료로 바꾸지 않음 |
| N18 | 캘린더·카메라/마이크·앱별 통화·오디오 | Keepresso·Amphetamine·Shortery | 필요한 상태만 관측. 단순 앱 실행을 회의/재생 성공으로 표시하지 않음 |
| N19 | 폴더 다운로드·파일 진행·Steam/백업 | Keepresso·Amphetamine | 무변화/권한실패/수면을 완료로 오인하지 않도록 작업 상한·연동 대안 |
| N20 | AI 추정+명시적 hook·waiting/subagent 상태 | Keepresso | 명시적 사건과 CPU/파일 변화 추정을 다른 근거로 표시 |
| N21 | CLI·URL·Shortcuts·Intent·AppleScript | Amphetamine·Keepresso·Lungo | 하나의 공통 명령 경로·입력 검증·결과/실패 코드 |
| N22 | MCP·다중 유한 lease·heartbeat | Keepresso | 도구별 소유/TTL·명시해제·크래시 만료. UI 작업과 시간 제한의 관계 명시 |
| N23 | 외부 hook: Shortcuts/webhook/command | Keepresso·Power Manager | 수동 설정·실행 범위·재귀 제한·가져온 명령은 검토 전 실행 금지 |
| N24 | 반복/일회 일정 wake·깨운 후 작업·작업 후 정리 | Power Manager·Keepresso | 펌웨어/전원/로그인·전역wake일정과 실제 실행 성공은 별도 |
| N25 | 위젯·제어 센터·Spotlight·시스템 진입점 | Keepresso·Amped·Insomniacs | 상태 시각·오래된 정보 표시, 별도 전원 writer 없음 |
| N26 | 종료 행동: OS 위임/화면/보호기/잠금/Sleep/스크립트 | Keepresso·Clamshell·Power Manager | 마지막 유효 작업과 원인에 따라 실행. shutdown은 별도 명시 예약/취소·저장 작업 검토 |
| N27 | 유휴 후 화면 유지 해제/어둡게·복귀 복원 | Keepresso·Lunar | 작업은 유지하고 화면 요구만 변경, 다른 작업 요구와 합성 |
| N28 | 원격 화면: 켜짐/밝기0/BlackOut/가상·분리 | Keepresso·BetterDisplay·Lunar | 각각의 전력/잠금/원격 호환성을 실제로 검증하고 fallback/복구 제공 |
| N29 | 활동 선언·커서warp·키/마우스 입력 방식 | Amphetamine·Keepresso·KeepAwake | 방식별 권한/실제 이벤트·앱별presence 차이. 직접 입력 중 억제·대상 제한·원격 호환 인수 |
| N30 | 화면 가림·발표·바탕화면 숨김·Focus Dim | Theine·One Switch·KeepAwake | 가림은 OS 잠금이 아님을 명확히. 자동 잠금 해제는 기능으로 약속하지 않음 |
| N31 | 배터리 하한·충전 부족·열 압력/센서·hysteresis | Keepresso·Owly·AlDente | 사용자 임계값과 Apple 보장 구분. 기본값/중단·회복 정책을 새로 설계 |
| N32 | 팬 최소/부스트·저전력·충전 도구 연계 | Keepresso·AlDente | 기기 지원/권한/원복 journal 별도. 충전중/물리연결/현재공급을 구분 |
| N33 | 네트워크 fallback·AWDL/게임·우선순위 | Keepresso | 기본 기능과 독립된 선택 확장. 기존 설정 baseline·되돌리기·연결 변화 표시 |
| N34 | 외부 디스크/NAS 깨움 | Amphetamine·Keepresso | 선택한 볼륨만·연결/해제·쓰기 방식과 주기 공개 |
| N35 | 종료·시작·반복·사전 알림·소리·액션 | Amphetamine·Keepresso·Insomniacs | 자연완료/보호/수동중지 구분, 과거 알림 액션과 알림 폭주 억제 |
| N36 | compact/detailed·시간/경과/마감·아이콘·메뉴 편집 | Lungo·Keepresso·NoDecaf | 작은 기본 화면+선택 정보, 중요한 종료/오류 조작은 항상 도달 가능 |
| N37 | 프리셋·복제/정렬·검색·import/export·이력 | Keepresso·Shortery·Tether | 조건/동작 template, 설정 복원과 실행 복원을 구분 |
| N38 | 왜 유지되는지·타사 영향·통계·원격 상태 | Keepresso·Wimoweh·Clamshell | 실제 관측·근거·시각·원인, 알 수 없는 상태를 사실로 만들지 않음 |
| N39 | 규칙 예행연습·작업 후 업데이트·복구 확인 | Tether·Vigil·OpenLid | 현재 잘 만든 경로를 재사용, 가상 실행/원복 완료/OS 실제 결과 구분 |
| N40 | 유휴 시작·입력 때 리셋되는 타이머 | Sleep Control Centre | 고정 마감/경과시간과 별도 타이머 종류. 키보드·마우스·원격·합성 입력을 어떤 활동으로 볼지 명시 |
| N41 | Sleep 전 외장디스크 안전 해제 | Sleep Control Centre | 선택 볼륨·실행 유예·열린 파일/권한/실패 처리. 실패를 강제 eject 성공으로 바꾸지 않고 후속 Sleep과 조정 |

CPU/GPU 감지·Focus·새 기기 조건처럼 서로 다른 제품 기능을 묶은 후보는 대상 OS/API를 각각 확인해야 한다. 목록의 묶음 수는 구현 기능 수나 완성률이 아니다.

## 4. ‘장점만 합치기’를 위한 공통 구조

### 선택 정책과 실행을 분리

1. **작업 요청:** 사용자·규칙·명령·AI·lease 각각 출처/수명/기간/요구 자원을 가진다.
2. **조건 평가:** 사건이 발생했는지와 현재 조건이 맞는지 분리한다. 권한/미확인/연결변화는 값과 시각을 함께 평가한다.
3. **정책 선택:** 전원 범위·분리 동작·시간 제한·중지/재개·원격/덮개 선택을 프로필로 설정한다. 이전 v4 규칙은 가능한 프리셋 하나이며 보편 제약으로 고정하지 않는다.
4. **자원 실행:** 일반·화면·덮개·밝기·팬·네트워크·wake 등은 자원별 adapter/소유권/복구 계약을 갖고, 같은 자원에 여러 독립 writer를 만들지 않는다.
5. **자동화 행동:** 종료/조건/보호/일정 사건에서 행동을 실행한다. 행동이 다시 사건을 만들어 무한 반복하지 않게 한다.
6. **표시:** 실행 의도·실제 적용·제한/원복·현재 이유를 나누고, 기본 화면에서는 현재 결과와 필요한 조작을 우선한다.

설정 수를 늘리는 것과 실행기를 늘리는 것은 다르다. 복구·권한·request ID·마감·기기 관측은 공통 경로를 재사용한다. 새 모듈을 끄거나 제거해도 다른 작업의 요구/설정을 훼손하지 않게 한다.

### 충돌을 선택 모델로 해결할 항목

| 충돌 | 선택/조정 원리 |
|---|---|
| 분리 즉시 종료 vs 배터리 계속 | 프로필/요청별 분리 정책 하나를 확정. 오래된 종료 권한이 새 유효 작업을 잠재우지 않음 |
| 무제한 vs 배터리/열 중단 | 시간 제한과 보호는 별도 옵션·이유. 앱 옵션이 OS의 강제 보호를 우회한다고 약속하지 않음 |
| 시간 연장 vs 지금부터N분 | 다른 명령과 미리보기. 마감 세대·취소·늦은 결과를 구분 |
| 수동 우선 vs 자동 공존 | 실행 이유별 request 합성과 명확한 중지 범위. 하나 끝남을 전체 끝남으로 오인하지 않음 |
| GUI 종료 시 해제 vs 계속 | 사용자가 선택한 실행 수명. ‘모든 유지 종료’는 어느 모드에서도 제공 |
| 화면 끄기 vs 원격 캡처/활동 입력 | 화면 정책과 활동 주입을 독립 선택. 주기 입력이 화면 절전을 계속 깨우는 조합은 예행연습/설정에서 설명 |
| 열림 시 잠금 vs 원격 무잠금 요구 | 프로필에서 열림 행동 구분. 이미 잠긴 Mac 자동 해제는 별도 인증 문제이며 이 기능 수집으로 해결됐다고 하지 않음 |
| 가상화면 제거 vs 화면 복구 | 물리/가상·마지막 유효 화면·원격 의존성을 확인하고 되돌리기/복구 경로 제공 |
| 자동팬/밝기/전원모드 vs 전문 앱 | 자원별 단일 소유자·원본·외부 변경 감지. 타사 변경을 덮는 무조건 원복 금지 |
| 원복 실패 vs 앱 재시작/업데이트 | 실패 정보를 보존하고 실제 원복 확인. 프로세스 종료나 재시도가 성공했다는 이유로 완료 처리하지 않음 |
| 일정 wake vs OS/다른 도구 예약 | 예약 소유권/전역 영향·충돌·취소를 표시. 표에 보이는 예약과 실제 깨어남은 다른 결과 |
| 설정 import/이력 vs 명령·토큰·실행 | 설정만 옮기고 외부 명령·권한·현재 작업 재생은 별도 명시 선택 |

### 출발점으로 제안할 프로필

- **간단 유지:** 기본시간/무제한·원클릭·화면 허용만 제공.
- **책상/도킹:** 전원·외장 화면·기기 조건과 화면/덮개를 연결.
- **이동 중 작업:** 배터리 지속·잔량/열·시간 제한·분리 동작을 선택.
- **원격/서버:** GUI와 작업 수명 분리·화면 정책·가상화면/실제화면 양보·lease·복구.
- **개발/AI:** 명령/PID·정확한 사건·추정·MCP·후처리·작업 후 업데이트.
- **발표/회의:** 시간·앱/회의·화면·바탕화면 가림·알림 선택.

이는 출발점 template이며 서로 다른 구현을6개 만드는 뜻이 아니다. 기본값·자동 시작·보호 재개·무제한 허용 등은 실제 UI에 적용하기 전에 새 설계로 확정한다. 기존 사용자 이관은 기존 동작 보존이 출발점이다.

## 5. 최신OS·공식 지원의 경계

- 공개 idle assertion은 유휴 수면과 덮개·명시적 Sleep을 구분한다. [Apple 공개 헤더](https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLib.h)는 `PreventSystemSleep`을 폐기·미지원으로 표시한다. [caffeinate 매뉴얼](https://github.com/apple-oss-distributions/PowerManagement/blob/main/caffeinate/caffeinate.8)의 `-s`와 오래된 설명을 현대 Mac의 모든 수면 방지 보장으로 사용하지 않는다. 매뉴얼의 시간/PID/명령 수명은 별도 참고한다.
- [활동 선언](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity)·[커서warp](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition(_:))·[실제 이벤트 주입 권한](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())·앱별presence는 다른 신호다. 권한과 실제 반응을 각각 검증한다.
- OS 잠금·로그인·원격 세션·실제 화면 전력·가상 화면·밝기0을 같은 상태로 표시하지 않는다.
- [Apple macOS27 Shortcuts 자동화 문서](https://support.apple.com/en-ie/guide/shortcuts-mac/apdfbdbd7123/10.0/mac/27)는 내장 자동화와 중복될 수 있는 기능을 확인하는 출발점이다. 포괄적인 목록 하나만으로 Mac의 각 트리거·macOS26 지원을 확정하지 않는다. 제공되는 OS 기능은 외부 앱의 동작을 복제하기보다 Tether 액션과 연결하는 안을 먼저 검토한다.
- 오래된 공개 코드·새 App Store 설명·도우미 없는 가상화면 기법 등은 기기/OS별 적용 근거가 다르다. 실제 장점과 최신OS에서 작동하는 실행 경로를 분리한다.

## 6. 검증과 다음 구현의 경계

현재 완료한 것은 공식 기능/코드 수집·앱별 장점·중복 정리·충돌 모델·차기 후보 범위다. 신규 기능 구현, 후보58 설치, 앱별 실제 비교, 물리 덮개/케이블, 원격/화면/팬/충전/네트워크 모듈 실행은 하지 않았다. 49단계/15개 UI 등의 후보58 기록을 신규 후보의 통과로 이월하지 않는다.

후속은 **기능 후보별 채택표/기본값 → 충돌 없는 새 계약 → 기본/고급 UI 시안 → 모듈별 구현/자동 검증 → 설치/물리 인수** 순서다. 기능이 확인됐다는 이유로 모든 모듈을 기본 ON하거나 모든 권한을 첫 실행에서 요청하지 않는다.

검증에는 복수 요청·정확한 시간/벽시계·분리/복귀·설정 편집 중 실행·권한 거부·관측 상실·크래시/GUI 종료/업데이트·전문 앱 공존·자원별 원복·실제 OS Sleep/Wake·화면/원격 인수를 포함한다. 팬/충전/전역 wake/네트워크를 실제로 조작하는 시험은 효과가 명확한 별도 단계로 관리한다.
