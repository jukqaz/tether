# 릴리스 절차

공개 저장소의 검토 가능한 커밋에서 설치 파일을 만들고, 같은 커밋에 태그를 연결합니다. 생성물·개인키·실기기 진단 로그는 소스 커밋에 포함하지 않습니다.


## 이번 후보의 게시 전 조건

최신 자동 검사 범위는 [검증 체크리스트](VALIDATION-CHECKLIST.ko.md), 실물 조작은 [인수 체크리스트](MANUAL-ACCEPTANCE.ko.md)를 따른다. 새로운 helper 실행 파일을 포함하므로 GUI만 교체하지 않는다. 관리자 승인·production 설치·실제 닫힌 분리 Sleep/Wake·macOS26 실행·인증된 원격 입력은 모의/격리 검사로 완료 처리하지 않는다. 현재 미커밋 변경은 이전 작업을 포함하므로 배포를 위해 일괄 커밋하거나 삭제하지 않는다.

사설 ad-hoc 배포 목적을 유지하며 Developer ID나 공증을 새로운 필수 요구로 만들지 않는다. 로컬 build와 서명 확인이 GitHub 게시·온라인 업데이트 완료를 뜻하지 않는다.

## 버전과 채널

표시 버전은 `연도.월.배포순번`이다. `2026.9.1`은 2026년 9월의 첫 배포이며 날짜의 일(day)을 뜻하지 않는다. 베타는 `2026.9.1 Beta 3`, 태그는 `v2026.9.1-beta.3`이다. 같은 정식 배포를 준비하는 동안 베타 순번을 올리고, 다음 정식 배포는 `2026.9.2`로 올린다. 월이 바뀌면 `2026.10.1`로 시작한다.

내부 빌드는 모든 채널에서 단조 증가한다. 2026-10-08 현재 소스·로컬 후보는 **2026.10.1 Beta 1 · 빌드 53**, 설치본은 **2026.9.1 Beta 8 · 빌드 52**이며 새 후보는 게시하거나 설치하지 않았다. 출시 월이 바뀌어도 빌드는 초기화하지 않는다. `Info.plist`의 `TetherReleaseChannel`은 `beta` 또는 `stable`, `TetherBetaIteration`은 베타에서 양수, 정식에서 0이다. 앱과 helper의 표시 버전·빌드는 반드시 같아야 한다. 현재 root schema는 3, IPC protocol은 2이며 일반 사용자 설정은 v4다. 아래 Beta 3 이름은 버전 형식 예시다. 실제 태그·ZIP 이름은 패키징 시 `Info.plist`에서 계산한다.

| 구분 | 태그 예시 | ZIP 예시 | 앱 기본 채널 |
|---|---|---|---|
| 베타 | `v2026.9.1-beta.3` | `Tether-2026.9.1-beta.3-arm64.zip` | 정식 + 베타 |
| 정식 | `v2026.9.1` | `Tether-2026.9.1-arm64.zip` | 정식 |

기존 사용자가 명시적으로 선택한 채널은 설치 파일 기본값보다 우선한다. 베타에서 정식으로 바꾸면 더 높은 빌드의 정식을 기다린다. 이미 게시한 버전·파일·빌드를 재사용하지 않는다. 낮은 표시 버전의 정식 hotfix를 높은 기능 버전 베타 뒤에 발행하는 병렬 배포는 현재 지원하지 않으며, 피드 생성기가 거부한다.

고정 피드는 `https://raw.githubusercontent.com/jukqaz/tether/updates/appcast.xml`이다. `updates` 브랜치의 서명된 피드 한 개에 최신 정식과 베타 항목을 유지한다. 베타 항목에만 Sparkle `beta` 채널을 표시한다. 같은 메타데이터에서 `downloads.json`과 다운로드 README도 만든다. 첫 정식 전에는 정식 링크를 만들지 않는다.

베타는 GitHub **Prerelease**, **Latest 아님**으로 게시한다. 새 피드를 게시하기 전에는 앱의 온라인 업데이트가 작동하지 않는다. 로컬 서명 검사 성공을 공개 배포 성공으로 간주하지 않는다.

## 로컬 검사

```sh
swift build
TETHER_RUN_LIVE_ASSERTION_TESTS=1 swift test
python3 scripts/test-update-feed.py
python3 scripts/test-release-preflight.py
python3 scripts/test-service.py
python3 scripts/test-conflicts.py
python3 scripts/test-upgrade.py
python3 scripts/test-uninstall.py
```

검사 목록의 기준은 [CI workflow](../.github/workflows/ci.yml)다. CI는 Swift 전체 회귀와 유한 비관리자 native 절전 요청, writer·복구·업데이트·설치/제거 통합을 검사한다. 공통 세션의 커널 peer·이관, 기기 capability 변경, 수동 유지와 기능 간 조정도 포함한다. 앱을 포장한 뒤 `TETHER_TEST_HELPER`와 `TETHER_TEST_CLI_EXECUTABLE`을 해당 포장 실행 파일로 지정해 Workbench IPC·실제 CLI 회귀를 실행한다. debug 실행 파일의 통과를 포장된 파일의 통과로 표시하지 않는다.

`TETHER_RUN_LIVE_ASSERTION_TESTS=1`은 실제 비관리자 IOKit 요청 검사를 활성화한다. GUI 로그인 세션이 없는 runner에서는 앱 측 native 검사가 건너뛰어질 수 있으므로 실행 요약의 건너뜀 수도 확인한다. CI 성공은 물리 덮개·패널·관리자 설치·회사 정책·macOS 26 실행 검증을 대신하지 않는다. workflow 변경만으로 원격 CI가 통과했다고 표시하지 않으며 실제 실행 결과로 확인한다.

## 패키징

Swift/앱 버전은 `TetherPaths.swift`와 `Info.plist`에서 함께 올립니다. Sparkle 2.10.0의 공식 도구와 앱 공개키에 대응하는 개인키를 사용합니다. 키는 저장소 밖의 안전한 장소에서 관리하고 값 자체를 명령줄·로그에 넣지 않습니다.

`scripts/build.sh`는 수정 중인 로컬 후보를 만들 수 있다. 서명 배포용 `scripts/release.sh`는 staged·수정·untracked 소스가 있으면 개인키 읽기나 생성물 생성 전에 중단한다. 최종 검증도 `--require-clean`을 적용한다. 배포를 위해 자동 커밋하거나 사용자의 변경을 지우지 않으며, 검토 후 커밋된 깨끗한 checkout에서 실행한다.

```sh
TETHER_PREVIOUS_APPCAST=/path/to/current-signed-appcast.xml \
TETHER_SIGNING_KEY_FILE=/private/path/ed25519.key \
SPARKLE_TOOLS_DIR=/path/to/Sparkle-2.10.0 \
sh scripts/release.sh --prerelease
```

최초 피드만 `TETHER_PREVIOUS_APPCAST` 대신 `TETHER_INITIALIZE_FEED=1`을 지정한다. 이후에는 현재 공개 피드를 받아 경로를 지정한다. 이전 피드의 서명 검증에 실패하면 중단한다. `dist/update-channel/`의 세 파일은 한 번에 게시할 메타데이터다.

`dist/`에 ZIP·SHA256·서명된 appcast·`release-manifest.json`을 생성합니다. **Sparkle 서명과 앱의 Developer ID 서명은 서로 다릅니다.** 현재 앱은 ad-hoc 서명으로 생성하며 공증하지 않습니다. `codesign --verify` 성공과 Gatekeeper 허용 여부를 구분해 manifest에 기록합니다.

`verify-release.py`는 압축을 새 임시 폴더에 풀고 앱 식별자·아키텍처·버전·소스 커밋, 중첩 코드 서명, ZIP/피드 Ed25519 서명, 파일 크기와 SHA256을 확인합니다. 포장된 도우미를 `--dry-run`으로 실행해 소켓 응답과 버전을 확인한 뒤 포장된 CLI를 연결합니다. 실제 도우미 설치나 시스템 전원 설정 변경은 하지 않습니다.

변경을 커밋한 뒤 최종 패키징을 하고, 같은 환경변수를 설정한 상태에서 아래 검사가 통과해야 게시할 수 있습니다.

```sh
# 현재 Beta 1 후보를 검토·커밋한 뒤의 예시. 버전이 바뀌면 생성된 파일명과 태그를 사용한다.
python3 scripts/verify-release.py dist/Tether-2026.10.1-beta.1-arm64.zip \
  --tag v2026.10.1-beta.1 --require-clean
```

실제 Sparkle 다운로드→교체 검증은 공식 `sparkle-cli`로 `scripts/test-sparkle-update.py`를 실행합니다. 이 검사는 폐기할 임시 Ed25519 키를 자체 생성하므로 실제 배포 개인키를 요구하지 않습니다. 현재 피드 보안 설정을 그대로 적용하고, 30일간 서명 실패가 이어져도 변조 피드를 거부하는지 확인합니다. 비교용 과거 정책 fixture에서만 만료 설정을 생략합니다. 앱처럼 보이는 합성 fixture만 교체합니다. 실제 관리자 도우미 갱신과 UI 재실행은 별도 대상 Mac 시험입니다.

## GitHub 게시와 확인

1. 소스·테스트·사용 문서를 검토하고 변경 커밋을 원격 브랜치에 올립니다. PR을 사용하면 CI 완료를 확인합니다.
2. 최종 커밋의 깨끗한 작업 폴더에서 최종 설치 파일을 만듭니다. manifest의 `source_commit`과 태그 대상을 일치시킵니다.
3. 해당 커밋에 새 태그를 만들고, GitHub 사전 릴리스 초안에 ZIP·체크섬·appcast·manifest와 한국어 설치 안내를 첨부합니다.
4. 릴리스 설명에 서명/공증 상태, 최소 OS·칩, 정확한 검사 범위와 실기기 미검증 항목을 적고 공개합니다.
5. 공개 URL에서 ZIP·피드·체크섬을 다시 받아 원본과 비교합니다. 공개 릴리스의 태그 대상, prerelease 속성, 기존 정식 latest 유지도 확인합니다.

6. 자산의 공개 다운로드 검사가 끝난 뒤에만 `dist/update-channel/`의 `appcast.xml`, `downloads.json`, `README.md`를 `updates` 브랜치에 함께 게시한다. 공개 raw 피드의 서명과 두 채널 후보, 다운로드 링크를 다시 검증한다. 서명된 이전 피드를 보존해 장애 시 복구하되 이미 설치한 앱을 다운그레이드하지 않는다.

게시 자동화에서 개인키가 들어 있는 디렉터리 전체를 첨부하지 않습니다. `dist/`의 정확한 파일을 지정합니다. 기존 버전의 설정을 포함하는 진단 보고서는 릴리스 파일로 올리지 않습니다.
