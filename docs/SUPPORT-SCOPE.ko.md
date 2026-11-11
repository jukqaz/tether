# macOS 기본 기능 우선 · 지원 범위와 차용 조사

> 빌드 49 반영: 이 문서의 과거 조사·검증 기록 이후 확정된 현재 동작은 [최종 기능](FINAL-SCOPE.ko.md)과 [보호 기준](PROTECTION-EVIDENCE.ko.md)을 따른다.

2026-09-29. 사용자의 새 기준: macOS 기본 기능은 중복 구현하지 않고, 최신 Mac에서 지원하지 않는 기능은 제공하지 않는다.

이 문서는 조사 결과와 다음 구현의 기준이다. **이 문서 작성으로 앱 동작·시스템 설정·설치 상태가 변경되지는 않았다.** 경쟁 앱은 소스를 비교했으며 이번 조사에서 실행하거나 설치하지 않았다.

## 결론

Tether는 외장 화면 없는 덮개 작업 유지, 전원 조건과 배터리 사용 시간, 자체 유지의 보호 중지·복구·진단에 집중한다. 일반 화면 시간, 잠금, 충전 상한, 에너지 모드, 기본 외장 화면 클램쉘은 macOS에 맡긴다.

지원 기준은 세 가지를 함께 본다: 공식 문서/API, 현재 기기의 실제 관측 가능성, 해당 동작의 기기 시험. OS 버전이나 명령 성공만으로 지원을 선언하지 않는다. 최신 Mac에서 미지원으로 확인된 경로를 우회·강제 활성화하는 기능은 추가하지 않는다.

**Apple 공식 안내에 있는 기능만 허용한다는 기준과는 다르다.** Apple의 닫힌 덮개 안내는 전원·외장 화면·입력장치 구성을 전제로 한다. 외장 화면 없는 작업 유지는 별도 호환성 검증이 필요한 Tether의 핵심 확장이다. 이것까지 공식 기본 기능만으로 제한하면 개발할 핵심 범위 자체가 크게 줄어든다. [Apple 외장 화면 안내](https://support.apple.com/en-us/102501)

## macOS에 맡길 것

| 항목 | 현재 근거 | Tether의 지원 범위 |
|---|---|---|
| 열린 덮개에서 AC 연결 중 화면만 끄고 유휴 잠자기 방지 | macOS 배터리 옵션에서 제공 | 별도 영구 설정·일반 절전 모드 기능을 만들지 않음. 시스템 설정 안내 |
| 화면 자동 꺼짐 시간, 잠금·암호 요구 | macOS 잠금 화면 설정 | 중복 슬라이더·잠금 방지·가짜 사용자 활동 제외 |
| 전원·외장 화면이 있는 기본 클램쉘 | Apple가 안내하는 구성 | 자체 전역 유지와 전체 화면 끄기를 추가하지 않고 OS에 위임. 화면 개수만으로 주변기기 승인까지 정상이라고 단정하지 않음 |
| 충전 상한·최적화 충전 | Apple Silicon + macOS 26.4 이상에서 충전 상한 80–100% 제공 | 충전 제어, 강제 방전, 배터리 보정 기능 제외 |
| 저전력·자동·고성능 모드 | 지원 모델의 macOS 배터리 설정에서 전원별 선택 가능 | Tether가 자동으로 성능 모드를 덮어쓰는 기능을 정리할 대상. 발열 보호는 자체 절전 방지의 중지로 범위를 좁힘 |
| 느린 충전기 표시 | macOS 26.4 이상에서 표시 | 단순 표시를 새 기능으로 중복 구현하지 않음. 자체 유지 중 실제 잔량 하한에 도달하는 상황은 별도 보호 대상으로 유지 |
| 팬·하드웨어 열 관리 | OS와 기기가 이미 관리 | 팬 제어·SMC 쓰기·하드웨어 고장 판정 제외. Tether는 OS 발열 신호에 따라 자체 유지 정책만 조정 |

근거: [잠자기·화면 설정](https://support.apple.com/en-hk/guide/mac-help/-mchle41a6ccd/mac), [충전 상한](https://support.apple.com/en-us/102338), [에너지 모드](https://support.apple.com/en-us/101613), [충전 상태 표시](https://support.apple.com/en-us/102397), [온도 안내](https://support.apple.com/en-us/102336).

기본 기능을 사용하는 것과 같은 기능을 앱에서 중복 제공하는 것은 구분한다. 예를 들어 배터리에서만 제한 시간 동안 유지하는 기능은 전원 연결 중 유휴 잠자기 방지 옵션만으로 대체되지 않는다. 필요한 경우 공개 IOPM assertion을 내부 수단으로 쓰는 것은 중복 제품 기능 추가가 아니다. 일반 idle-sleep assertion으로 덮개 닫힘까지 보장하지도 않는다. [Apple IOPM API](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)

## 최신 Mac에서 제외하거나 지원 판정을 제한할 것

1. **Power Nap 설정:** Apple는 설정 옵션을 Intel Mac에 한정한다. Apple Silicon 대상 Tether에 제공하지 않는다. 이것은 Apple Silicon의 모든 백그라운드 깨움이 없다는 뜻이 아니다. [공식 안내](https://support.apple.com/en-qa/guide/mac-help/mh40774/mac)
2. **hibernate/standby 등 오래된 전원 조절 모음:** Tether의 요구에 필요하지 않으며 최신 기기에서의 의미를 검증하지 않았다. 설정 편집 기능을 제공하지 않는다. 모든 키가 최신 Mac에서 동작하지 않는다고 일괄 단정하지는 않는다.
3. **비공개 배터리 센서의 보편적 지원:** 현재 `SystemProbe.batteryTemperature()`는 IORegistry의 기기별 값에 의존한다. 현재 기기에서 읽혔어도 모든 최신 모델·OS에서 같은 구조와 단위를 보장하지 못한다. 기본 보호의 필수 입력에서 분리할 후보이며, 확인된 값만 진단에 사용한다.
4. **내장 패널 전력 0 보장:** OS의 화면 잠듦 관측과 전기적 전원 차단은 다르다. 후자를 보장하는 기능명·검증 결과를 제공하지 않는다. 밝기 0으로 성공을 대신하지 않는다.
5. **잠든 Mac에 전원만 꽂으면 항상 깨우기:** 현재 정책은 dark wake를 full wake로 강제 전환하지 않는다. 전원 조건 적용과 기기 깨우기를 같은 기능으로 설명하지 않는다. OS가 완전히 깨운 이후 조건을 평가한다.
6. **비공개 경로가 막혔을 때 권한·보안을 우회하는 기능:** 제공하지 않는다. 예를 들어 `batt`는 최신 펌웨어의 충전 제어 제약과 대체 경로를 설명하지만, Tether가 그런 충전 제어를 추가할 이유는 없다. [프로젝트 호환성 설명](https://github.com/charlie0129/batt#compatibility-matrix)

이번 Mac은 `sw_vers`에서 macOS 27.0 / 26A428, `uname -m`에서 arm64로 확인했다. 읽기 전용 `pmset -g cap`에는 `powernap`, `hibernatemode` 등도 출력됐다. **키가 목록에 있다는 이유만으로 해당 UI·동작의 지원 근거가 되지 않는다.** 이 점 때문에 버전 검사와 `pmset` 목록 하나에만 의존하는 설계는 부적절하다.

지원 상태는 내부적으로 구분한다.

| 상태 | 처리 |
|---|---|
| 동작 지원·검증됨 | 해당 기능 제공. 검증한 모델·OS·범위를 기록 |
| 미지원이 확인됨 | UI에서 제외하고 도우미도 요청을 거절 |
| 아직 미검증 | 지원·정상으로 표시하지 않음. 일반 자동 운용의 지원 목록에 넣지 않음 |
| 일시적 조회 실패 | 미지원 또는 꺼짐으로 바꾸지 않음. 마지막 확인 시각과 구체적인 실패를 진단에 남김 |

새 OS에서 기존 설정이 미지원이 되면 원래 값을 백업하고 해당 기능을 중단한다. 이미 바꾼 자체 설정을 확인·복구한 뒤 활성 설정을 이관한다. UI만 숨겨서 이전 도우미 설정이 계속 작동하게 두지 않는다.

## 다른 앱에서 차용할 가치가 있는 방법

### 1. batt: 기능별 지원 판정과 도우미의 요청 차단 — 우선 적용 후보

고정 커밋 `e56345622046d5c012cfd361bd560ed6dbcb68b5`의 `detectCapabilities`, `disableUnsupportedConfiguredFeatures`, `requireCapability`는 현재 이용할 수 있는 기능을 구분하고 미지원 설정과 API 요청을 처리한다. Tether에는 이 **지원 판정·설정 이관·도우미 검증의 일관성**을 차용할 가치가 있다. [구현](https://github.com/charlie0129/batt/blob/e56345622046d5c012cfd361bd560ed6dbcb68b5/pkg/daemon/compatibility.go)

충전 제어·SMC·PowerUIAgent 접근 방식은 차용하지 않는다. 구형 도우미의 지원 정보를 받지 못하면 기능을 허용하는 `Permissive` 호환 경로도 Tether 요구에 맞지 않아 제외한다. [지원 모델](https://github.com/charlie0129/batt/blob/e56345622046d5c012cfd361bd560ed6dbcb68b5/pkg/compatibility/compatibility.go)

Tether의 현재 `isSupportedMac`은 덮개와 내장 배터리 존재 확인이다. 화면 관측, 전원 정보, 보호 입력, 실제 설정 적용·복구의 기능별 지원 계약으로 확장하는 것이 이번 요구에 가장 직접적인 개선이다. 단, 읽기 전용 탐색만으로 실제 덮개 동작까지 검증했다고 처리하지 않는다.

### 2. Keepresso: 관측 후 화면 복구 — 이미 일부 반영, 장시간 동작 개선 후보

Keepresso v1.25.0은 실제 내장 화면의 켜짐을 보고 재절전을 요청하며 외장 화면이 있으면 전체 화면 절전을 생략한다. Tether 48 소스에도 같은 원리를 자체 구현했다. [비교 소스](https://github.com/gyorgysh/keepresso/blob/5837a0be0764c6637c09c29c606405e0630e43ed/Sources/KeepressoCore/ClosedDisplay.swift#L179-L201)

차용할 추가 관점은 장시간 세션의 복구다. 현재 Tether의 세션 총 3회 예산은 멀리 떨어진 일시적 깨움에도 소진된다. 안정 구간 후 복구 예산을 재평가하는 방식은 후보지만, 짧은 정상 표본 하나로 즉시 횟수를 초기화하면 무한 반복이 된다. 지속 충돌 중지와 장시간 정상 사용을 함께 시험한 뒤 조정해야 한다. Keepresso의 반복 방식을 제한 없이 그대로 채택하거나 5초를 제조사 권장값으로 표현하지 않는다.

### 3. Lidless: 요청·실제 적용·미확인 상태를 분리 — 기존 구조 유지 및 표시 개선

`StateReconciler`는 쓰기 성공, 실제 값 불일치, 읽기 실패, 외부 변경, 늦게 도착한 응답을 구분한다. 실패 원인을 다른 앱 탓으로 추측하지 않고 확인된 현상을 표시하는 점이 좋다. [구현](https://github.com/nghialuong/Lidless/blob/1c432ede45ea8c3e6dd4aa148a4d840d4e4e48cb/Sources/Shared/StateReconciler.swift)

Tether에도 `stateGeneration`, 명령 revision, 실제 SleepDisabled 확인, 자체 소유권 기록이 이미 있다. 이를 새 기능으로 다시 만들기보다 메뉴바와 로그가 같은 확인 상태를 표시하는지 보강한다. ‘켰음’보다 ‘켜기 요청 → 적용 확인’의 일관성이 중요하다.

Lidless의 앱 서명 검증 XPC도 비교 가치가 있다. 다만 해당 소스는 개발자 팀 서명을 사용하므로 사설 ad-hoc Tether에 그대로 붙일 수 없다. 설치·업데이트 동안 유지되는 앱 신원 설계를 먼저 정해야 하며, 이번 기능 축소의 필수 범위에는 넣지 않는다. [도우미](https://github.com/nghialuong/Lidless/blob/1c432ede45ea8c3e6dd4aa148a4d840d4e4e48cb/Sources/Helper/HelperService.swift)

### 4. LidGuard + Apple: 온도 숫자보다 OS 발열 상태 중심 — 우선 적용 후보

LidGuard는 배터리 섭씨 온도에 필수 의존하지 않고 발열 수준을 정책 입력으로 사용한다. 다만 내부 Darwin 알림도 병용하므로 구현 전체를 공식 API 방식으로 소개해서는 안 된다. Tether에는 공개 `ProcessInfo.thermalState` 중심이라는 원리만 적용한다. [LidGuard 센서](https://github.com/aermin/LidGuard/blob/5bba8031a64fcebfcdbbe1d670324c497bdbdeba/Sources/LidGuardHelperKit/SystemSensors.swift)

Tether는 이미 공개 발열 알림과 읽기를 사용한다. 다음 개선은 기존 40/43/45°C 보조 기준과 필수 센서 의존을 축소하는 것이다. Apple의 주변 온도 10–35°C를 배터리 센서 제한으로 환산하지 않는다. 사용자가 정한 세부 온도 설정을 바꿀 때는 백업·변경 고지를 포함해 마이그레이션한다. [Apple 온도 안내](https://support.apple.com/en-us/102336)

OS의 serious/critical은 부하를 줄여야 하는 근거를 제공하지만, Tether가 언제 유지를 중단하고 어떻게 재개할지는 제품 정책이다. 그것을 Apple가 정한 안전 시간·배터리 수명 보장이라고 표현하지 않는다. [serious](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious), [critical](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical)

LidGuard의 선택적 고부하 프로세스 종료나 잠금 방지는 차용하지 않는다. GUI 종료 후 세션을 계속하는 방식도 사용자의 의도와 복구 정책이 달라 자동 채택하지 않는다.

### 5. LidGuard·Foldwake: 실제 적용값 재확인 — 이미 있는 기능 유지

명령이 성공해도 OS 값이 요청과 다른 경우 실패로 다룬다. Tether의 `applyOverride`에 이미 있다. 복구 성공과 실제 시스템 Sleep 성공은 계속 별도로 검사한다. [LidGuard 구현](https://github.com/aermin/LidGuard/blob/5bba8031a64fcebfcdbbe1d670324c497bdbdeba/Sources/LidGuardHelperKit/PowerController.swift)

## 추가로 발견한 진단 개선

- **전원 연결·충전 중·방전 중은 다른 상태다.** 충전 상한이나 최적화 충전으로 ‘충전하지 않음’이 정상일 수 있다. 그것만으로 충전기 오류·전원 분리라고 판단하지 않는다. 잔량 하한과 실제 방전이 확인될 때 자체 유지를 해제하는 보호는 유지할 가치가 있다. 표현은 관측에 맞게 ‘전원 연결 중 배터리 잔량 감소’로 하고 충전기 고장을 단정하지 않는다. [Apple 충전 안내](https://support.apple.com/en-us/102397)
- **액세서리 승인을 클램쉘 오류와 구분한다.** 잠긴 Apple Silicon Mac에서는 새 독·화면의 승인이 필요할 수 있고 승인하지 않아도 충전은 가능하다. ‘AC이므로 정상 독 구성’이라고 추정하면 오진한다. 확인되지 않은 원인을 확정하지 않고 관련 증거가 있을 때만 승인 안내를 제공한다. 회사 보안 설정을 바꾸거나 우회하지 않는다. [Apple 액세서리 보안](https://support.apple.com/en-us/102282)
- **배터리 잔량·타이머는 사용자 사용 예산으로 설명한다.** 공통의 제조사 안전값인 것처럼 표현하지 않는다.

## 현재 코드와 실제 변경 필요 범위

| 현재 경로 | 다음 변경 |
|---|---|
| `SystemProbe.isSupportedMac` | 기능별 지원·관측·검증 상태를 도우미에서 판정하고 UI와 공유 |
| `Helper+BatteryHold.manageLowPower`, `Helper+HeatGuard` | macOS 전원 모드 자동 쓰기 정리. 저장된 battery/AC 모드와 watchdog의 복구 경로를 먼저 처리 |
| `SafetyPolicy`, `SafetyNetTracker`, `ProtectionState`, `Helper+Service` | 섭씨 센서 필수 의존과 임의 제한을 재설계. 공개 발열·잔량·시간·소유권 실패 처리는 유지 |
| `SafetyPage`, `ProtectionBasisView` | 중복 에너지 모드·온도 임계값 설정 축소, 필요한 시스템 설정 안내 |
| `SettingsMigration`, `HelperState`, watchdog | 제거한 기능의 설정·자체 변경 잔재가 다음 실행에 살아나지 않도록 순차 이관 |
| `Policy.wantsClamshell` | 현재 열린 덮개에서도 전역 값을 미리 켠다는 점을 명시. 열린 상태에서 OS에 전적으로 맡기는 변경은 덮개 닫힘 경쟁 조건까지 실기기 검증해야 함 |
| `DisplaySleepGate` | 검증된 일시적 재점등 회복과 지속 충돌의 구분을 보완. 무제한 재시도 금지 |

UI에서 중복 옵션을 지우는 것만으로 시스템 개입이 사라지지 않는다. 특히 전역 `disablesleep`의 사전 적용을 없애고 닫힘 이벤트 때만 켜는 변경은, OS 잠자기보다 늦게 적용될 수 있으므로 단순 리팩터링으로 취급하지 않는다.

## 남길 제품 기능

1. 검증된 기기에서 외장 화면 없는 덮개 작업 유지.
2. AC만 / 배터리만 / 둘 다의 조건과 배터리 제한 시간·잔량 예산.
3. 내장 화면 절전 관측·제한된 복구, 외장 화면 구성에서는 macOS에 위임.
4. 공개 발열 상태를 근거로 자체 유지 중지, 안전 조건을 확인한 명시적 재개.
5. 외부 전원 요청과 자체 설정의 구분, 종료·장애·업데이트 시 자체 변경 복구.
6. 구체적인 상태·원인 로그와 설정 보존 업데이트.

코드 정리 시 검증은 OS 기본 설정 불변, 구버전 자체 변경 복구, 미지원 옵션의 UI/API 차단, 센서 누락과 실제 과열 구분, 전원 전환·잔량·시간 제한, 외장 화면 위임, 실제 덮개·화면·Sleep/Wake를 각각 다룬다. 이전 빌드 48의 열린 덮개 화면 복구 시험은 실제 닫힌 덮개 성공의 대체 증거가 아니다.

조사 자료: `work/tether-native-scope-20260929/batt-metadata.json`과 고정 커밋 소스, 이전 고정 소스 `work/tether-continue-or-replace-20260929`. 외부 앱의 코드나 의존성을 제품에 복사하지 않았다.
