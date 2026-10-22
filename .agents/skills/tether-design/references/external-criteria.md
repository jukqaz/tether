# Tether 외부 디자인 참고 기준

확인일: 2026-10-14. 외부 원문에서 Tether에 필요한 판단 기준만 직접 요약했다.
이 문서는 참고 체크리스트이며, 원문 전체 설치·외부 스크립트 실행·훅 추가를 요구하지 않는다.

## 우선순위와 적용 범위

- 현재 시각 디자인 계약은 저장소 루트 `DESIGN.md`를 따른다. 기능 의미는 해당 소스·제품 문서와 대조하며 디자인 검토에서 바꾸지 않는다.
- macOS 26 이상 SwiftUI 메뉴바 앱, SF 시스템 글꼴, Graphite+Blue, 컴팩트한 메뉴·설정 밀도를 유지한다.
- 시스템 재질·컨트롤·창·포커스 구현은 기존 macOS Liquid Glass·SwiftUI Patterns 기준으로 판단한다.
- 화면 문제와 우선순위는 기존 Product Design Audit, 시안 비교는 Ideate, 실제 조작·캡처는 Computer Use에 맡긴다.
- 외부 체크리스트는 위 산출물에서 남은 문제를 좁히는 데 사용하고 별도 중복 감사 절차를 만들지 않는다.
- VoiceOver 전용 기능·낭독·검증은 이번 범위에 추가하지 않는다. 기존 컨트롤의 이름·의미·상태는 보존한다.
- 상태·시간·실패·보호·권한·확인 불가의 의미를 시각적 단순화를 위해 숨기거나 바꾸지 않는다.
- 모바일 44pt 터치 타깃, 웹 16px 본문·CSS·GSAP·반응형 breakpoint를 macOS 치수·구현 규칙으로 강제하지 않는다.

## 고정 출처

| 참고 원본 | 확인한 버전과 역할 |
|---|---|
| [Impeccable](https://github.com/pbakaus/impeccable/tree/2f98774f86bc05563876643db37e6c37c322850f) | `2f98774` · 2026-10-13 UTC · 글자·배치·정보 축약·마감 기준 |
| [UI UX Pro Max SKILL](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/blob/7246805992a42b7bba37d4cac83b01416f0c6c44/.claude/skills/ui-ux-pro-max/SKILL.md) | 저장소 `7246805` · 2026-10-12 UTC · 특정 UX 문제의 검색 참고 |
| [Anthropic frontend-design](https://github.com/anthropics/skills/blob/41bbe19d1a1a7eaab5e7bb9050a417e5c6cffc8f/skills/frontend-design/SKILL.md) | `41bbe19` · 2026-09-03 UTC · 절제·문구·행동 피드백 |
| [AvdLee SwiftUI Expert](https://github.com/AvdLee/SwiftUI-Agent-Skill/blob/204dba7c67256a8b707ee3fbc5759a824191974f/skills/swiftui-expert-skill/SKILL.md) | `204dba7` · 확인일 기준 고정 · SwiftUI 구현 리뷰 |

[Impeccable](https://github.com/pbakaus/impeccable/blob/2f98774f86bc05563876643db37e6c37c322850f/LICENSE)·[Anthropic frontend-design](https://github.com/anthropics/skills/blob/41bbe19d1a1a7eaab5e7bb9050a417e5c6cffc8f/skills/frontend-design/LICENSE.txt) 원문은 Apache-2.0, [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/blob/7246805992a42b7bba37d4cac83b01416f0c6c44/LICENSE)·[SwiftUI Expert](https://github.com/AvdLee/SwiftUI-Agent-Skill/blob/204dba7c67256a8b707ee3fbc5759a824191974f/LICENSE) 원문은 MIT다.
원문을 재배포하거나 수정 배포할 때는 해당 저장소의 라이선스·고지 조건을 별도로 유지한다.

## Impeccable: 글자와 배치

원본: [typeset](https://github.com/pbakaus/impeccable/blob/2f98774f86bc05563876643db37e6c37c322850f/.agents/skills/impeccable/reference/typeset.md), [layout](https://github.com/pbakaus/impeccable/blob/2f98774f86bc05563876643db37e6c37c322850f/.agents/skills/impeccable/reference/layout.md).

- [ ] 대표 상태, 이유, 남은 시간, 다음 조작이 크기·굵기·명도로 구분되는가.
- [ ] SF semantic style과 숫자의 정렬을 활용하고 장식용 폰트·강제 자간을 추가하지 않았는가.
- [ ] 한국어·영어·긴 이유에서 핵심 단어와 동작명이 잘리거나 부자연스럽게 분리되지 않는가.
- [ ] 같은 역할의 이름·값·설명·조작이 기준선과 열을 공유하는가.
- [ ] 그룹 간 여백으로 관계가 읽히며 반복 카드·구분선·외곽 padding이 밀도를 낭비하지 않는가.
- [ ] 좁은 설정 창과 메뉴 폭에서도 중요 이유·마감·버튼을 읽을 수 있는가.

## Impeccable: 정보 축약과 마감

원본: [distill](https://github.com/pbakaus/impeccable/blob/2f98774f86bc05563876643db37e6c37c322850f/.agents/skills/impeccable/reference/distill.md), [polish](https://github.com/pbakaus/impeccable/blob/2f98774f86bc05563876643db37e6c37c322850f/.agents/skills/impeccable/reference/polish.md).

- [ ] 반복 제목·설명·배지·내부 용어를 줄여 현재 상태와 핵심 조작이 먼저 보이는가.
- [ ] 보조 진단을 접더라도 보호 제한·실패 이유·재개 조건은 필요한 위치에 남는가.
- [ ] 자동·수동, 일반·덮개, 선택·실행·확인의 차이가 축약 후에도 분명한가.
- [ ] 아이콘 크기·정렬·모서리·간격·강조 강도가 같은 역할 안에서 일관적인가.
- [ ] Blue를 핵심 선택·조작에 집중하고 경고·실패의 의미 색상과 설명을 보존했는가.
- [ ] 정상·진행·실패·비활성 상태의 차이가 장식보다 실제 의미를 전달하는가.
- [ ] HTML/CSS 탐지기 결과를 SwiftUI 화면이나 macOS 재질·조작의 검증 결과로 계산하지 않았는가.

## UI UX Pro Max: 특정 문제의 검색 참고

- 대비·포커스·긴 문구·동작 피드백 등 관측한 문제 한 가지에 해당하는 UX 기준만 참고한다.
- 구현 정보가 필요하면 `swiftui` 항목으로 범위를 좁히고 iOS 중심 자료의 macOS 적합성을 확인한다.
- 이미 정한 Graphite+Blue·SF·밀도를 제품 유형별 팔레트·웹 폰트·랜딩페이지 추천으로 다시 생성하지 않는다.
- [ ] 검색 결과의 플랫폼·문제·해결 목적이 맞으며 일반 기본값을 검증된 제품 결론으로 쓰지 않았는가.
- [ ] 새 의존성·MVVM 전환·테스트 도구 도입을 외형 개선의 부수 요구로 추가하지 않았는가.

## Anthropic frontend-design: 절제와 행동 피드백

- [ ] 강조점을 대표 상태나 핵심 조작에 모으고 무관한 배경 효과·반복 카드·장식을 덜어냈는가.
- [ ] 열기·선택·시작·종료의 피드백이 사용자가 일으킨 변화와 연결되는가.
- [ ] 반복 등장·자동 재생 모션을 줄이고 기존 Reduce Motion 대응을 보존했는가.
- [ ] 버튼 이름, 결과 문구, 오류·빈 상태의 안내가 사용자에게 같은 의미로 이어지는가.
- 현재 원문은 사용자 브리프를 우선한다. 개성을 이유로 SF나 컴팩트한 네이티브 외관을 교체하지 않는다.

## SwiftUI Expert: 구현 리뷰로 연결

- 바뀐 화면에 필요한 상태 소유·view identity·텍스트 배치·Preview 기준만 확인한다.
- [ ] 반복 스타일과 modifier 순서가 의도한 배경·클릭 영역·레이아웃을 만드는가.
- [ ] 표시용 계산이나 애니메이션이 정책 timer·실제 유지 상태의 판단을 바꾸지 않는가.
- [ ] 긴 문구·정상·보호·실패·도우미 없음 등의 기존 Preview·Fixture 근거를 필요한 범위에서 재사용했는가.
- 구현 리뷰는 기존 macOS 스킬과 코드 검토에 연결하며 독립적인 전면 리팩터링을 시작하지 않는다.

## 결과 기록

- 채택한 기준과 화면에서 해결한 문제를 연결하고, 취향 제안과 실제 결함을 구분한다.
- 새 실행이 필요하면 기존 Audit·Computer Use 검증에서 한 번 확인하고 같은 근거를 재사용한다.
- 코드·Preview·Fixture·설치 앱·실제 전원 동작의 근거를 구분하고 미확인을 합격으로 올리지 않는다.
