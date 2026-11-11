# Tether 표시 문구

이 문서는 메뉴바·설정·상태 설명에 사용하는 한국어·영어 용어를 관리한다. 기능 규칙·기본값·지원 조건은 [기능명세서](PRODUCT-SPEC.ko.md)가 우선한다.
화면 구성은 [정보 구조](DESIGN-V5.ko.md), 색·서체·간격은 [스타일 가이드](../DESIGN.md)를 따른다.
문구를 정리한 사실은 실제 앱 반영·설치·화면 검수·물리 동작 검증 완료를 뜻하지 않는다. 문구 변경으로 기존 승인 옵션이나 전원 분리·종료·보호·복구 규칙을 바꾸지 않는다.
정리 전 문구와 기록은 [보관 문서](archive/2026-10-21-spec-cleanup/COPY-V5.ko.md)에 남긴다.

2026-11-10 승인 제품 구성은 통합 메뉴·설정 4페이지·시작하기를 기준으로 한다. Liquid Glass 효과는 제거하고 일반 macOS bordered 컨트롤과 불투명 읽기 표면을 사용한다. 전체 옵션 카탈로그·미지원 로드맵·검토용 시안 표식은 제품 주 동선에 표시하지 않으며 기존 기능은 담당 페이지·편집창으로 연결한다.

## 문장과 적용 범위

- 상태·항목 이름은 짧은 명사형, 버튼은 실행 대상을 드러내는 동사형으로 쓴다. 한국어 설명은 `합니다`체, 영어 설명은 sentence case로 통일한다. 고정 탐색·그룹 제목은 기존 Mac 스타일 표기를 유지한다.
- `자동 유지`와 `수동 유지`는 실행 주체를 구분한다. `타이머`는 종료 시각이 있는 수동 유지에만 사용한다. 종료 시각이 없는 유지도 `수동 유지`이며 `타이머`라고 부르지 않는다.
- **허용**, **요청**, **적용 중**, **확인됨**을 구분한다. 허용 체크만으로 작업을 시작하거나 화면·덮개 기능이 현재 적용됐다고 표시하지 않는다.
- 현재 작업에 적용되는 선택, 다음 수동 시작의 기본값, 앱 전체 허용을 같은 범위처럼 설명하지 않는다. 범위에 맞는 실제 모델의 값을 사용한다.
- 알려진 상태만 표시한다. 조회 실패를 `꺼짐`, `0`, `없음`, `미연결`, `최신`으로 바꾸지 않는다. 원인·시각·개수는 실제 확인값으로 채운다.
- 한국어·영어에서 모두 같은 정보를 제공한다. 긴 문구는 줄바꿈하고, 영문 길이를 맞추기 위해 필수 제약이나 실행 대상을 생략하지 않는다.

### 저장 방식과 적용 시점

`즉시 저장`은 저장 방식을 뜻하며 `현재 유지에 즉시 적용`과 같은 뜻이 아니다. 각 옵션은 저장 방식과 적용 대상을 따로 설명한다.

| 옵션 범위 | 저장 방식 | 적용 대상 | 기본 안내 · KO / EN |
|---|---|---|---|
| 수동 유지의 화면·덮개·유휴 기본값 | `적용 / Apply`를 눌러 저장합니다. `변경 취소 / Discard`는 이 편집 내용만 되돌립니다. | 다음에 직접 시작할 수동 유지입니다. 현재 요청·기한은 바꾸지 않습니다. | 적용하면 다음 수동 유지부터 사용합니다. / Apply to save for the next manual start. |
| 수동 유지의 전원 조건 | 변경 즉시 저장합니다. 위의 적용·변경 취소에 포함되지 않습니다. | 다음에 직접 시작할 수동 유지입니다. 현재 요청·전원 범위는 바꾸지 않습니다. | 즉시 저장 · 다음 수동 유지부터 / Saves immediately · Next manual start |
| 배터리 시간 한도 | 변경 즉시 저장합니다. 위의 적용·변경 취소에 포함되지 않습니다. | 새 수동 유지와 고급 자동의 새 조건 구간(activation)에 한도를 저장합니다. 현재 요청의 기한·배터리 한도나 같은 고급 자동 구간의 재개 한도는 바꾸지 않습니다. | 즉시 저장 · 새 유지부터 / Saves immediately · New work only |
| 전원·덮개의 앱 전체 허용 | 변경 즉시 저장합니다. 별도 적용 버튼을 사용하지 않습니다. | 기본 전원 자동 유지에는 허용한 기능을 사용합니다. 고급 자동·수동 유지에는 별도로 선택한 기능만 허용합니다. 현재·다음 유지에 이 규칙을 적용하며 새 유지를 시작하지 않습니다. | 즉시 저장 · 현재·다음 유지에 적용 / Saves immediately · Current and future work |

기본 화면에는 한 줄 요약을 두고, 저장·적용의 전체 범위와 macOS 정책 설명은 기본으로 접힌 안내에 둔다. 표의 상세 설명 전체를 옵션마다 반복 노출하지 않는다. 현재 경고·도우미 준비 필요·복구 실패·보호 중지 이유와 필요한 다음 조작은 접지 않는다.

### 메뉴바의 정보 반복

- 상단 상태가 실행 주체를 이미 밝히면 별도 `실행 중인 유지 / Active keep-awake` 제목을 추가하지 않는다.
- 자동만 실행 중이면 본문에 `자동 유지` 라벨을 반복하지 않고 확인한 조건·전원 상태를 표시한다. 수동만 실행 중이면 시간 정보와 종료 조작을 표시한다.
- 종료 시각이 없으면 `종료할 때까지 / Until ended`만 표시하며 `종료 시간 없음 / No scheduled end time`을 덧붙이지 않는다.
- 자동·수동이 함께 실행 중일 때는 각 행의 구분 라벨과 `자동 유지는 계속됩니다. / Automatic keep-awake continues.` 안내를 유지한다. 전체 종료 범위는 종료 버튼의 도움말과 접근성 설명에서 제공한다.
- 수동 종료의 대상은 버튼·도움말·접근성 설명에 남긴다. 자동·수동 공존처럼 오해할 상황이 아닌 기본 화면에서는 같은 범위를 여러 문장으로 반복하지 않는다.

## 공통 용어 · KO / EN

| 내부 용어·이전 표현 | 한국어 | English | 의미·범위 |
|---|---|---|---|
| AC | 전원 연결 중 | On power | 확인한 전원 상태 |
| 배터리 공급 | 배터리 사용 중 | On battery | 확인한 전원 상태 |
| automatic hold | 자동 유지 | Automatic keep-awake | 허용된 자동 조건으로 시작한 잠자기 방지 |
| manual session·직접 유지 | 수동 유지 | Manual keep-awake | 사용자가 직접 시작한 유지. 시간제·종료 시각 없음 모두 포함 |
| timed manual | 종료 시각이 있는 수동 유지 | Timed manual keep-awake | 남은 시간·종료 시각·연장이 의미 있는 경우 |
| unlimited·무제한·끄기 전까지 | 종료할 때까지 | Until ended | 시간 만료가 없다는 뜻. 전원·보호·종료 규칙을 무시한다는 뜻이 아님 |
| 클램쉘·덮개 유지 | 덮개를 닫고 사용 | Closed-lid use | MacBook 덮개 기능. 일반 잠자기 방지와 구분 |
| display hold | 화면 켜두기 | Display keep-awake | Tether의 화면 꺼짐 방지 요청. 잠금 설정 변경이나 잠금 해제가 아님 |
| assertion | 잠자기 방지 요청 | Keep-awake request | 확인된 OS 요청을 설명할 때 사용 |
| 자동 트리거 | 자동 시작 조건 | Automatic conditions | 기본 전원 조건과 승인된 고급 조건의 실제 적용 범위를 구분 |
| 전원 분리 정책 | 전원 분리 시 | When unplugged | 전원을 분리했을 때 기존 유지에 적용하는 선택 |
| 원복 | 전원·화면 상태 복원 | Restore power and display changes | Tether가 변경한 실행 상태의 복구. 저장한 환경설정은 유지하며 실제 복구 확인 상태를 구분 |
| 전원 unknown | 전원 상태 확인 중 | Checking power source | 전원이 연결되거나 분리됐다고 단정하지 않음 |
| 충돌 앱·다른 전원 앱 | 다른 앱의 잠자기 방지 요청 | Other apps’ keep-awake requests | 실제 요청을 관측한 경우만 표시 |
| external work·lease | 외부 작업에 맞춰 유지 | Keep awake for external work | 도구가 보낸 명시적 시작·종료 이벤트에 맞춘 유지 |
| import / export | 설정 가져오기·내보내기 | Import and export settings | 저장된 설정의 이동. 진행 중이거나 종료된 유지의 복원이 아님 |
| stable / stable + beta | 정식 / 정식 + 베타 | Stable / Stable + Beta | 선택한 업데이트 채널 |

## 메뉴바 조작

| 조작 | 한국어 | English | 실제 적용 범위·설명 |
|---|---|---|---|
| 새 수동 유지 | 수동 유지 시작(메뉴 버튼) | Start manual (menu button) | 선택한 조건으로 새 수동 유지를 시작합니다. 시간을 고르는 것만으로 시작하지 않습니다. 버튼의 접근성 이름은 직접 시작 / Start manually입니다. |
| 현재 수동 종료 | 수동 종료(메뉴 버튼) | End manual | 직접 시작한 수동 유지만 종료합니다. 유효한 자동 유지는 계속됩니다. 버튼의 접근성 이름은 수동 유지 종료 / End manual keep-awake입니다. |
| 실행 중 시간 연장 | {선택한 시간} 추가 | Add {selected duration} | 종료 시각이 있는 수동 유지의 현재 기한에 더합니다. 종료 시각이 없는 유지에는 표시하지 않습니다. |
| 전체 중지 | 모두 중지 | Stop all | 현재 유지를 모두 종료하고 사용자가 중지를 해제할 때까지 새 자동 시작을 막습니다. |
| 전체 중지 해제 · 메뉴바 | 중지 해제 | Resume | 현재 자동 조건을 다시 평가합니다. 종료된 수동 유지는 다시 시작하지 않습니다. |
| 전체 중지 해제 · 설정 | 중지 해제 | Resume keep-awake | 메뉴바의 중지 해제와 같은 동작입니다. 긴 영문 버튼을 사용할 수 있는 설정에서만 확장 표기를 씁니다. |
| 자동 일시정지 | 자동만 일시 중지 | Pause automatic | 수동 유지와 저장된 자동 켜짐·꺼짐 선택은 바꾸지 않습니다. |
| 자동 일시정지 해제 | 자동 재개 | Resume automatic | 현재 자동 조건을 다시 확인합니다. 수동 유지를 만들지 않습니다. |
| 자동 시작 스위치 | 전원 연결 시 자동 시작 | Start automatically on power | 전원이 연결된 동안 자동 조건을 평가합니다. 중지·보호·복구 차단을 해제하는 조작이 아닙니다. |
| 전원 분리 선택 | 모두 종료 / 자동 유지 종료 / 허용된 유지 계속 | End all / End automatic / Continue allowed work | 선택한 기존 분리 규칙을 적용합니다. `모두 중지`의 사용자 중지 상태와 같은 조작으로 설명하지 않습니다. |
| 통계 진입 | 사용 통계 | Usage statistics | 실제 저장된 통계로 이동합니다. |
| 최근 기록 진입 | 최근 동작 | Recent activity | 실제 기록으로 이동합니다. |
| 진단 진입 | 로그와 보고서 | Logs and reports | 진단 기능으로 이동합니다. |

`수동 유지 종료`, `자동 시작 끄기`, `자동만 일시 중지`, `모두 중지`는 대상과 결과가 다르다. 하나의 `종료` 또는 `중지` 문구로 합치지 않는다.
전원 재연결·중지 해제·보호 해제·설정 가져오기·다음 기본값 적용이 종료된 수동 유지를 되살린다고 설명하지 않는다.

## 설정 페이지와 옵션

| 위치·항목 | 한국어 | English | 설명 |
|---|---|---|---|
| 전원·덮개 페이지 | 전원·덮개 | Power & Lid | 자동 시작, 전원 분리, 덮개·화면 허용을 설정합니다. |
| 수동 유지 페이지 | 수동 유지 | Manual Keep-awake | 다음에 직접 시작할 수동 유지의 기본값을 설정합니다. |
| 보호·진단 페이지 | 보호·진단 | Protection & Diagnostics | 보호·재개 선택과 실제 진단 정보를 확인합니다. |
| 일반 페이지 | 일반 | General | 앱·업데이트·설정 이동을 관리합니다. |
| 덮개 앱 전체 허용 | 덮개 닫고 사용 허용 | Allow closed-lid use | 변경 즉시 저장됩니다. 기본 전원 자동 유지에는 허용한 덮개 기능을 사용합니다. 고급 자동·수동 유지에는 덮개 기능을 별도로 선택해야 합니다. 허용만으로 새 유지를 시작하지 않습니다. |
| 화면 앱 전체 허용 | 화면 켜두기 허용 | Allow display keep-awake | 변경 즉시 저장됩니다. 기본 전원 자동 유지에는 허용한 화면 기능을 사용합니다. 고급 자동·수동 유지에는 화면 기능을 별도로 선택해야 합니다. 잠금은 macOS 설정을 따릅니다. |
| 허용 범위 안내 | 화면·덮개 허용 안내 | About display and lid permissions | 허용은 앱 전체의 기능 사용 허가입니다. 기본 전원 자동 유지가 허용값을 기능 요청으로 사용하는 경우와, 고급 자동·수동 유지의 별도 기능 선택을 구분합니다. |
| 화면 유휴 동작 | 입력 없으면 화면 켜두기 해제 | Release display keep-awake when idle | 설정한 시간 동안 입력이 없으면 Tether의 화면 켜두기 요청만 해제합니다. 컴퓨터 잠자기 방지는 계속합니다. |
| 보호 재개 선택 | 보호 중지 후 재개 | Resume after protection | 안전한 상태를 확인한 뒤 선택한 재개 방식을 적용합니다. 자동 재개는 현재 자동 조건을 다시 평가하며 종료된 수동 유지는 다시 시작하지 않습니다. |
| 외부 연동 선택 | 외부 작업에 맞춰 유지 | Keep awake for external work | 연결한 도구가 보내는 명시적 시작·종료 이벤트를 사용합니다. AI 작업이나 원격 접속 자체를 감지해 시작하지 않습니다. |
| 다음 시작의 기본값 | 다음 수동 유지 기본값 | Defaults for the next manual start | 현재 유지의 기한·요청은 바꾸지 않습니다. 별도 즉시 저장 옵션은 해당 범위를 표시합니다. |
| 설정 이동 진입 | 설정 가져오기·내보내기 | Import and export settings | 저장된 설정만 가져오거나 내보냅니다. 진행 중인 유지·중지 상태·권한·복구 저널을 복원하지 않습니다. |
| 가져오기 조작 | 설정 가져오기… | Import settings… | 검토한 설정을 기존 가져오기 규칙에 따라 적용합니다. |
| 내보내기 조작 | 설정 내보내기… | Export settings… | 저장된 설정을 파일로 내보냅니다. |
| 일반의 알림 | 종료·보호 알림 | Completion & Protection Notices | 일반 페이지의 접힌 상세에서 즉시 저장합니다. 알림을 꺼도 보호는 계속됩니다. |
| 일반의 고급 연동 | 명령으로 제어 | Command-line Control | 현재 지원되는 수동 시작·연장·종료·상태 조회 CLI와 URL을 복사합니다. 명령이나 PID 수명에 연결한 수동 실행으로 소개하지 않습니다. |
| 일반의 작업 이벤트 | 작업 이벤트 연동 | Work Event Actions | 확인된 사건에 설정한 HTTPS Webhook을 연결합니다. |
| 앱 종료 안내 | 저장한 환경설정은 유지됩니다. | Saved preferences are retained. | 앱 종료는 자체 유지와 전원·화면 변경을 해제·복구합니다. 종료된 수동 유지는 다시 시작하지 않습니다. |

## 상태별 표시 · timed / untimed / dual / paused / protected / error

| 확인된 상태 | 주표시 · KO / EN | 보조 설명과 표시할 값 | 조작·표시 제한 |
|---|---|---|---|
| 실행 없음·자동 꺼짐 | 잠자기 방지 꺼짐 / Keep-awake off | 자동 시작이 꺼져 있습니다. / Automatic start is off. | 허용된 새 수동 시작을 표시합니다. |
| 기본 자동 조건 대기 | 전원 연결 대기 중 / Waiting for power | 전원 연결 조건을 기다립니다. / Waiting for the power condition. | 기존 고급 규칙을 켠 경우 전원 전용이라고 표시하지 않습니다. |
| 자동 유지 중 | 자동 유지 중 / Automatic keep-awake active | 확인한 시작 이유·현재 전원 상태를 표시합니다. | 수동 종료 버튼을 표시하지 않습니다. |
| 시간제 수동 유지 중 · timed | 수동 유지 중 / Manual keep-awake active | 남은 시간·종료 시각을 표시합니다. / Time remaining · Ends at {time} | 수동 유지 종료와 허용된 시간 추가를 표시합니다. 다음 시간 선택은 현재 기한을 바꾸지 않습니다. |
| 종료 시각 없는 수동 유지 중 · untimed | 수동 유지 중 / Manual keep-awake active | 종료할 때까지 / Until ended | 수동 유지 종료를 표시합니다. 남은 시간·종료 시각·타이머·시간 추가는 표시하지 않습니다. |
| 자동·수동 유지 중 · dual | 자동·수동 유지 중 / Automatic + manual active | 수동 유지가 시간제면 남은 시간·종료 시각, 아니면 종료할 때까지를 표시합니다. 자동도 적용 중임을 구분합니다. | 수동 유지 종료는 수동만 종료합니다. 모두 중지는 둘 다 중지합니다. |
| 수동 종료 뒤 자동만 남음 | 자동 유지 중 / Automatic keep-awake active | 필요하면 최근 기록에서 수동 유지 종료 이유를 보여줍니다. | 현재 상태를 종료된 타이머처럼 표시하지 않습니다. |
| 자동 유지 일시 중지됨 | 자동 유지 일시 중지됨 / Automatic starts are paused | 재개 시각 또는 직접 재개 안내를 표시합니다. 영문 시각 설명은 `Automatic starts paused until {time}`으로 씁니다. 수동 유지가 진행 중이면 주표시는 수동 유지 중이며 자동 일시정지는 보조 설명으로 표시합니다. | 수동 유지의 현재 시간·종료 조작을 유지합니다. |
| 모두 중지 · paused | 모두 중지됨 / All keep-awake stopped | 중지를 해제할 때까지 새 자동 시작을 막습니다. / Automatic start stays blocked until you resume. | 중지 해제를 표시합니다. 종료된 수동 유지는 다시 시작하지 않습니다. |
| 중지 해제 직후 | 자동 조건 확인 중 / Checking automatic conditions | 현재 조건을 다시 확인합니다. 종료된 수동 유지는 다시 시작하지 않습니다. / Current conditions are checked again. Ended manual work is not restarted. | 조건 확인 전 자동 유지가 시작됐다고 표시하지 않습니다. |
| 보호 중지 · protected | 보호를 위해 중지됨 / Stopped for protection | 확인된 보호 이유를 표시합니다. | 안전 확인·재개 가능 여부를 기존 정책대로 표시합니다. 보호로 종료된 수동 유지를 대기 중인 타이머로 표시하지 않습니다. |
| 보호 후 안전 확인 중 | 안전 상태 확인 중 / Checking safe conditions | 다시 시작할 수 있는 상태인지 확인합니다. / Checking whether it is safe to resume. | 확인 전에 재개 완료라고 표시하지 않습니다. |
| 보호 해제 후 재개 가능 | 다시 시작 가능 / Ready to resume | 선택한 재개 방식과 현재 자동 조건을 구분합니다. | 종료된 수동 유지는 새로 직접 시작해야 합니다. |
| 전원 관측 대기 | 전원 상태 확인 중 / Checking power source | 현재 전원 상태를 확인합니다. / Checking the current power source. | 새 시작·연장 가능 여부는 기존 판정을 따릅니다. 관측 실패만으로 현재 유지가 종료됐다고 표시하지 않습니다. |
| 유지 해제 확인 중 | 유지 해제 확인 중 / Confirming release | 자체 요청의 해제 결과를 확인합니다. / Checking that Tether’s requests were released. | 실제 확인 전 종료 완료라고 표시하지 않습니다. |
| 요청·해제·복구 오류 · error | 확인 필요 / Review needed | 실패한 작업·확인된 이유·필요한 다음 조작을 표시합니다. | 알려진 현재 유지·권한·적용 결과를 보존합니다. 오류만으로 꺼짐·복구 완료를 만들지 않습니다. |
| 자체 해제 확인됨 | Tether 유지 종료 / Tether keep-awake ended | 확인한 종료 이유를 표시합니다. | 다른 앱의 요청 해제나 실제 Mac 잠자기까지 확인됐다는 뜻으로 쓰지 않습니다. |
| 설정 복구 진행 | 원래 설정으로 되돌리는 중 / Restoring original settings | 확인한 진행 상태를 표시합니다. | 성공 여부를 별도로 확인합니다. |
| 설정 복구 미확인·실패 | 설정 복구 확인 필요 / Settings recovery needs review | 복구하지 못했거나 확인하지 못한 항목과 이유를 표시합니다. | `복구됨`으로 표시하지 않습니다. |
| 잠자기 요청 수락 | Mac 잠자기 요청됨 / Mac sleep requested | 실제 잠자기 여부는 아직 확인되지 않았습니다. / Actual sleep has not been confirmed. | 명령 수락과 실제 Sleep 전이를 구분합니다. |
| 실제 잠자기 전이 관측 | Mac 잠자기 확인 / Mac sleep confirmed | 실제 확인 시각을 표시합니다. | 관측 근거가 있는 경우에만 사용합니다. |

중지·보호·해제 확인·오류의 우선순위는 현재 상태 머신을 따른다. 문구를 맞추기 위해 상태를 만들거나 정상 유지·오류를 숨기지 않는다.

## 덮개와 화면의 현재 적용 설명

| 상태·선택 | 한국어 | English |
|---|---|---|
| 덮개 도우미 준비 필요 | 덮개 기능 준비가 필요합니다. 일반 잠자기 방지는 바로 사용할 수 있습니다. | Closed-lid support needs setup. General keep-awake remains available. |
| 실제 열림·덮개 유지 기능 적용 확인 | 덮개 열림 · 닫고 사용 준비됨 | Lid open · ready for closed-lid use |
| 실제 닫힘·덮개 유지 기능 적용 확인 | 덮개 닫힘 · 덮개 유지 적용 중 | Lid closed · closed-lid support active |
| 덮개 관측 없음 | 덮개 상태 확인 중 · {확인한 실행 상태} | Checking lid state · {confirmed execution status} |
| 덮개 허용 꺼짐 | {실제 덮개 상태} · 덮개 유지 허용 꺼짐 | {observed lid state} · closed-lid permission off |
| 덮개 기능 미선택 | {실제 덮개 상태} · 이번 유지에는 덮개 기능 미선택 | {observed lid state} · closed-lid use not selected for this session |
| 도우미 기능 자체의 적용값 | 덮개 유지 기능 적용됨 | Closed-lid support applied |
| 허용 켜짐·현재 요청 없음 | 현재 유지는 이 기능을 요청하지 않습니다. | The current work does not request this feature. |
| 허용 켜짐·작업 없음 | 이 기능을 요청하는 유지가 시작되면 적용합니다. | Applies when work that requests this feature starts. |
| 전체 중지·허용 켜짐 | 모두 중지됨 · 허용 설정 유지 | All keep-awake stopped · permission stays enabled |
| 보호 중지·허용 켜짐 | 보호로 중지됨 · 허용 설정 유지 | Stopped for protection · permission stays enabled |
| 자체 해제 미확인 | 유지 해제 확인 중 | Checking keep-awake release |
| 화면 유지 요청 적용 확인 | 화면 켜두기 요청 중 · 잠금은 macOS 설정을 따름 | Display keep-awake requested · locking follows macOS |
| 화면 끄기 선택 설명 | 내장 화면의 절전 처리를 요청합니다. | Requests sleep for the built-in display. |
| 밝기 0 선택 설명 | 밝기만 낮춥니다. 화면 꺼짐·잠금 해제·원격 연결 성공을 뜻하지 않습니다. | Lowers brightness only. It does not confirm display sleep, unlocking, or a successful remote connection. |
| 밝기 0 적용을 재조회로 확인 | 내장 화면 밝기 0 적용됨 | Built-in display brightness set to zero |
| 밝기 0 미지원·적용 실패 | 밝기 0을 적용하지 못했습니다. {확인된 이유} | Could not set brightness to zero. {observed reason} |
| 변경하지 않기 선택 설명 | Tether가 내장 화면 설정을 바꾸지 않습니다. | Tether leaves built-in display settings unchanged. |

메뉴와 설정은 같은 실제 덮개 관측·실행 상태 문구를 사용한다. 허용 체크는 기능 사용 허가, 도우미 적용값은 덮개 유지 지원, `덮개 열림/닫힘`은 실제 관측이다. 열린 상태의 도우미 적용값을 `덮개 닫고 사용 중`으로 표시하지 않으며, 관측이 없으면 열림·닫힘으로 추정하지 않는다. 해제 확인·보호·미선택·미적용 이유를 준비 완료 문구로 덮지 않는다.

### 자동·수동·중지·보호의 연계

| 실행 상태 | 메뉴 | 전원·덮개 설정 |
|---|---|---|
| 자동 유지 | 자동 유지 중과 실제 적용 결과. 허용 체크 자체를 실행 증거로 사용하지 않는다. | 저장된 자동 설정과 현재 자동 유지 상태, 화면·덮개 공통 상태를 표시한다. |
| 수동 유지 | 현재 요청의 기한·종료와 적용 결과. 자동만 일시 중지해도 수동의 기한은 바뀌지 않는다. | 수동은 원래 기한·보호 한도를 따름을 설명한다. 다음 수동 기본값 편집은 현재 적용 결과가 아니다. |
| 모두 중지 | 기존 표시 규칙에 따라 중지·재개 중심으로 보여주고 빠른 허용 조작은 숨긴다. | 저장된 체크가 켜져 있어도 `모두 중지됨`으로 표시한다. 중지 해제 전 자동·수동이 가능하다고 안내하지 않는다. |
| 보호 중지 | 중지 이유와 가능한 다음 조작을 우선하며 실행 중으로 표시하지 않는다. | `보호로 중지됨`과 허용 보존을 구분한다. 안전 상태·재개 설정 확인 전에 자동 시작을 약속하지 않는다. |
| 해제 확인 중 | 기존 실행 권한·표시 제한을 유지한다. | 중지 완료·미적용으로 단정하지 않고 자체 해제 확인 중임을 우선한다. |

메뉴의 빠른 조작 표시 여부는 기존 상태 규칙을 유지한다. 메뉴가 빠른 조작을 숨기는 상태에서도 설정의 저장값을 끄지 않는다. 메뉴와 설정은 화면 유지의 동일한 상태 설명을 공유한다. `보호`, `모두 중지`, `자동만 일시 중지`, `다음 시작 기본값`을 서로 대신하는 말로 사용하지 않는다.

화면 켜두기 해제·밝기 0·화면 절전·활동 유지 끄기를 `잠기지 않음`으로 설명하지 않는다. 화면 켜두기 요청의 활성은 실제 패널 켜짐을 측정한 결과가 아니다. 화면·잠금·실제 잠자기·원격 프레임/입력은 별개다.

## 전원·배터리 상세

| 항목 | 한국어 | English | 표시 조건 |
|---|---|---|---|
| 상세 펼침 | 전원·배터리 정보 | Power & battery | 내부 배터리가 확인된 Mac에서만 표시 |
| 충전기 보고값 | 충전기 전력(보고값) | Charger-reported power | 확인된 어댑터 보고값. 배터리 충전·방전 전력이나 Mac 전체 소비 전력이 아님 |
| 충전기 설명 | 충전기가 보고한 값입니다. 현재 배터리 충전·방전 전력과 다릅니다. | Reported by the charger. This differs from current battery charging or discharging power. | 현재 전달 중인 전력·확인된 최대 출력이라고 단정하지 않음 |
| 배터리 충전 전력 | 배터리 충전 전력 | Battery charging power | 유효한 양의 배터리 측 W |
| 배터리 방전 전력 | 배터리 방전 전력 | Battery discharging power | 유효한 음의 배터리 측 W. 표시 숫자는 크기, 문구는 방전 방향 |
| 흐름 없음 | 배터리 측 전력 | Net battery power | 유효한 실제 0 W와 미제공을 구분 |
| 충전 여부 | 충전 안 함 | Not charging | 확인된 충전 여부와 전력 흐름은 독립 |
| 충전 사이클 | 충전 사이클 | Charge cycles | 유효한 충전 사이클 값만 표시 |
| 재조회 | 다시 확인 중 | Checking again | 깨움·전원 정보 변경 후 재조회 전 이전 숫자를 숨김 |
| 오래된 관측값 | 오래된 정보 | Outdated information | 마지막 관측 시각과 현재 값이 아님을 표시 |
| 일부 정보 미제공 | 확인된 값만 표시합니다. | Only available readings are shown. | 미제공을 0이나 미연결로 만들지 않음 |

## 기록·다른 앱·업데이트

| 상태·항목 | 한국어 | English |
|---|---|---|
| 통계·기록 빈 상태 | 아직 기록이 없습니다. | No records yet. |
| 조회 중 | 기록을 불러오는 중 | Loading records |
| 기록 조회 실패 | 기록을 불러오지 못했습니다. 다시 확인해 주세요. | Could not load records. Check again. |
| 다른 앱의 실제 요청 관측 | 다른 앱의 잠자기 방지 요청 {개수}개 | {count} keep-awake requests from other apps |
| 다른 앱 상세 | 앱 또는 프로세스 / 컴퓨터 잠자기 방지 또는 화면 꺼짐 방지 / 확인 시각 / 앱 열기 | App or process / System or display keep-awake / Checked at / Open app |
| 다른 앱 요청 조회 실패 | 다른 앱의 요청을 확인하지 못했습니다. | Could not check other apps’ requests. |
| 업데이트 확인·결과 | 업데이트 확인 중 / 최신 버전입니다. / {버전} 업데이트 가능 | Checking for updates / Up to date / {version} available |
| 업데이트 확인 실패 | 업데이트를 확인하지 못했습니다. 다시 확인해 주세요. | Could not check for updates. Check again. |
| 설치 보류 | 업데이트 설치 대기 중 · {확인된 이유} | Update installation waiting · {observed reason} |

`최신 버전입니다`는 선택한 채널의 업데이트 조회가 성공했을 때만 쓴다. 다른 앱은 실제 요청을 관측한 경우에만 표시하고 조회 실패를 0개로 바꾸지 않는다. 앱 연결이 확인되지 않으면 `앱 열기`를 숨긴다.

## 승인된 확장 옵션 문구

기능명세 §9의 옵션 범위를 보존한다. native 연결·지원 여부는 기능명세의 구현 상태표를 따르며, 후보 문구를 실제 지원으로 표시하지 않는다. 고급 자동 규칙을 켠 상태를 전원 전용처럼 설명하지 않는다.

| 항목·내부 표현 | 한국어 | English |
|---|---|---|
| 고급 설정 노출 | 추가 옵션 보기 · 기능을 켜지 않고 설정 항목만 펼칩니다. | Show more options · Reveals settings without enabling features. |
| 현재 작업 값 | 이번 유지에만 적용 | Apply to this work only |
| 기본값 변경 | 다음 수동 유지 기본값 | Defaults for the next manual start |
| 규칙 값 | 이 자동 규칙에만 적용 | Apply to this automatic rule only |
| AND / OR | 모든 조건이 맞으면 / 하나라도 맞으면 | When all conditions match / When any condition matches |
| manual override | 수동으로 시작하면 자동만 일시 중지 | Pause automatic when starting manually |
| extend by N | {N}분 추가 · 현재 종료 시각에 더합니다. | Add {N} min · Adds to the current end time. |
| stop in N | 지금부터 {N}분 뒤 종료 · 기존 종료 시각을 바꿉니다. | End in {N} min · Replaces the current end time. |
| 작업 수명 | 앱이나 작업이 끝날 때까지 | Until the app or task ends |
| hook | 이 일이 생기면 실행 | Run when this happens |
| lease 상세 | 외부 도구가 요청한 유지 · {남은 기한} | Keep-awake requested by an external tool · {time left} |
| heuristic / verified | 활동으로 추정 / 연결 확인됨 | Inferred from activity / Connection confirmed |
| 미지원·권한·실패 | 이 Mac에서는 지원하지 않음 / 사용하려면 준비 필요 / 적용하지 못함 | Not supported on this Mac / Setup required / Could not apply |
| 부가 기능 활성 요약 | 추가 기능 {개수}개 사용 중 · {핵심 요약} | {count} extra features active · {summary} |
| 시간 초안 | 다른 시간으로 시작 / 유지 시간 / 종료 시각 / 이 시간으로 시작 / 취소 | Start with another duration / Duration / End time / Start this timer / Cancel |
| 다음 요청 편집 | 다음 수동 유지 기본값 / 다음 시작에 적용 | Defaults for the next manual start / Apply to next start |
| 추가 옵션 접근 | 담당 설정 페이지와 고급 편집창에서 제공 | Available from the owning settings page and advanced editor |
| 자동 범위 거절 | 기본 자동 시작은 전원 연결 중에만 동작합니다. 전원 범위를 바꾸려면 고급 자동화를 먼저 선택해야 합니다. | Basic automatic start works only on power. Select advanced automation before changing its power scope. |
| 사건 실행 | 이 일이 생기면 실행 / 설정한 Webhook 실행 허용 / 꺼진 상태로 추가 | Run when this happens / Allow configured webhook / Add disabled |
| 알림 | 수동 유지 종료 / 연동 작업 종료 / 만료 예고 / 예고 소리 | Manual keep-awake ended / Linked work ended / Expiry warning / Warning sound |

shell 명령·프로세스 식별값 같은 기술 용어는 해당 고급 편집 화면에서만 표시한다. 지원 미확인 기능에 활성화 스위치를 먼저 보여주지 않는다. 고급 자동 배터리 유지를 `전원 어댑터 연결`로 설명하지 않는다.
