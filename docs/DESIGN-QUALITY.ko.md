# UI 품질 측정

2026-11-11 · 개발용 검사 · macOS native Scene

이 검사는 잘림·겹침·조작 접근성처럼 재현 가능한 결함을 찾는다. 앱 사용자에게 점수나 진단 파일을 자동 생성하지 않는다. 색 취향·전체 미적 완성도·사용성·Apple 또는 WCAG 인증을 점수로 판정하지 않는다.

## 기준과 배점

Apple HIG의 적응형 배치, 읽을 수 있는 글자, native 조작 원칙과 W3C의 대비 계산 방법을 참고한다. 아래 배점과 메뉴 폭·조작 높이는 **Tether의 제품 기준**이다. 표준 기관의 점수가 아니다.

| 영역 | 배점 | 검사 |
|---|---:|---|
| 배치 | 40 | 유효한 AX 프레임 10, 보이는 조작의 창 안 배치 15, 실제 메뉴 폭 5, 글자 프레임의 수평 잘림 10 |
| 조작 | 20 | 서로 독립된 조작의 겹침 10, 주요 시작·중지 버튼 높이 10 |
| 읽기 | 20 | 핵심 문구의 실제 표시 10, 측정 가능한 렌더링 대비 10 |
| 입력 | 20 | 같은 GUI 후보의 native 키보드 경로 10, 마우스 경로 10 |

- 현행 메뉴 폭은 380±1pt로 [스타일 가이드](../DESIGN.md)의 380pt와 `WorkSessionMetrics.panelWidth`를 따른다. 프레임 반올림 오차는 0.5pt까지 허용한다. 평가기의 `MENU_WIDTH_POINTS`·`MENU_WIDTH_TOLERANCE_POINTS`와 보고서의 `menuWidthPoints`·`menuWidthTolerancePoints`가 이 제품 기준을 기록한다.
- 이전 300·304·360pt 기준의 저장된 점수·캡처는 당시 기준의 기록이다. 현행 380pt 기준으로 이전 결과를 다시 합격 처리하거나 현재 설치본의 근거로 사용하지 않는다. 새 기준의 UI 확인에는 같은 후보에서 새로 수집한 캡처가 필요하다.
- 주요 시작·중지 버튼은 24pt를 제품 목표로 삼는다. `--recommend-minimum-target`은 나머지 식별 가능한 앱 조작의 22pt 권고도 검사한다. macOS 기본 창 버튼을 이 높이로 강제하지 않는다.
- macOS 좌표 `pt`, PNG 픽셀, 웹 `CSS px`는 다르다. WCAG의 24×24 CSS px 기준을 native 컨트롤의 24pt 의무 규칙으로 사용하지 않는다.
- 작은 일반 글자의 전경·배경을 확정할 수 있을 때 대비 4.5:1을 목표로 한다. 비활성 조작·장식·큰 글자는 별도로 해석한다. Glass와 vibrancy의 실제 색을 확정하지 못하면 미측정이다.

## 점수를 읽는 방법

각 규칙은 `pass`, `fail`, `unknown`으로 기록한다. 화면별 동일 가중치를 사용하고, 미측정은 통과에 더하지 않는다. 비교에는 같은 화면·언어·크기·상태 목록을 사용한다.

- **확인 점수 / 100**: 통과 근거가 있는 배점의 합. 전체 디자인의 미적 점수로 해석하지 않는다.
- **측정 범위 %**: 통과 또는 실패를 판단할 수 있었던 배점. 나머지는 미측정이다.
- **측정 항목 통과율 %**: 확인 점수를 측정한 배점으로 나눈 부분 비율. 이것만 100%라고 해서 전체 UI가 100점인 것은 아니다.
- **중대 결함 수**: 확인된 조작 잘림·독립 조작 겹침·핵심 문구 잘림. 하나라도 있으면 `failed`이다.

원본 캡처가 없거나 잘못된 경우 `incomplete`이다. `measured`와 종료 코드 0은 검사가 수행됐다는 뜻이며 모든 항목의 합격을 뜻하지 않는다. 높이 권고 같은 실패도 상세 결과를 읽어야 한다.

## 근거와 한계

XCUITest가 실제 Settings·MenuBarExtra를 실행하고 각 PNG에 같은 화면의 AX 프레임 JSON을 붙인다. 창 프레임을 캡처 전후 대조하고 변경된 경우 배치 판정을 보류한다. 캡처와 AX 조회는 완전히 원자적인 API가 아니므로 애니메이션 중 내용까지 동일하다고 보장하지 않는다.

AX 수집은 앱 조작을 요소 유형별 query와 index로 읽고, 표준 `_XCUI:` 창 장식은 측정 범위에서 제외한다. 조회 중 사라졌거나 유형이 달라져 읽지 못한 요소는 `unmeasuredElements`에 남긴다. `measurementCompleteness`가 `partial`이거나 이 목록이 비어 있지 않으면 배치·조작의 통과 판정을 보류하고 `unknown`으로 처리한다. 읽지 못한 프레임을 정상 배치나 겹침 없음의 근거로 세지 않는다.

버튼 내부 글자·아이콘, native Picker의 부모·자식, 중복 AX 노드는 독립 조작 겹침으로 세지 않는다. 부모 관계를 모르면 실제 충돌로 단정하지 않는다. 세로 스크롤 밖 내용은 정상적인 offscreen일 수 있으므로 곧바로 잘림 실패로 세지 않는다. 고정 조작과 스크롤 후 접근 가능성은 native 동작 시험으로 보완한다.

macOS AX의 `hittable=true`만으로 스크롤 내용이 실제로 보인다고 확정하지 않는다. 수집기는 같은 ScrollView의 typed descendant에서 유형·식별자·문구·값·프레임이 단일 일치한 경우에만 `observedScrollViewport`를 기록한다. 평가기는 해당 viewport가 같은 캡처의 실제 ScrollView 프레임과 정확히 일치하고 조작과 완전히 불교차할 때만 offscreen으로 구분한다. 부분 교차·관계 미확인은 창 경계 검사를 그대로 적용하며, 위조·불일치 관계는 유효한 근거로 인정하지 않는다.

AX에 전체 문장이 있어도 실제 화면에서는 말줄임표로 잘릴 수 있다. 핵심 문구는 새 PNG의 Apple Vision OCR과 시각 검사를 대조한다. 고신뢰도 OCR에서 문구가 발견되면 해당 문구의 표시만 확인한다. OCR 미발견만으로 실패시키지 않는다. 실패는 실제 잘림을 시각적으로 확인한 기록과 같은 PNG 해시가 있어야 한다. 전체 문자열의 잘림, 일반적인 글자 크기·폰트·행간의 품질을 자동 인증한 것은 아니다.

대비는 source 색 토큰이나 PNG 차이만으로 통과시키지 않는다. 실제 배경과 글자의 확정 가능한 색, PNG 해시, 측정 방법이 필요하다. 안티앨리어싱된 글자 가장자리나 Glass 배경의 임의 픽셀을 전체 대비 인증으로 사용하지 않는다. 현재 자동 측정이 없으면 그대로 `unknown`으로 둔다.

현재 평가기는 원본 픽셀을 검증하는 대비 측정 backend가 없어 대비를 항상 `unknown`으로 처리한다. RGB·method·hash를 JSON에 적는 것만으로 대비 배점을 얻을 수 없다. 4.5:1은 후속 실측의 목표이고 이번 점수의 통과 근거가 아니다.

입력 배점은 캡처와 `result.json`의 source GUI 해시가 같고 실제 native suite가 실행·전체 통과·skip/expected failure/런타임 경고 0일 때 인정한다. 전체 native suite의 실행 경로 근거이며 각 화면의 모든 조작에 대한 접근성 점수가 아니다. 화면마다 모든 컨트롤이 클릭됐다는 의미도 아니다. 실제 설치 화면, 물리 덮개·Sleep, 원격 앱, 최소 지원 OS는 별도 검증이다.

## 실행

```sh
python3 -B scripts/test-design-quality.py
python3 scripts/test-ui-native.py --output .build/verification/design-quality/native
```

`NativeUI.xcresult`에서 PNG와 `*-layout.json`을 내보낸다. 원본 첨부는 보존하고, 같은 실행의 `result.json` 해시·PNG 해시·명시적 핵심 문구 검사를 넣은 파생 JSON을 별도 `audit-input`에 만든다. fixture landing·실패 진단 중복 이미지는 제품 화면 목록에 포함하지 않는다.

```sh
swiftc scripts/recognize-ui-text.swift -o .build/verification/recognize-ui-text
xcrun xcresulttool export attachments \
  --path .build/verification/design-quality/native/NativeUI.xcresult \
  --output-path .build/verification/design-quality/png --filter '*.png'
xcrun xcresulttool export attachments \
  --path .build/verification/design-quality/native/NativeUI.xcresult \
  --output-path .build/verification/design-quality/geometry --filter '*.json'
python3 scripts/prepare-design-audit.py \
  --native-result .build/verification/design-quality/native/result.json \
  --attachments .build/verification/design-quality/png \
  --layout-attachments .build/verification/design-quality/geometry \
  --output .build/verification/design-quality/audit-input \
  --ocr .build/verification/recognize-ui-text
python3 scripts/design-quality.py .build/verification/design-quality/audit-input \
  --native-result .build/verification/design-quality/native/result.json \
  --report .build/verification/design-quality/design-score.json
```

OCR은 기존 PNG만 읽는다. 새 desktop 캡처·네트워크 전송·이미지 수정·사용자 앱 상태 변경을 하지 않는다. 보고서 이름에 `layout`을 넣지 않아 다음 평가 입력으로 혼입되지 않게 한다. 개발자가 명시적으로 실행할 때만 `.build/verification`에 기록한다.

PNG·JSON은 각각 새 디렉토리에 export한다. `xcresulttool`이 같은 디렉토리의 기존 manifest를 덮어쓰지 않기 때문이다. 파생 자료 준비는 fixture·test·step·device·configuration 출처가 일치할 때만 결합하고, 두 manifest 해시를 보존한다. 자료 준비 자체는 UI 통과나 시각 승인으로 표시하지 않는다.

`prepare-design-audit.py`는 `textChecks`를 자동으로 만들지 않는다. 제품의 명시적 핵심 문구 목록을 파생 JSON에 적용한 뒤 평가한다. 전체 문자열이나 이미 보이는 단어를 임의로 골라 모든 글자가 통과했다고 주장하지 않는다. 같은 전후 비교에는 고정한 문구 목록을 사용한다. UI가 원래 생략을 의도하고 실제 상세 경로를 제공하면 그 경로를 별도로 확인한다.

## 변경 완료 조건

1. 새 캡처에서 결함과 발생 상태를 확인한다.
2. 영향받는 컴포넌트만 수정하고 같은 목록으로 전후 비교한다.
3. 확인된 중대 결함 0, native 시험 실행·전체 통과, 평가기 회귀 통과를 확인한다.
4. 미측정·미실시 범위와 후보/설치 구분을 결과에 기록한다.

## 공식 참고

- [Apple Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple 잘림·큰 글자 평가](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria)
- [Apple Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [W3C 글자 대비](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
- [W3C 조작 영역·예외](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
