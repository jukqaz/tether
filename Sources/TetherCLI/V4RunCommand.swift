import Darwin
import Foundation
import TetherCore

/// Only this wrapper's own, still-suspended child may be killed on failed admission.
/// After SIGCONT, Tether never terminates the workload on time/power/protection changes.
func performRunCommand(_ words: [String]) -> Never {
    guard let input = V4CLIRunInput(words: words) else {
        fail(L("Usage: tether run --minutes N|--unlimited -- executable [arguments...]. The command starts only after the manual request is confirmed.",
               "사용법: tether run --minutes N|--unlimited -- 실행파일 [인수...]. 수동 유지 확인 후 명령을 시작합니다."), code: 2)
    }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { fail(L("Could not prepare the command.", "명령을 준비하지 못했습니다.")) }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED)) == 0 else {
        fail(L("Suspended command creation is unavailable; the command was not started.", "명령을 정지 상태로 준비할 수 없어 시작하지 않았습니다."))
    }
    var argv = ([input.executable] + input.arguments).map { strdup($0) } + [nil]
    var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in argv { free(pointer) }
        for pointer in environment { free(pointer) }
    }
    var child: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { args in
        environment.withUnsafeMutableBufferPointer { env in
            posix_spawnp(&child, input.executable, nil, &attributes, args.baseAddress!, env.baseAddress!)
        }
    }
    guard spawned == 0, child > 1 else {
        // Never print argv or subprocess output in an error or decision record.
        fail(L("The command could not be prepared (error \(spawned)).", "명령을 준비하지 못했습니다 (오류 \(spawned))."))
    }
    var resumed = false
    func removeUnstartedChild() {
        guard !resumed else { return }
        // waitpid ownership plus the unreaped child lifetime prevents PID-reuse cleanup of an unrelated process.
        _ = kill(child, SIGKILL)
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
    }
    do {
        guard let process = ProcessIdentity.capture(pid: child), process.uid == geteuid(), !ProcessIdentity.exited(pid: child) else {
            throw UserSessionFailure("invalidRequest")
        }
        let identity = V4ProcessIdentity(pid: child, startIdentity: process.started, executableIdentity: process.executable)
        let client = try userSessionClient()
        let accepted = try client.perform(.manual(minutes: input.minutes), manualPID: identity)
        guard let requestID = accepted.status?.manualRequestID,
              accepted.status?.manualActive == true, accepted.status?.holding == true,
              accepted.status?.manualApprovalPending != true else { throw UserSessionFailure("requestVerificationFailed") }
        let current = try client.snapshot()
        guard current.status?.manualRequestID == requestID, current.status?.manualActive == true,
              current.status?.holding == true, current.status?.manualApprovalPending != true,
              current.workScope != nil, current.workScope == accepted.workScope,
              let observed = ProcessIdentity.capture(pid: child), observed.matchesLifetime(process),
              observed.executable == process.executable else { throw UserSessionFailure("superseded") }
        guard kill(child, SIGCONT) == 0 else { throw UserSessionFailure("requestVerificationFailed") }
        resumed = true
    } catch {
        removeUnstartedChild()
        fail(error.localizedDescription)
    }
    var waitStatus: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(child, &waitStatus, 0) } while waited == -1 && errno == EINTR
    guard waited == child, let code = V4CLIRunInput.exitCode(waitStatus: waitStatus) else {
        fail(L("The command exit status could not be confirmed. Tether observes the process separately.", "명령 종료 상태를 확인하지 못했습니다. Tether는 프로세스 상태를 별도로 관측합니다."))
    }
    note(L("Command process exited with status \(code). This is not proof of task success or Mac Sleep.",
           "명령 프로세스 종료 상태: \(code). 작업 성공이나 Mac 잠자기 완료의 증거는 아닙니다."))
    // The app's verified PID-exit event owns natural completion; do not race it with endManual.
    exit(code)
}
