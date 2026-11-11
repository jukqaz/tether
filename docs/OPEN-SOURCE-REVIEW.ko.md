# 오픈소스 코드 대조와 채택 · 2026-09-29

2026-10-06: **아래는 이전 설계·구현의 기록이다. 다음 구현의 계약·근거로 사용하지 않는다. 현재 기준은 [새 기능 정의](PRODUCT-SPEC.ko.md), [실행 설계](ARCHITECTURE-REDESIGN.ko.md), [새 조사](COMPETITOR-DEEP-RESEARCH.ko.md)다. 과거 검증 결과를 v3 합격으로 재사용하지 않는다.**

이 문서는 2026-09-29 구현의 기록이다. 다음 구현의 기준은 [기능 정의](PRODUCT-SPEC.ko.md)·[재설계 아키텍처](ARCHITECTURE-REDESIGN.ko.md)·[2026-09-30 코드 대조와 장애 계약](ARCHITECTURE-REVIEW.ko.md)이다. 아래의 ‘화면 충돌 → 보호 중지·시스템 잠자기’ 결정은 재설계에서 폐기하고 화면 실패를 별도 상태로 격리한다. 과거 검증 결과는 그대로 보존하며 새 설계의 합격으로 취급하지 않는다.

목표는 외장 화면 없는 클램쉘의 안정성과 복구다. 아래는 고정 커밋의 소스 검사 결과이며, 네 앱을 같은 기기에서 새로 실행한 비교 시험이 아니다. Tether의 실기기 실패는 `19:19:45` 화면 끄기 직후 외부 UserIsActive와 화면 켜짐, `19:19:55` 보호 중지, `19:20:00` 실제 Clamshell Sleep이었다. 이 실패 경로를 우선 보완했다.

## 확인한 구현과 결정

| 프로젝트·고정 커밋 | 실제 코드에서 확인한 접근 | Tether 결정 |
|---|---|---|
| [Keepresso v1.25.0 · 5837a0b](https://github.com/gyorgysh/keepresso/blob/5837a0be0764c6637c09c29c606405e0630e43ed/Sources/KeepressoCore/ClosedDisplay.swift#L125-L201) | 닫힘 진입 시 화면 절전을 요청하고, 내장 화면이 실제 켜짐으로 읽히면 5초 간격 제한 후 재요청. 외장 화면이 있으면 전체 화면 끄기를 생략 | **채택:** 켜짐을 관측한 뒤 재시도하는 원리. Tether는 10초 관측 창·세션당 최대 3회로 제한하고 지속 충돌은 보호 중지. 요청 직전 덮개·외장 화면·전원·소유권을 다시 확인 |
| [Keepresso 화면 조회](https://github.com/gyorgysh/keepresso/blob/5837a0be0764c6637c09c29c606405e0630e43ed/Sources/KeepressoCore/Display.swift#L45-L78) | 잠든 내장 화면도 읽기 위해 active 목록과 별도로 online 목록·`CGDisplayIsAsleep` 사용 | **기존 구현 유지:** Tether도 online 목록을 사용. 조회 실패·내장 화면 부재는 꺼짐 성공으로 바꾸지 않음. 알 수 없는 상태에서 재요청을 늘리지 않음 |
| [Liddy · 6c5e1b0](https://github.com/bygelo/liddy/blob/6c5e1b00efef3911cb7747d534060c7b6d94ae7c/Sources/LiddyHelper/main.swift#L73-L157) | 관리자 도우미가 전역 설정을 관리하고 앱 연결 종료·heartbeat 만료 때 해제. 시작 시 잔여 기록 복구 | **기존 구현 유지:** Tether는 PID와 프로세스 시작 시각, 종료 알림, 별도 launchd watchdog, 현재 부팅의 소유권 기록을 사용. GUI heartbeat 의존성을 추가하지 않음. 보호 판단은 도우미에서 계속 실행 |
| [Liddy 보호 정책](https://github.com/bygelo/liddy/blob/6c5e1b00efef3911cb7747d534060c7b6d94ae7c/Sources/LiddyKit/Safety/SafetyGovernor.swift#L26-L106) | 부작용 없는 정책 계층과 명령 실행 계층을 분리. 보호의 심각도에 따라 해제 또는 sleep 요청 | **기존 구현 유지:** Tether의 순수 정책·도우미 실행 구조, 센서 실패와 열·배터리 보호가 화면 복구보다 우선하는 회귀 검증을 유지. 경쟁 앱 임계값이나 물리적 설명을 제조사 안전 근거로 채택하지 않음 |
| [Foldwake · 36a97c2](https://github.com/thavguard/foldwake/blob/36a97c2f0f5910d285f4f7ecad5308e2e8b1a97e/Sources/FoldwakeHelper/main.swift#L105-L140) | pmset 성공 후 실제 `SleepDisabled`를 다시 조회해 요청값과 비교 | **기존 구현 유지:** Tether의 `applyOverride`도 실제 OS 값을 재확인하고 실패 시 복구 기록 보존. 명령 종료 코드만으로 켜짐·원복·실제 sleep 성공을 선언하지 않음 |
| [Sleepless · 2a690e5](https://github.com/Aboudjem/Sleepless/blob/2a690e50724ffc17440ef58e5e0c9f69c82452fa/App.swift#L569-L644) | 명령 권한 실패와 전원 상태 조회를 구분. 배터리 하한과 저전력 모드에 따라 해제 | **부분 원리 유지:** 명령 실패와 관측 상태를 구분하는 Tether 진단 유지. 일반 앱에 sudoers 권한을 주는 구조나 모든 사용자 저전력 설정을 종료 조건으로 바꾸는 동작은 도입하지 않음 |

## 이번 반영

1. `DisplaySleepGate`: 일시적 화면 깨움은 즉시 클램쉘 실패로 처리하지 않고 관측 창을 거쳐 재시도한다. 처음부터 계속 켜져 있으면 t=0·10·20초에 요청, t=30초부터 실패 판정이 가능하다. 실제 적용 지연에는 3초 폴링과 명령 수행 시간이 더해질 수 있다.
2. 화면 꺼짐이 한 번 관측되어도 같은 덮개 세션의 요청 횟수를 충전하지 않는다. 외부 앱이 매번 깨우는 상황에서 무한히 화면을 끄지 않는다. 10초·3회는 공학적 예산이며 제조사 기준이나 최적값의 증명이 아니다.
3. 열·센서·배터리·전원·소유권 조건이 바뀌면 복구 요청을 취소한다. 외장 화면을 새로 연결했을 때 해당 화면까지 끄지 않도록 요청 직전 재조회한다.
4. `Helper+Display`: 시도 횟수·화면 관측값·화면 유지 요청 PID를 기록한다. PID가 존재한다는 이유만으로 해당 앱을 실제 깨움의 원인으로 확정하지 않는다. assertion 이름·문서 제목·URL은 수집하지 않는다.
5. `RecentActivity`: 화면 재시도·꺼짐 확인·복구 중단의 고정 이벤트를 읽는다. 가변 진단 문구와 사용자용 활동 목록을 분리해 문구 변경으로 사건이 누락되지 않게 했다. 이전 버전 중지 문구도 호환된다.

## 제외

- 무제한 주기적 화면 끄기, 밝기 0으로 위장한 화면 끄기, 가상 모니터 추가, 비공개 화면 연결 해제 API.
- 다른 앱 강제 종료, 타 앱의 절전 방지 요청 해제, 운영체제 잠금 정책 변경.
- CLI 작업 lease·AI 에이전트 연동·규칙 엔진·팬·충전 제어 등 합의한 핵심 범위 밖의 기능.

## 출처와 검증 경계

Keepresso의 [GPL-3.0 라이선스](https://github.com/gyorgysh/keepresso/blob/5837a0be0764c6637c09c29c606405e0630e43ed/LICENSE), Liddy·Foldwake·Sleepless의 각 저장소 MIT 라이선스를 확인했다. 이번 변경은 동작 원리를 대조한 Tether 자체 구현이며 외부 소스의 복사·번역·의존성 추가는 없다. 조사용 파일은 앱 번들이나 저장소 소스에 포함하지 않는다.

회귀 검증은 실제 실패 시각 재현, 영구 켜짐, 간헐적 재점등, 관측 불가, 덮개 열림·외장 화면·전원 분리·열 보호 우선순위, 활동 이벤트와 구버전 로그 호환을 포함한다. 실제 닫힌 덮개 유지·내장 패널 전력·장시간 작업 성공은 별도 실기기 로그가 필요하다. 화면 꺼짐 관측은 패널 전력 0이나 시스템 잠자기의 증명이 아니다.
