# 공통 전원 복구 잠금 구현·검증

2026-09-30 수정본에서 도우미, 감시 장치, 설치·제거가 같은 BSD flock을 사용하도록 연결했다. 자동 전원 트리거와 선택적인 수동 세션 정책은 유지했다. 이번 수정본은 설치하거나 배포하지 않았다.

## 구현

- 잠금 파일은 `/Library/Application Support/.tether-power-recovery.lock`에 둔다. 소유권 journal의 atomic rename 및 Tether 지원 폴더 삭제와 독립된 inode이며, 설치 실패 원복과 제거 후에도 비어 있는 0600 파일을 보존한다. 실행 중인 프로세스나 전원 설정을 유지하기 위한 파일이 아니다.
- native 도우미는 보호된 부모 디렉터리, 소유자, 일반 파일, 단일 hard link, 0600 권한 및 잠금 획득 후 inode를 확인한다. 잠금 대기는 250ms로 제한하고 경합 시 전원 쓰기를 보류한다. journal을 잠금 안에서 다시 읽어 이미 소비된 소유권 캐시로 다른 요청을 해제하지 않는다.
- shell 경로는 같은 잠금을 FD 9로 보유한다. watchdog은 경합 시 다음 점검으로 미룬다. 설치·제거의 잠금 대기는 2초이며, 획득하지 못하면 복구 기록과 기존 파일을 보존한다. 서비스 종료·시작·준비 대기 중에는 설치 프로그램이 잠금을 잡고 있지 않는다.
- watchdog·설치·제거는 `pmset` 종료 코드만으로 복구 기록을 소비하지 않는다. IOPMrootDomain에서 `SleepDisabled = No`를 재확인한 뒤에만 기록을 소비하거나 제거를 진행한다.
- shell 잠금 함수는 별도 resource로 포함·설치한다. 도우미 바이너리가 실행되지 않아도 감시 장치가 사용할 수 있다. 고아 도우미 정리 및 과거 에너지 모드 복구 경로도 공통 잠금을 사용한다.

macOS 15.0의 [Apple 배포 소스](https://github.com/apple-oss-distributions/distribution-macOS/tree/macos-150/shell_cmds)는 shell_cmds-319.0.1을 지정하고, 해당 [lockf 소스](https://github.com/apple-oss-distributions/shell_cmds/blob/shell_cmds-319.0.1/lockf/lockf.c)는 상속된 FD의 BSD flock 방식을 지원한다. 실제 실행 검증은 현재 개발 Mac에서 했으며 macOS 15 실행 시험을 대신하지 않는다.

## 최종 검증

| 검사 | 결과 | 검증 범위 |
|---|---:|---|
| 전체 Swift 단위·프로세스 테스트 | 393 통과, 선택 실행 5 건너뜀, 실패 0 | 398개 실행 목록. 실제 전원 assertion 선택 시험은 이번 실행에서 건너뜀 |
| 새 잠금·watchdog 집중 검사 | 25 통과 | 위 전체 검사에 포함. native/shell 배타성, journal 교체, 잠금 수명, 위험한 경로, 경합, 복구 효과 없음 |
| 실제 도우미 잠금 통합 | 6 통과 | 다른 프로세스가 보유한 flock과 충돌 시 획득·원복 보류, 해제 후 재시도, 소비된 journal 재조회 |
| 실제 설치 스크립트 모의 OS 검사 | 11 통과 | 성공, 복구, 원복, 잠금 경합, 위험한 잠금, OS 효과 없는 성공 명령, 기존 설정 및 inode 보존 |
| 실제 제거 스크립트 모의 OS 검사 | 10 통과 | 소유권·boot 구분, 원복 실패·미확인 시 보존, 경합, inode 보존 |
| 도우미 기능 회귀 | 201 통과 | 서비스 70, 수동 옵션 27, 전원 보정 16, 조정 14, 충돌 49, 원격 화면 25. 모든 OS 쓰기는 dry-run |
| 배포 앱 빌드·패키지 | 통과 | macOS 최소 15.0, shell resource 포함 및 원본 일치, ad-hoc 서명 검증. 설치·GitHub 게시 없음 |

증거는 `work/tether-recovery-lock-20260930/`의 최종 로그와 `validation.json`에 저장했다. 초기 집중 검사에서 macOS `/dev/fd`의 synthetic device 번호 때문에 잠금을 잘못 거절한 문제가 발견되어 inode 검사로 수정했다. 추가 회귀의 첫 실행은 SwiftPM 바이너리 경로를 잘못 지정해 시작하지 못했으며, 실제 `--show-bin-path` 결과로 수정한 뒤 최종 실행이 통과했다. 실패한 중간 로그도 별도로 보존했다.

## 남은 제한

D-04 전체 완료는 아니다. native 잠금은 unrelated exec 자손에게 상속하지 않는다. 도우미 자체가 죽은 뒤 OS 작성자가 살아 있는 경우를 다루는 `writerUnresolved` 지속 기록, PID 신원, 거래 세대와 최신 의도의 연동은 남아 있다. 이전 바이너리가 새 잠금을 사용한다고 가정해서도 안 된다.

이 검사로 실제 덮개·전원 전환, 장시간 동작, 잠금 화면 정책, 실제 원격 세션, macOS 15 및 모든 Apple Silicon 모델을 통과로 표시하지 않는다. 과거 물리 시험 결과와 이번 모의 검사는 별개다. 아직 설치본 교체나 전체 재설계 완료를 선언할 단계는 아니다.
