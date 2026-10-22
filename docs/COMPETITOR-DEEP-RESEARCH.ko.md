# Tether 재설계를 위한 새 조사

2026-10-06 조회 · macOS 26 이상 / Apple Silicon · 공개 문서·고정 commit·현재 이슈 상태. **지난 조사 결론·시험 수·설치 상태를 새 근거로 사용하지 않았다.** 제품 소개, 코드에서 확인한 경로, 사용자 보고, 실기기 검증을 구별한다. 경쟁 앱·설치본의 교체나 덮개/전원/보안 설정 변경을 수행하지 않았다. 이후 수행한 현재 Tether의 안전한 로컬 자동 검증은 §9와 [검증 체크리스트](VALIDATION-CHECKLIST.ko.md)에 별도로 기록했다. [디자인 미리보기](DESIGN.ko.md)는 예시 데이터로만 실행한다.

이 파일은 기존 심층 조사 문서를 대체한다. 현재 결정은 [기능 정의](PRODUCT-SPEC.ko.md)와 [실행 설계](ARCHITECTURE-REDESIGN.ko.md)에 반영했다. 예전 분석·실행 이력은 [구현 검토 기록](ARCHITECTURE-REVIEW.ko.md)에 남아 있으며 새 설계의 합격 근거가 아니다.

## 1. 새로 확인한 결론

일반 절전 방지와 덮개 수면 방지는 다른 실행 수단이다. 자체 요청 해제와 실제 Sleep도 다르다. 화면 절전·잠금 정책·실제 잠금·원격 입력을 하나의 상태로 합치면 원인을 놓친다. 세션·전원 트리거의 결정은 하나로 줄이고 덮개 실행과 복구만 권한 경계를 둔다.

공개 자료에서 **실제 내장 화면 꺼짐 + 세션 동안만 자동 무잠금 + 전역 보안 설정 미변경 + 원격 입력**을 모두 보장한 구현은 확보하지 못했다. Keepresso의 밝기 0% 원격 대응을 이 요구와 동일시하지 않는다. 수면 중 전원 연결 자동 시동 안내도 완전 Wake·원격 준비 보장은 아니다.

## 2. Apple 문서·SDK·공개 소스

| 근거 | 오늘 확인한 내용 | 결정·한계 |
|---|---|---|
| [공개 idle assertion 문서](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep), [IOPMLib.h L275–292](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/pwr_mgt.subproj/IOPMLib.h#L275-L292) | 화면 절전은 허용하지만 lid-close·사용자 Sleep 등은 예외 | 일반 작업 유지에 채택. helper·전역 설정 없이 시작할 수 있음. 덮개 지원으로 확대하지 않음 |
| [PreventSystemSleep 웹 문서](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventsystemsleep), [공개 헤더 L1014–1023](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/pwr_mgt.subproj/IOPMLib.h#L1014-L1023), [powerd L6641–6652](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/PMAssertions.c#L6641-L6652) | 웹 설명은 DarkWake 유지지만 헤더는 deprecated/사용 금지. 공개 powerd에는 AC 중심 처리 존재 | 문서·헤더·구현 불일치 기록. 호출 성공을 공식 지원·배터리 덮개 지원으로 읽지 않음. 별도 실험 후보 |
| [private header L646–686](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/pwr_mgt.subproj/IOPMLibPrivate.h#L646-L686), [실제 entitlement 검사 L2559–2578](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/PMAssertions.c#L2559-L2578) | `AppliesToLimitedPower`, `AppliesOnLidClose`는 내부 entitlement 요구. ARM64 clamshell 처리에도 추가 modifier 조건 존재 | 이름이 비슷한 속성을 임의로 넣어 덮개·배터리가 해결된다고 가정하지 않음 |
| [system-wide SleepDisabled L1980–2000](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/pwr_mgt.subproj/IOPMLibPrivate.h#L1980-L2000), [XNU 반영 L2055–2058](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L2055-L2058), [idle·demand sleep 차단 L7660–7695](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L7660-L7695) | 전원 소스별·프로세스별 assertion이 아닌 전역 설정. 공개 XNU는 사용자 demand Sleep도 차단 | 선택적 helper와 baseline·변경 전 journal·원복 실증 필요. 덮개 전용·native 메뉴 Sleep 보존으로 홍보하지 않음. 자체 잠자기는 해제 후 요청, 실제 OS 26 결과는 별도 검증 |
| [macOS 26 잠금 설정](https://support.apple.com/en-is/guide/mac-help/mh11784/26/mac/26), [암호 요구 설정](https://support.apple.com/guide/mac-help/require-a-password-after-waking-your-mac-mchlp2270/26/mac/26), [iPhone Mirroring](https://support.apple.com/en-us/120421) | 화면 절전 후 암호 요구는 별도 설정. 미러링의 자동 인증은 즉시 암호 요구와 연결 | 잠금 옵션 꺼짐을 OS 자동 잠금 방지로 표현하지 않음. 정책 읽기와 실제 잠금 관측을 구별 |
| [macOS 26 Sleep/Wake](https://support.apple.com/guide/mac-help/put-your-mac-to-sleep-or-wake-it-mh10330/26/mac/26), [네트워크 깨움](https://support.apple.com/guide/mac-help/share-your-mac-resources-when-its-in-sleep-mh27905/26/mac/26), [전원 연결 자동 시동](https://support.apple.com/en-us/120622) | 지원된 깨움 경로와 시동 설정은 앱 트리거와 다름 | awake/FullWake 뒤 AC 재평가. 수면 중 케이블만 연결하면 항상 원격 가능하다는 보장 제외 |
| [외장 화면의 닫힌 덮개 조건](https://support.apple.com/en-au/102501), [Apple Silicon 액세서리 승인](https://support.apple.com/en-gb/102282) | 외장 화면 클램쉘은 전원·입력·액세서리 조건이 있음 | 물리 외장과 원격 가상 화면 구별. 외장 화면 존재만으로 자기 종료 책임을 넘기지 않음 |
| [ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum), [운영 온도 안내](https://support.apple.com/en-la/102336) | OS 열 상태를 제공. 10~35°C는 주변 환경 온도 | OS 상태로 보호. 주변 온도를 CPU 임계값으로 쓰지 않음. 120분·중지 정책은 제품 결정 |
| [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29) | 등록·승인·실행은 별개 | 사설 ad-hoc 패키지의 실제 승인/업데이트 검증 뒤 채택. 등록 성공만으로 helper 정상 판단 금지 |

공개 소스 snapshot: IOKitUser HEAD `323ead896d04424f87184d8f6ff0cce811aab106`(commit 2026-04-17 UTC), PowerManagement HEAD `d415e45501842834a280930c3eed9186544a67f0`, XNU HEAD `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`(둘 다 commit 2025-10-16 UTC). Apple의 최신 공개 코드가 모든 macOS 26/27 배송 바이너리와 같다는 뜻은 아니다.

현재 로컬 Xcode SDK는 **macOS 27.0**이다. 이 SDK의 IOPMLib.h도 위 deprecated 표기를 포함한다. macOS 26 SDK/기기 동작을 직접 검증했다고 주장하지 않는다. 로컬 `pmset` man page의 `displaysleepnow`는 전체 display sleep, `sleepnow`는 system sleep 명령이다. 미문서화된 `disablesleep`을 일반 공개 API로 홍보하지 않는다.

### 닫힌 MacBook의 전원 감지와 깨움

`IOPSNotificationCreateRunLoopSource`는 전원 정보 변화를 CFRunLoop에 전달한다. [Apple 공식 API](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou?language=occ), [공개 헤더 L319–342](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/ps.subproj/IOPowerSources.h#L319-L342), [구현 L366–434](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/ps.subproj/IOPowerSources.c#L366-L434)에는 덮개가 열려 있어야 한다는 조건이 없다. **닫힌 채 깨어 있는 Mac에서 감지 가능**하다는 판단은 이 계약과 실행 경로에 근거한다. 오늘 물리 시험 결과는 아니다.

| 상태 | 앱의 처리 계약 |
|---|---|
| 닫힌 덮개 + Awake | 실행 중 RunLoop에서 알림을 받고 현재 전원을 재조회 |
| 실제 Sleep·Standby | 앱이 즉시 처리한다고 가정하지 않음. Wake 뒤 현재 상태를 다시 조회 |
| DarkWake | 부분 깨움과 일반 사용자 세션의 FullWake를 구별. 모든 앱의 callback 실행을 보장하지 않음 |
| FullWake | 실행 재개 후 현재 전원으로 자동 조건 재평가. 과거 알림의 전부 재생을 가정하지 않음 |

[IOPSGetProvidingPowerSourceType 헤더 L307–317](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/ps.subproj/IOPowerSources.h#L307-L317)는 AC·배터리·UPS 공급을 반환한다. 충전 여부와 다르며 [Apple powerd L1396–1450](https://github.com/apple-oss-distributions/PowerManagement/blob/d415e45501842834a280930c3eed9186544a67f0/pmconfigd/BatteryTimeRemaining.m#L1396-L1450)도 외부 전원과 충전을 분리한다. 배터리 100%·최적화 충전 때문에 충전이 중단됐다고 AC 분리로 판정하지 않는다.

[XNU AC 변화 처리 L8801–8837](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L8801-L8837)는 덮개 정책을 다시 평가한다. [DarkWake 구분 L6816–6826](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L6816-L6826)과 [닫힌 FullWake 유지 검사 L7793–7812](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOPMrootDomain.cpp#L7793-L7812)는 깨움 조건이 별도임을 보여 준다. AC 처리의 FullWake 사례도 이미 발생한 USB wake와 AC 연결의 조건부 사례다. 케이블 연결을 모든 모델에서의 무조건 FullWake 명령으로 쓰지 않는다.

Keepresso v1.26.0도 [전원 공급/충전 L57–90](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/PowerSource.swift#L57-L90)과 [이미 발생한 Wake 처리 L270–280](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/Keepresso/KeepressoApp.swift#L270-L280)를 나눈다. [클램쉘 backend L381–390](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/ClosedDisplay.swift#L381-L390)의 설정 해제 성공은 실제 Sleep의 증거가 아니다.

[Apple 지원 120622](https://support.apple.com/en-us/120622)의 전원 연결 시 자동 시동은 **자동 부팅** 설명이다. 닫힌 수면 → FullWake → 로그인/원격 준비를 보장하는 문서가 아니다. 공개 소스와 실제 macOS 26 배포 커널·펌웨어의 일치 및 기기별 동작은 별도 실증한다.

## 3. 경쟁 앱의 현재 자료

GitHub 수치는 2026-10-06의 누적 star snapshot이며 활성 사용자 수·설치 수·안전성 지표가 아니다. stable과 main을 별도로 조회했다. Amphetamine/KYA/Keepresso는 기능 기준 비교, OpenLid/Liddy는 구현의 반례를 찾는 보조 비교다. 0-star Liddy를 인기·실사용 추천 후보로 올리지 않는다.

| 앱 | 현재 정식 / 고정 release commit → main | 공개 자료·라이선스 |
|---|---|---|
| [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) | 5.3.2 / 2023-11-10. 본체 소스 비공개 | 트리거·시간/무제한·덮개·앱 잠금 옵션의 제품 기준. 오래된 도움말·현재 OS 보고와 구별 |
| [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | [1.6.8](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.6.8) / `cca86d604835ad4fda1acab4b4807d4c7a1db856` → `2be93dd7f390b23fbca934ff3b1ac03468a80077` | ★6,961 · main commit 2026-08-15 UTC · MIT. 단순한 일반 절전 방지의 기준 |
| [Keepresso](https://github.com/gyorgysh/keepresso) | [v1.26.0](https://github.com/gyorgysh/keepresso/releases/tag/v1.26.0) / `e114f3230e3501005ec285839f874911d24fe024` → `e9d96264d9500e5c3b0bc904d303d13fb3be2d0d` | ★99 · main commit 2026-10-04 UTC · GPL-3.0. 전원·덮개·화면/원격 기능이 가장 가까운 공개 비교 |
| [OpenLid](https://github.com/openlid/openlid) | [v2.4.0](https://github.com/openlid/openlid/releases/tag/v2.4.0) / `ea5c9b9acc60239bb1bad178a02246fd7cc7fa96` → `60a6865ed8e53d112133fa399af3a5c6653478f3` | ★13 · main commit 2026-06-24 UTC · Apache-2.0. helper/상태 표시 반례 |
| [Liddy](https://github.com/bygelo/liddy) | [v0.1.0](https://github.com/bygelo/liddy/releases/tag/v0.1.0) / `6c5e1b0` → `b010439631b0b68f58cefbe564cf7877ea2f6c98` | ★0 · main commit 2026-09-30 UTC · MIT. 정식과 HEAD 차이·복구 코드 참고만 |

### 세션·트리거에서 가져올 원리

- KYA의 [caffeinate 경로 L95–125](https://github.com/newmarcel/KeepingYouAwake/blob/cca86d604835ad4fda1acab4b4807d4c7a1db856/Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/KYASleepWakeTimer.m#L95-L125)는 기간·앱 PID 수명과 일반 assertion을 묶는다. 덮개 우회나 실제 Sleep은 이 경로에 없다. Tether는 native idle assertion을 직접 소유한다.
- Amphetamine의 [전원·덮개 트리거 도움말](https://github.com/x74353/Amphetamine_Localization/blob/4c796caf9e1d54fec37fb50b227b6a426718a780/English/en_Localizable.strings#L1136-L1162)에서 세션과 옵션을 분리하는 UX를 참고한다. 도움말은 5.3.1 / 2023-09-24 snapshot이므로 최신 OS 구현으로 일반화하지 않는다.
- Keepresso의 [세션 종료 L801–840](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/SessionController.swift#L801-L840)와 [종료 action](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/SessionEndAction.swift#L4-L19)은 자체 세션 끝과 실제 Sleep을 구별한다. Tether에도 이 의미를 명확히 둔다.
- Keepresso의 trigger 모드는 timed cap을 적용하지 않으며, Liddy의 [2시간 값 L343–362](https://github.com/bygelo/liddy/blob/b010439631b0b68f58cefbe564cf7877ea2f6c98/Sources/LiddyKit/Runtime/LiddyRuntime.swift#L343-L362)은 보호 예외 창이다. 둘을 사용자가 요구한 배터리 세션 2시간 구현으로 가져오지 않는다.

### 덮개·복구에서 제외할 구현

Amphetamine [Power Protect L8–54](https://github.com/x74353/Amphetamine/blob/f8b3fe1d9363726d6dcbb718df6d8bdb9c041e42/Files/powerProtect.scpt#L8-L54)는 `pmset -a disablesleep 1/0`을 사용하고 원래 값을 저장하지 않는다. 스크립트에는 AC 이벤트 감지나 `sleepnow`가 없다. 공개 Enhancer의 2020년 코드도 본체 5.3.2의 동작 증거가 아니다. [Enhancer 코드](https://github.com/x74353/Amphetamine-Enhancer/blob/c372712a3127fd6e6d77b0bc727dff332489909f/Xcode%20Project/CDMManager/CDMManager/AppDelegate.m#L22-L39).

`disablesleep`을 해제해야 직접 Sleep도 가능한 공개 커널 경로는 위 XNU 근거에서 확인했다. 경쟁 앱의 메뉴가 자체 해제 후 Sleep을 제공하더라도 macOS 메뉴의 Sleep과 동일한 경로라고 가정하지 않는다. 앱이 OSWillSleep을 받아 정리한다는 설계만으로는 차단된 요청을 감지할 수 없다.

Keepresso의 [HelperEngine L621–667](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/HelperEngine.swift#L621-L667)은 변경 전 baseline 기록·원복 실패 debt 보존의 좋은 참고다. 반면 [clearForeignHold L157–177](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/ClosedDisplayCoordinator.swift#L157-L177)는 Tether에 가져오지 않는다.

OpenLid [startup L83–89](https://github.com/openlid/openlid/blob/ea5c9b9acc60239bb1bad178a02246fd7cc7fa96/crates/helper/src/main.rs#L83-L89)는 stale marker 원복 시도 뒤 실패 여부와 무관하게 marker를 제거한다. [마지막 연결 종료 L126–136](https://github.com/openlid/openlid/blob/ea5c9b9acc60239bb1bad178a02246fd7cc7fa96/crates/helper/src/xpc_listener.rs#L126-L136)의 15초 타이머는 원복 없이 process exit를 수행한다. [plist](https://github.com/openlid/openlid/blob/ea5c9b9acc60239bb1bad178a02246fd7cc7fa96/resources/helper/io.openlid.helper.plist#L16-L28)에는 KeepAlive/RunAtLoad가 없다. **15초 내 종료는 15초 내 원복이 아니다.** 이는 정적 경로 분석이며 이 Mac의 crash 재현 결과가 아니다.

Liddy HEAD [ClamshellGuard L83–106](https://github.com/bygelo/liddy/blob/b010439631b0b68f58cefbe564cf7877ea2f6c98/Sources/LiddyKit/Runtime/ClamshellGuard.swift#L83-L106)도 실패한 원복 뒤 자료 삭제 경계가 있다. HEAD의 연결 소유권 수정은 정식 0.1.0에 없으므로 둘을 같은 완성도로 판단하지 않는다.

## 4. 화면·잠금·원격에서 가져올 구분

Keepresso는 [displayOff/zeroBrightness/leaveAlone](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/DisplayPolicy.swift#L9-L17)을 구분한다. [밝기 코드](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/Keepresso/KPBrightness.m#L10-L21)는 비공개 DisplayServices 경로다. 밝기 0을 실제 panel sleep으로 대체하지 않는 상태 구분만 채택한다.

OpenLid의 [display 경로 L54–91](https://github.com/openlid/openlid/blob/ea5c9b9acc60239bb1bad178a02246fd7cc7fa96/crates/app/src/platform/macos/display.rs#L54-L91)는 display-idle assertion과 닫힘 시 `displaysleepnow`를 병용한다. 공개 assertion이 있어도 [Apple 문서](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep)는 덮개·시스템 수면 예외를 설명한다. 무잠금·원격 입력은 미검증이다.

Amphetamine의 [화면 절전 도움말](https://github.com/x74353/Amphetamine_Localization/blob/4c796caf9e1d54fec37fb50b227b6a426718a780/English/en_Localizable.strings#L692-L704)은 OS 타이머에 따른 display sleep을 허용한다. [커서·앱 잠금 도움말](https://github.com/x74353/Amphetamine_Localization/blob/4c796caf9e1d54fec37fb50b227b6a426718a780/English/en_Localizable.strings#L775-L794)에는 VNC/ARD/RDP의 커서 유휴 판단과 앱 잠금 선택이 있지만, OS 암호 요구를 세션 중에만 우회하는 구현 근거는 없다. 커서 자동 이동은 화면 절전을 방해하므로 제외한다.

## 5. 현재 이슈와 회귀 대상으로 쓸 범위

| 보고 | 현재 상태·내용 | 새 인수 조건 |
|---|---|---|
| [Amphetamine #16](https://github.com/x74353/Amphetamine/issues/16) | open · 2026-05-22 · macOS 26.4.1/Mac15,12 · 장시간 수면 후 검은 화면. Power Protect 원인은 작성자의 추정. 댓글·개발자 답변 없음 | 장시간 종료/Wake/화면 준비. 인과가 입증된 앱 결함으로 단정하지 않음 |
| [Amphetamine #19](https://github.com/x74353/Amphetamine/issues/19) | open · 2026-08-22 · macOS 15.6/M1 Pro/5.3.2 · 배터리 시간 세션 종료 보고. 댓글·개발자 답변 없음 | 배터리 시간 만료·덮개 해제·실제 Sleep. macOS 26 결함으로 일반화하지 않음 |
| [KYA #262](https://github.com/newmarcel/KeepingYouAwake/issues/262), [#104](https://github.com/newmarcel/KeepingYouAwake/issues/104) | open · 닫힌 덮개/AC 자동 활성 요청 | KYA를 덮개·전원 트리거 대체재로 홍보하지 않음 |
| [Keepresso #18](https://github.com/gyorgysh/keepresso/issues/18) | closed · 원격 연결 방해. [유지보수자](https://github.com/gyorgysh/keepresso/issues/18#issuecomment-5577297630)는 v1.23.0에서 밝기 0% 대응을 여러 remote display에서 시험했다고 설명 | 반복 화면 절전·virtual display·원격 재연결 검증. closed나 개발자 시험이 Tether/Splashtop의 합격은 아님 |
| [Keepresso #7](https://github.com/gyorgysh/keepresso/issues/7) | closed · 저전력 보호 | OS 경고·자체 해제·수동 예외에서도 보호 적용 |
| OpenLid v2.4.0 release | helper가 동작하지 않아도 유지 중으로 표시했던 결함을 release가 명시 | 명령/ready와 실제 적용 상태 구별 |

최근 갱신 issue/PR 최대 100건에서 PR을 제외해 조사했으며 전체 과거 이슈 전수조사는 아니다. Amphetamine 공식 Freshdesk 목록·관련 FAQ는 이번 조회에서 HTTP 404라 확인 근거로 쓰지 않았다. Reddit 등 후기는 재현 단서만으로 취급하고 제품 동작 결정은 위 1차 근거를 사용했다.

## 6. 새 설계에서 버릴 것과 남길 것

**버림:** 이전 v2의 origin별 누적예산, 자동/예약 240분, AC 30초 재무장, 건강성 90초를 종료 재시도에 사용, AC 시간제의 기존 24시간 상한을 새 무제한 제한으로 해석하는 것, 앱/root 중복 트리거, 반복 display-conflict 회복, 원격용 메뉴 아이콘, 밝기/키보드/에너지 설정 동시 제어.

**남김:** 하나의 세션 결정, 프로세스 소유 일반 assertion, 선택적 덮개 실행 권한, 단일 writer/설치 lock, 변경 전 baseline journal·실패 debt 보존, 사용자 off/보호/설정 이관, 실제 상태 관측과 이유 표시. 120분은 사용자 요구이며 수명 heartbeat/lease 수치는 실험으로 정한다.

### 사용자 요구로 좁힌 기능 선택

같은 날 공식 [Amphetamine 기능 목록](https://apps.apple.com/us/app/amphetamine/id937984704), [KeepingYouAwake README](https://github.com/newmarcel/KeepingYouAwake#keepingyouawake), [Keepresso README](https://github.com/gyorgysh/keepresso#features)와 위 고정 commit의 종료·복구 소스를 다시 대조했다. README의 현재 기능 소개와 고정 소스·실기기 검증을 동일한 증거로 취급하지 않는다. 다음은 **설계 채택 여부**이며 출시 구현 완료 목록이 아니다.

| 기능·원리 | 참고 앱·근거 | 결정·필요한 이유 |
|---|---|---|
| 수동 유지와 자동 트리거 ON/OFF 분리 | Amphetamine, Keepresso 공식 기능 목록 | 유지. 자동을 꺼도 수동을 사용할 수 있고 전체 중지와 범위가 다름 |
| 시간 프리셋·분 단위 직접 입력 | KYA의 기간 선택, Amphetamine/Keepresso의 지정 기간 | 채택. 원하는 시간을 짧게 입력. 마지막 선택 기억은 Tether의 편의 설계이며 실행 세션 재개와 분리. 현재 예시는 프리셋만 구현 |
| 화면 절전 허용, 덮개 유지, 앱 잠금 선택 | Amphetamine 공식 목록·위 화면 도움말 | 유지. 앱 잠금 기본 OFF. 실행 수단이 없는 `로그인 상태 유지` 스위치는 제거하고 OS 정책·실제 잠금을 따로 안내 |
| 세션 종료와 실제 Sleep 구분 | Keepresso `SessionEndAction`·종료 경로 | 핵심 채택. 닫힌 전원 분리에서 자체 해제뿐 아니라 실제 Sleep을 검증. 호환 선택은 접힌 설정으로 제공 |
| 변경 전 원본 보존·원복 실패 기록 | Keepresso `HelperEngine` | 핵심 채택. 업데이트·앱 종료·crash 후 자체 변경만 복구. 실패 기록을 먼저 지우지 않음 |
| 배터리 하한·열 보호 | Amphetamine의 배터리 종료, Keepresso #7, Apple thermal state | 유지·강화할 계약. AC/배터리·자동/수동 모두 열 보호. 최대 2시간은 사용자의 요구이며 경쟁 앱이나 Apple의 안전 보증이 아님 |
| 시작/종료 단축키 | Amphetamine 공식 목록 | 후순위 후보. 핵심 분리·Sleep·복구 검증 뒤 고려. 새 권한·모니터를 먼저 추가하지 않음 |
| 종료 시각 지정·빠른 연장·종료 예고 | Amphetamine 시간 지정·연장, Keepresso `Stop in`·알림 | 이번 범위 보류. 기간 선택으로 충분하며 여러 마감 변경 경로를 줄임 |
| 앱/CPU/네트워크/일정/AI 작업 트리거·예약 깨움 | Amphetamine·Keepresso 공식 목록 | 제외. 사용자가 원하는 전원 조건과 직접 유지에 필요하지 않고 별도 감지·권한·평가 로직이 늘어남 |
| 마우스/키 자동 입력·밝기 0·팬/충전 제어·사용 통계 | Amphetamine·Keepresso의 부가 기능, 위 화면/복구 조사 | 제외. OS/원격 입력·화면·보호 역할과 상충하거나 현재 목적 밖임 |

기본 UI에서는 조작할 수 없는 외관·아이콘 폭 설명 행을 제거하고 배터리 계속 유지 선택을 수동 시작 근처로 옮긴다. 안정/베타 업데이트·설정 이관·용량을 제한한 진단 로그는 기존 요구로 유지하되 베타와 상세 로그는 접는다. 반복 재점등 복구·가짜 입력·외부 요청 강제 해제는 잠금/원격 문제 해결 기능으로 차용하지 않는다.

GPL-3.0 Keepresso 코드를 직접 이식하지 않는다. MIT/Apache 소스도 이번에는 복사하지 않고 확인한 실행 원리를 독립 구현한다. 단순한 라이선스 표기나 star 수를 기능·복구 성공 근거로 쓰지 않는다.

## 7. 현재 소스와 새 구조의 차이

오늘 소스 읽기에서 [사용자 정책](../Sources/TetherCore/Policy/IdleSessionPolicy.swift), [root 정책](../Sources/TetherHelper/Helper.swift), [root 작업 세션](../Sources/TetherHelper/Helper+WorkSession.swift)의 판단 중복을 확인했다. [ProtectionState](../Sources/TetherCore/Policy/ProtectionState.swift)는 보호와 예산을 함께 저장하고, [AppModel](../Sources/Tether/Model/AppModel.swift)의 일부 일반 controller 진입은 helper readiness와 결합되어 있다.

[PowerOwnership](../Sources/TetherCore/Policy/PowerOwnership.swift)의 30초, [SafetyPolicy](../Sources/TetherCore/Policy/SafetyPolicy.swift)의 240분, [SleepRequestPolicy](../Sources/TetherCore/Policy/SleepRequestPolicy.swift)의 종료 시간은 새 정책으로 자동 수입하지 않는다. [ManualSessionPolicy](../Sources/TetherCore/Policy/ManualSessionPolicy.swift)의 `maximumTimedDuration=24h`는 **시간제** 상한이며 `duration=nil`인 AC 무제한은 이미 가능하다. [ScreenGuard](../Sources/Tether/Screen/ScreenGuard.swift)의 원본 삭제는 setter·원복 확인 뒤로 바꿀 대상이다. 상세 대체 책임은 새 실행 설계에 기록했다.

기존 닫힌 전원 분리의 Sleep 요청은 `foreignKeepAwake == false`가 확인돼야 진행한다. 타사 유휴 절전 방지나 그 조회 실패를 이유로 요청을 생략하는 현재 [SleepRequestPolicy](../Sources/TetherCore/Policy/SleepRequestPolicy.swift)는 사용자의 최초 문제와 새 추천 종료 계약을 아직 해결하지 못한다. 원복·명령 성공과 실제 Sleep을 구별하는 검증은 유지하되, ordinary assertion과 다른 작성자의 전역 차단을 구별하는 새 실행부가 필요하다.

## 8. 검증 결과와 남은 합격 조건

리서치 단계의 검증 범위는 공개 원문·pinned 코드·현재 소스·새 계약 데이터의 정합성이었다. 이후 현재 소스의 빌드·자동 실행은 아래 §9에서 확인했으며, 설치본/helper 교체·OS 설정 변경·물리 시험은 수행하지 않았다. 기존 테스트 개수는 v3 통과 수에 포함하지 않는다.

먼저 macOS 26에서 덮개 backend와 자체 해제→실제 Sleep, 화면 꺼짐/잠금/원격 조합을 작은 실험으로 확인한다. 다음 순수 정책·일반 assertion·원복/설치·이관·UI를 구현한다. 무잠금 공개 경로, 사설 SMAppService 승인, watchdog 복구 지연은 **출하 전에 실제 근거가 필요한 항목**으로 남긴다. 설계 문서 완성과 앱 재구현·배포 완료를 구별한다.

## 9. 객관적 지표와 현재 완성도 판정

2026-10-06 18:28 KST의 GitHub REST snapshot과 공식 App Store를 사용했다. star는 관심도, asset 다운로드는 해당 파일의 누적 횟수이며 활성 사용자·장애율·안전성 지표가 아니다. 서로 다른 게시 기간의 다운로드를 직접 순위 점수로 바꾸지 않는다.

| 앱 | 정식 배포·유지보수 자료 | 공개 규모 자료 | 사용자 요구와의 관계 |
|---|---|---|---|
| [Tether](https://github.com/jukqaz/tether) | 공개 [v2.0.1](https://github.com/jukqaz/tether/releases/tag/v2.0.1), 2026-09-26 UTC. 현재 로컬 build 50·v3 설계와 다름 | ★0, 최신 ZIP 3회. [조회 API](https://api.github.com/repos/jukqaz/tether/releases/latest) | 목적을 좁힐 수 있지만 현재 닫힌 분리 종료와 새 실행부가 남음 |
| [Keepresso](https://github.com/gyorgysh/keepresso) | [v1.26.0](https://github.com/gyorgysh/keepresso/releases/tag/v1.26.0), 2026-10-04 UTC. main도 같은 날 갱신. 저장소 생성 2026-06-30 | ★99, 최신 DMG 315회. [조회 API](https://api.github.com/repos/gyorgysh/keepresso/releases/latest) | 전원 트리거·덮개·열 보호·복구·화면/원격 선택을 제공하는 가장 가까운 현재 기준. 개발 이력은 짧음 |
| [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | [1.6.8](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.6.8), 2025-09-12 UTC. main은 2026-08-15 갱신 | ★6,961, 최신 ZIP 235,061회. [조회 API](https://api.github.com/repos/newmarcel/KeepingYouAwake/releases/tags/1.6.8) | 일반 절전 방지의 단순한 기준. 통합 덮개·AC 자동 기능 요청은 open이므로 핵심 요구의 단독 대체재가 아님 |
| [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) | 공식 정식 5.3.2, 2023-11-10. 본체 비공개 | 이번 조회에서 유효 평점·평가 수/활성 사용자 수를 확보하지 못함 | 일반 세션·트리거는 풍부. 정식 갱신 간격과 현재 Apple Silicon Power Protect 사용자 보고는 별도 확인 필요 |

Amphetamine의 평가 수 미확인을 사용자 0명으로 해석하지 않는다. Keepresso의 open issue 0도 결함 없음의 증거가 아니다. KYA는 정식 배포보다 main 갱신이 최근이므로 정식 날짜 하나만으로 유지보수 중단이라 단정하지 않는다.

Keepresso는 AC 트리거·`Only while brewing`·세션 종료 `Sleep Mac`을 조합할 수 있다. [종료 코드 L1238–1259](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/SessionController.swift#L1238-L1259)와 [종료 action](https://github.com/gyorgysh/keepresso/blob/e114f3230e3501005ec285839f874911d24fe024/Sources/KeepressoCore/SessionEndAction.swift#L4-L19)은 trigger 해제 후 Sleep 경로를 지원한다. 이는 정적 코드 근거다. 다른 trigger/lease가 남으면 세션이 계속될 수 있고, 일괄 종료 action이 Tether의 **닫힌 전원 분리만** Sleep하는 계약과 같다는 보장은 없다. 이 Mac의 실물 분리·원격 시험은 하지 않았다.

**현재 Tether가 경쟁 앱보다 전반적으로 뛰어나다는 근거는 없다.** 원복 journal·진단 로그·열/잔량 보호·수동 무제한은 Keepresso에도 대응 기능이 있으며 독점 장점으로 세지 않는다. Tether의 가능한 이점은 원하는 전원 종료에 집중한 조작과 이유 설명, 배터리 예외의 고정 마감, 외부 자원과 자체 자원의 구별이다. 새 구현과 같은 조건의 실제 시험에서 확인해야 장점으로 판정한다.

| 평가 항목 | 현재 Tether의 확인된 결과 | 비교 결론 |
|---|---|---|
| 기존 코드 회귀 | macOS 27에서 860개 단위·26개 통합 그룹·11개 실제 시간 모의 시험 통과 | 회귀 기반은 있음. 새 정책 52개 또는 경쟁 앱보다 낮은 장애율을 증명하지 않음 |
| 패키지·이관 | 로컬 arm64/최소 OS 26 패키지, 패키지 실행 14개, 이전 build 49 이관/롤백 fixture 7개 통과 | 실제 관리자 설치·게시·실행 중 이전 앱 업데이트는 미확인 |
| 요청 수명·공존 | 정지한 자체 idle 요청은 이 OS에서 90초 기한 뒤 해제되고 독립 요청 유지 | 유용한 직접 근거. root watchdog·다른 OS/모델·실제 Sleep까지 일반화하지 않음 |
| 핵심 분리 종료 | 타사 일반 요청/조회 실패 때문에 기존 Sleep 생략 가능, v3 미구현 | 현재 사용자 요구의 중요한 공백 |
| 화면·무잠금·원격 | 미리보기 설명/작은 창 일부 검토. 실제 세 조건 동시 검증 없음 | Keepresso #18의 밝기 0 대응도 실제 화면 절전 요구와 동일하지 않음 |
| CPU·메모리·에너지·발열·실패율 | 같은 기기/작업의 경쟁 후보 비교 측정 없음 | 더 빠름·저전력·안전·내구성 우위를 주장하지 않음 |

따라서 Keepresso를 현재 기능 비교의 기준으로 두고, Tether는 닫힌 AC 분리·배터리 예외·원격 경로와 원복을 실제로 더 명확하게 처리하는지를 검증하는 것이 개발 이유다. 그 차이가 실증되지 않으면 기존 앱보다 월등하다는 결론을 내리지 않는다. [자동/직접 시험과 결과별 결정](VALIDATION-CHECKLIST.ko.md)에 완료·미구현·실물 미확인을 나눴다.
