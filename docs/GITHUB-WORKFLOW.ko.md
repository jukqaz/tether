# GitHub 프로젝트 관리

화면 절전·무잠금·원격 조작의 기술 검증은 `gh api`로 [#4 기존 진행 댓글](https://github.com/jukqaz/tether/issues/4#issuecomment-5929095896)에 추가했다. 재조회로 작성자·본문 일치와 Open을 확인했으며 프로젝트는 In Progress다. 저장소 관리자·프로젝트 수정 권한이 현재 CLI 인증에 있어 새 토큰이나 권한을 만들지 않았다. 공개 assertion만으로 무잠금 보장을 확정할 수 없고 실제 공급자 관측 adapter도 없어 F-04는 미완료다. 후보에 잠금 화면 설정 열기와 정확한 설정명·전역 적용 범위 안내를 추가했다. 변경 후 앱·Preview 빌드, arm64/macOS 15 대상, ad-hoc 서명과 실제 한국어 Preview의 버튼·상세·줄바꿈·정상 종료를 확인했다. Preview의 버튼은 비활성화되어 실제 설정 이동 실행과 원격 성공을 시험한 것은 아니다. 아래 Swift 708·설치 51개는 앞선 단계의 검증이며 이번 UI 변경 후 전체 재실행으로 표현하지 않는다. 설치본 49·관리자 helper·전원/잠금 설정·index는 보존했고 커밋·푸시·배포는 남는다. [기술 검증과 채택 결정](MAC-REMOTE-COOPERATION.ko.md).

최신 CLI/API 기록은 [#1 도우미 완료 판정](https://github.com/jukqaz/tether/issues/1#issuecomment-5931778780)과 [#6 직접 예약의 원마감 보존](https://github.com/jukqaz/tether/issues/6#issuecomment-5931779000)이다. API 재조회에서 본문·작성자 일치와 Open·In Progress를 확인했다. 같은 후보 빌드의 구형 계약·미래 상태 false-ready를 거절하고, 자동 갱신 시도를 실행 계약별로 기록한다. coordinator 4에서는 빈 현재 요청이 작업 유지 권한을 즉시 해제하면서 동일 직접 예약의 과거 소비 기록만 유지한다. 최종 Swift 708개(Core 554 + 앱·업데이트 154, 신규 13·native 7 포함), 포장 설치 51개, Workbench IPC 9·실제 CLI 3·작업 25·이관 8·기기 전환 2·수동 27·조정 14개가 통과했다. 한국어 실제 Preview의 수정 안내와 줄바꿈을 확인했으며 OS 효과·센서·원격 값은 모의다. 설치본 49·전원/잠금 설정·index를 보존하고 기존 문서·14개 검증 파일만 갱신했다. 테스트 임시 파일과 프로세스를 정리했으며 새 토큰·권한·별도 보고서·Desktop 저장은 없다. 실제 관리자·물리·잠금 방지·원격·macOS 15·전체 Sparkle UI·새 배포는 남는다. [최신 검증 범위](UPDATES-AND-MIGRATION.ko.md).

GitHub 작업은 이제 `gh` CLI와 API로 처리한다. 현재 `jukqaz`의 키체인 인증에는 `repo`·`project` 범위가 있고, 읽기 전용 API에서 저장소 `ADMIN`·프로젝트 `viewerCanUpdate=true`·이슈 편집 권한을 확인했다. 필요한 권한이 이미 있어 새 토큰이나 추가 권한을 만들지 않았다. 이슈·프로젝트 갱신 뒤 API로 다시 읽어 저장 내용을 확인하며, 인증 원문은 출력하거나 파일로 저장하지 않는다. 기존 컴퓨터유즈 기록은 당시 검증 근거로 보존한다.

CLI/API 후속 기록은 [#2 명령 경계](https://github.com/jukqaz/tether/issues/2#issuecomment-5930709509)와 [#6 전원 전환·공통 기록](https://github.com/jukqaz/tether/issues/6#issuecomment-5930709751)에 게시했다. API로 본문·작성자 일치와 Open·In Progress를 확인했다. Swift 695개(Core 546 + 앱·업데이트 149, 신규 35·native 7)는 실패·건너뜀 0이다. 포장 helper IPC 9개·실제 CLI 3개, 작업 24·이관 8·기기 전환 2·수동 27·조정 14·native 위임 12·전원 관측 17·원격 정책 27·화면 관측 17개가 통과했다. OS 효과·센서는 dry-run이며 한국어 실제 Preview의 기록 시작·시점 표시·중단·최근 동작과 정상 창 종료를 확인했다. 설치본 49·전원/잠금 설정·index는 보존했고 추가 토큰·권한·별도 보고서·Desktop 저장 없이 기존 기록을 갱신했다. 실제 물리·장시간·잠금/원격 화면과 입력·관리자·macOS 15·전체 업데이트·원격 CI·새 배포는 남는다. 아래 660개·654개·636개는 당시 근거다. [현재 검증 범위](COMMON-SESSION-PREVIEW-20261001.ko.md).

CLI/API 전환 후 [#1 종료 취소 복구 기록](https://github.com/jukqaz/tether/issues/1#issuecomment-5924371468)을 갱신하고 [#9 배포 경계·CI 기록](https://github.com/jukqaz/tether/issues/9#issuecomment-5929625153)을 게시했다. API로 본문·작성자 일치와 두 이슈의 `Open`·`In Progress`를 다시 확인했다. 해당 단계의 전체 Swift 660개(Core 532 + 앱·업데이트 128, native 7개 포함)는 실패·건너뜀 0이며 최종 포장 IPC 9개·실제 CLI 3개가 통과했다. 도우미 이관 8개·capability 2개·수동 27개·조정 14개와 배포 소스 preflight 5개도 통과했다. OS 쓰기는 dry-run이며 실제 Preview UI와 설치 41개는 앞선 단계의 근거다. release.sh의 clean git 확인·조회 실패 중단·최종 `--require-clean`과 CI 포장 경로 검사를 추가했다. 원격 CI 실행·새 배포·물리·관리자·원격 화면/입력·최소 OS·전체 Sparkle UI는 남는다. 설치본 49·전원 설정·index는 보존했고 새 토큰·추가 권한·별도 보고서·Desktop 저장 없이 기존 기록에 합쳤다. [현재 릴리스 절차](RELEASING.ko.md) · [종료 복구](UPDATE-TERMINATION-20261001.ko.md).

화면·원격 협력 후속 보완은 `gh api`로 [#4 진행 댓글](https://github.com/jukqaz/tether/issues/4#issuecomment-5929095896)을 게시하고 프로젝트 상태를 `In Progress`로 갱신했다. API 재조회에서 작성자·본문 일치와 이슈 `Open`·보드 `In Progress`를 확인했다. 최신 전체 Swift 654개(Core 532 + 앱·업데이트 122, 새 회귀 18·native 7개 포함), 최종 포장 helper IPC 9개·실제 포장 CLI 경로 3개·작업 10개·원격 정책 27개·화면 관측 17개가 통과했다. 설치 41개는 앞선 단계 근거다. 이번 실제 한국어 Preview의 원격 상세와 자동 유지가 꺼진 수동 세션 중지를 확인했으며 센서·OS 효과·원격 값은 모의다. 실제 원격 화면/입력·잠금·물리·관리자·최소 OS·전체 업데이트는 남아 #4를 닫지 않았다. 새 토큰·권한·배포 없이 기존 문서와 검증 기록을 갱신했다. [구현과 검증 범위](COMMON-SESSION-PREVIEW-20261001.ko.md) · [원격 계약](MAC-REMOTE-COOPERATION.ko.md).

공통 상태·예약·진단 후속 보완은 `gh api`로 [기존 #6 검증 댓글](https://github.com/jukqaz/tether/issues/6#issuecomment-5926535871)을 갱신했다. API 재조회에서 작성자와 본문이 일치하고 `Open`·`In Progress`가 유지됨을 확인했다. 앞선 상태·예약·진단 단계의 Swift 636개(Core 521 + 앱·업데이트 115, 추가 25개·native 7개 포함), 최종 포장 IPC 9개·CLI 경로 3개·작업 10개·원격 정책 25개·화면 관측 5개·설치 41개가 통과했다. 이전 611개 단계는 같은 댓글의 과거 근거로 보존한다. 센서·전원 효과·서비스 등록은 모의값이며 실제 물리·원격·관리자·최소 OS·전체 업데이트와 새 배포는 남는다. [최종 수정·검증 범위](COMMON-SESSION-PREVIEW-20261001.ko.md).

2026-10-01 세션·이관·제거 후속 보완은 컴퓨터유즈로 [기존 #6 검증 댓글](https://github.com/jukqaz/tether/issues/6#issuecomment-5926535871)을 갱신하고 재조회 뒤 611개·41개 결과와 `Open`·`In Progress`를 확인했다. 빈 원본의 불필요한 백업 생성 방지·기존 백업 검증, 로그인 항목 해제 오류 표시, 유지 해제 및 휴지통 이동 완료 뒤 설정 삭제를 보완했다. 최종 Swift 611개(Core 500 + 앱·업데이트 111, native 7개 포함)는 실패·건너뜀 0이다. 최종 포장 설치 시험은 기존 34개와 실제 이전 빌드 49 helper를 실행한 추가 7개를 포함해 총 41개가 통과했다. 이전 helper 종료·설정 백업·49→50 교체·실패 뒤 49 복구·임시 상태 재생 방지를 확인했고 서비스 등록과 전원 효과는 모의값이다. 앞선 화면/타이머 595개와 포장 IPC 8개·작업 10개·수동 27개·화면 5개, 한국어·영어 실제 GUI는 그 단계 근거로 보존하고 중복 합산하지 않는다. 설치본 빌드 49·전원 설정·이번 단계의 index는 유지했고 임시 시험 파일과 프로세스를 정리했다. 실제 관리자 설치/제거·물리·원격·최소 OS·전체 Sparkle UI·새 배포는 남는다. 별도 보고서·바탕화면 저장 없이 [기존 미리보기 문서](COMMON-SESSION-PREVIEW-20261001.ko.md), [업데이트 문서](UPDATES-AND-MIGRATION.ko.md), [설치 판정 문서](INSTALL-TARGET-20261001.ko.md)에 합쳤다.

2026-10-01 공통 세션의 실제 UI 미리보기 검증은 컴퓨터유즈로 [#6 검증 코멘트](https://github.com/jukqaz/tether/issues/6#issuecomment-5925813384)에 기록하고 페이지 재조회 뒤 저장과 `Open`·`In Progress`를 확인했다. 새 정책·도우미 IPC 연결과 첫 상태 준비 경쟁을 보완하고 전체 Swift 587개(native 7개·새 미리보기 7개 포함), 포장 도우미의 같은 7개, 실제 UI의 모의 전원·자동/수동 독립·배터리 한도·기기 전환·정상 종료를 확인했다. 설치본 빌드 49·전원 설정은 동일하며 실제 관리자·물리·원격·최소 OS·전체 업데이트는 남는다. [미리보기 구조·재현·증거](COMMON-SESSION-PREVIEW-20261001.ko.md).

2026-10-01 종료 보완은 컴퓨터유즈로 [#1 검증 코멘트](https://github.com/jukqaz/tether/issues/1#issuecomment-5924371468)에 기록하고 페이지 재조회 뒤 저장과 `Open`·`In Progress`를 확인했다. 종료 실패 뒤 정상 일반 작업 보존, 비동기 업데이트 경계 재검사, 실제 native·소켓·잠금 검증과 전체 Swift 555개(native 7개 포함)를 보고했다. 설치본 빌드 49·전원 설정은 동일하며 실제 관리자·물리·전체 업데이트가 남아 완료로 바꾸지 않았다. [종료 계약·재현·증거](UPDATE-TERMINATION-20261001.ko.md).

진행 상태는 [Tether 재설계 안정화 프로젝트](https://github.com/users/jukqaz/projects/8), [안정화 마일스톤](https://github.com/jukqaz/tether/milestone/1), [통합 이슈 #10](https://github.com/jukqaz/tether/issues/10)에서 관리한다. 프로젝트는 비공개이며 `jukqaz/tether` 저장소에 연결되어 있다. 기존 작업은 삭제하지 않고, 기능 구현·실행 검증·배포 상태를 구분한다.

보드의 `Todo`는 대기, `In Progress`는 구현·검증 진행, `Done`은 완료 기준을 확인한 상태다. 2026-10-01 이번 CLI API 재조회에서 이슈 10개 중 #1·#2·#4·#5·#6·#7·#8·#9·#10은 진행 중이며 #3만 대기 상태다. 대기 1·진행 9·완료 0이며, 실제 완료 조건을 확인한 뒤 상태를 갱신한다. 현재 계정의 보드 편집 컨트롤과 #6 작성·메타데이터 편집 권한을 확인했다. 새 권한이나 자격증명을 추가하지 않았다.

Tether 신규·갱신 항목의 자동 등록 규칙을 켜 두었다. 보드 상태 변경에 따른 이슈 자동 종료와 PR 병합에 따른 자동 완료 규칙은 껐다. PR이 병합되어도 실기기 검증 등 이슈의 남은 완료 조건을 확인한 뒤 종료한다.

| 이슈 | 범위 | 완료 기준 |
|---|---|---|
| [#1](https://github.com/jukqaz/tether/issues/1) | 이전 버전 업데이트·설정 이관·원복 | 설정과 꺼짐 선택 보존, 장애 복구, 실제 전체 업데이트 경로 검증 |
| [#2](https://github.com/jukqaz/tether/issues/2) | 전원 명령과 복구 거래 | 부모 사망·timeout·교체 경쟁, 미확인 작성자 차단, OS 효과와 최신 의도 확인 |
| [#3](https://github.com/jukqaz/tether/issues/3) | 실제 Sleep 뒤 닫힌 AC 연결 | OS Wake부터 적용까지 실제 인과 로그 또는 지원 불가 조건 확정 |
| [#4](https://github.com/jukqaz/tether/issues/4) | 화면·잠금·원격 | 계산 작업, 화면 절전, 잠금 정책, 원격 화면·입력을 각각 실측 |
| [#5](https://github.com/jukqaz/tether/issues/5) | macOS·타 앱 공존 | native 경로 및 외부 assertion 교차 시험, 전역 동일 값 경쟁의 한계 명시 |
| [#6](https://github.com/jukqaz/tether/issues/6) | 수동 세션·보호 지연 | 자동과 독립, AC 무제한 선택·배터리 최대 2시간, 실제 해제 지연 검증 |
| [#7](https://github.com/jukqaz/tether/issues/7) | GUI 사용자 전환 | 로그인 세션 신원 집행 및 빠른 사용자 전환 시험 |
| [#8](https://github.com/jukqaz/tether/issues/8) | macOS 15+·Apple Silicon | 기기별 실행기와 확인한 조합의 지원 행렬 |
| [#9](https://github.com/jukqaz/tether/issues/9) | 코드·문서·CI·릴리스 | 검토 가능한 PR, 서명·빌드 식별, 확인 범위 공개 후 배포 |

`priority:P0`는 정식 배포 전에 해결하거나 지원 제한을 확정할 핵심 과제다. `in-progress`는 구현·시험 진행 중, `validation`은 실행 근거가 필요한 상태다. 이슈 종료는 명령 성공이나 파일 존재만으로 하지 않는다. 다른 실행 경로가 남으면 체크 항목과 제한을 남긴다.

변경은 관련 이슈 번호를 PR에 연결한다. 모든 완료 조건을 충족하지 않았다면 `Closes #N`으로 자동 종료하지 않고 `Refs #N`으로 연결한다. 진단 원본, 인증 정보, 개인 경로와 테스트용 개인키는 공개 이슈·커밋에 넣지 않는다.

회귀는 `swift test --disable-sandbox`, writer/복구 lock 및 helper dry-run, 모의 OS의 설치·원복 시험으로 확인한다. 실제 화면·Sleep/Wake·원격·macOS 15 실행은 따로 기록한다. GitHub Actions에서 실행하기 전 로컬 통과를 원격 CI 통과로 표현하지 않는다.

작성자 GUI 단계는 컴퓨터유즈로 [#7 진행 기록](https://github.com/jukqaz/tether/issues/7#issuecomment-5918012435)과 [#2 집행 기록](https://github.com/jukqaz/tether/issues/2#issuecomment-5918073605)에 저장했다. 당시 Swift 436 통과·5 건너뜀과 비관리자 native 게이트 16개, 포장 helper 서비스/기능 11/19개를 실제 root·물리 시험과 구분했다. [GUI 작성자 단계](GUI-WRITER-GATE-20261001.ko.md).

이후 [#8 기기별 설치 진행 기록](https://github.com/jukqaz/tether/issues/8#issuecomment-5918816691)을 컴퓨터유즈로 게시하고 새로 불러온 이슈에서 저장을 확인했다. 당시 설치 판정 단계의 Swift 440 통과·5 건너뜀, debug·포장 실행 파일의 동일 설치 34개 및 포장 GUI/기능 11/19개를 실제 관리자·데스크톱·macOS 15 시험과 구분했다. 당시 보드는 대기 4·진행 6·완료 0이며 #1/#8을 닫지 않았다. [설치 구현 단계](INSTALL-TARGET-20261001.ko.md).

사용자 세션 입력·보호 보완은 컴퓨터유즈로 [#6 진행 기록](https://github.com/jukqaz/tether/issues/6#issuecomment-5919953898)에 게시하고 저장을 확인했다. 전체 Swift 467 통과·0 건너뜀·0 실패이며 native 6개와 관련 25개는 그 전체 실행에 포함된다. 포장한 빌드 50의 서명·격리 도우미 소켓·CLI 경로를 확인했으나 설치본은 빌드 49다. MacBook 공통 조정자 통합·물리 보호 지연·원격·macOS 15 실행·Sparkle 전체 업데이트가 남아 #6을 진행 중으로 유지한다. 커밋·푸시·원격 CI·배포는 아직 실행 전이다. [사용자 세션 보완 범위](USER-SESSION-INPUT-20261001.ko.md).

이어 컴퓨터유즈로 [#8 일반 실행 경로·90초 관측 기록](https://github.com/jukqaz/tether/issues/8#issuecomment-5920407172)을 저장하고 새로 불러온 이슈에서 확인했다. 기기 관측 실패의 일반 유지, 초기 AC 표시 오류와 소비 예산 보존을 보완해 Swift 472개가 통과했다. 제품 idle 실행기의 실제 90초 요청 만료는 별도 비관리자 프로세스 시험 1회이며 root 전체 복구와 실제 Sleep의 증거로 확대하지 않는다. #8은 계속 진행 중이다. [상세 범위](GENERAL-SESSION-ROUTING-20261001.ko.md).

프로젝트의 접근 관리 화면에서 소유자 권한을 확인했고 현재 인증의 `viewerCanUpdate=true`도 읽기 전용 조회로 검증했다. 프로젝트는 비공개·협업자 0명이며 추가 권한이나 자격증명을 만들지 않았다. 이어 컴퓨터유즈로 [#6 공통 세션 진행 기록](https://github.com/jukqaz/tether/issues/6#issuecomment-5921551363)을 저장하고 새로 불러온 페이지에서 확인했다. MacBook 공통 정책 연결·설정 v3 이관·덮개 오류 분리, Swift 492개와 격리 도우미/모의 OS 검증 범위를 기록했다. 실제 해제 상한·Sleep/Wake·원격·전체 업데이트 등 남은 조건 때문에 #6은 진행 중이며 완료로 변경하지 않았다. [공통 세션 구조와 증거](COMMON-SESSION-20261001.ko.md).

이후 컴퓨터유즈로 [#6 앱·CLI 공통 명령 기록](https://github.com/jukqaz/tether/issues/6#issuecomment-5922355713)을 게시하고 페이지 재조회 뒤 저장과 `In Progress` 상태를 확인했다. 전체 Swift 515개(Core 461 + 앱·업데이트 54), 같은 포장 CLI 회귀 2개, 격리 도우미의 동일 10개(debug·포장), 교차 14개와 모의 OS 설치 34개를 물리·관리자·최소 OS·전체 업데이트 검증과 구분했다. CLI는 실행 중인 같은 빌드의 앱에 위임하며 지연 중지·만료·중복 요청을 검사한다. 사용자 소켓 lock의 중복 서버 차단을 앱 전체 단일 작성자 보장으로 표현하지 않는다. 설치본 빌드 49와 전원 설정은 유지했고 커밋·푸시·원격 CI·배포는 남는다. [공통 명령 구조와 확인 범위](USER-COMMAND-COORDINATOR-20261001.ko.md).

이어 컴퓨터유즈로 [#7 앱 수명 조정 기록](https://github.com/jukqaz/tether/issues/7#issuecomment-5922733647)을 게시하고 새로 불러온 페이지에서 저장과 `Open`·`In Progress`를 확인했다. 앱 초기화 전 실행 잠금·명령 서버 예약, 종료 승인 이후의 잠금 유지, 소유권 상실 시 추가 쓰기 거절을 보완했다. 전체 Swift 523개와 포장 CLI의 같은 2개·격리 도우미 IPC 10개는 실제 GUI·관리자·물리·macOS 15·전체 업데이트의 완료 증거가 아니다. 설치본 빌드 49와 전원 설정을 유지하며 #7은 진행 중이다. [앱 수명 구조·확인 범위·남은 조건](APP-COORDINATOR-LIFETIME-20261001.ko.md).

접근 관리 화면에서 현재 계정이 프로젝트 설정·접근을 관리할 수 있음을 다시 확인했다. 프로젝트는 비공개·협업자 0명이며 새 권한을 만들지 않았다. 이어 컴퓨터유즈로 [#1 설정·세션 이관 기록](https://github.com/jukqaz/tether/issues/1#issuecomment-5923423575)을 게시하고 새로 불러온 페이지에서 저장과 `Open`·`In Progress`를 확인했다. 설정 v4·중지 보존·타이머 재시작 방지와 준비 후 재조회, 오래된 연결 거절을 보완했다. 전체 Swift 534개와 격리 도우미의 같은 IPC 18개(debug·포장), 포장 CLI의 같은 2개, 기존 교차 14개·모의 OS 설치 34개를 실제 관리자·물리·원격·최소 OS·전체 업데이트와 구분했다. 설치본 정보와 macOS 전원 설정은 검사 전후 동일하며 #1의 전체 완료 조건은 남아 있다. [이관 구조와 확인 범위](SESSION-HANDOFF-20261001.ko.md).

이어 컴퓨터유즈로 [#8 실행 중 기기 조회 보완 기록](https://github.com/jukqaz/tether/issues/8#issuecomment-5923811161)을 게시하고 새로 불러온 페이지에서 저장과 `Open`·`In Progress`를 확인했다. 같은 일반 조정자·원래 타이머·소비 예산을 유지하며 덮개 연결만 해제·재준비하고, 지연 응답·해제 미확인 상태에서 추가 grant를 막는다. 최종 전체 Swift 543개(추가 회귀 9개·native 6개 포함), 새 격리 도우미 IPC 동일 2개(debug·포장), 같은 포장 CLI 2개와 후보 포장을 확인했다. 기기 전환은 fixture이며 실제 센서 장애·관리자 root 효과·기기별 실행·Sleep/Wake·macOS 15·전체 업데이트는 남는다. 설치본 빌드 49와 전원 설정은 보존했다. [구조·검증 범위](CAPABILITY-REFRESH-20261001.ko.md).

배터리 전용 기능도 컴퓨터유즈로 [#8 후속 기록](https://github.com/jukqaz/tether/issues/8#issuecomment-5924096458)에 게시하고 새로 불러온 페이지에서 저장과 `Open`·`In Progress`를 확인했다. 프로젝트 접근 관리 화면에서도 비공개·협업자 0명과 관리 컨트롤을 확인해 새 권한을 추가하지 않았다. 최종 전체 Swift 547개(추가 회귀 4개·native 6개 포함), 포장 CLI의 같은 3개, 후보 포장과 데스크톱/조회 불가 화면 렌더를 확인했다. 설치본 빌드 49·전원 설정은 유지하며 실제 기기/원격·root 효과·최소 OS·전체 업데이트는 남는다. [기기별 기능과 증거](BATTERY-CAPABILITY-20261001.ko.md).
