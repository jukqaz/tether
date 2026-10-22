import Darwin
import Foundation
import TetherCore

// Only an unprivileged temporary fixture is accepted. This target is never shipped.
let arguments = CommandLine.arguments
if geteuid() != 0, arguments.count == 3, arguments[1] == "--app-coordinator-lock" {
    let folder = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard ["/tmp", "/private/tmp"].contains(folder.deletingLastPathComponent().path),
          folder.lastPathComponent.hasPrefix("tether-app-lease-") else { exit(64) }
    do {
        let lease = try AppCoordinatorLease.acquire(at: folder.appendingPathComponent("instance.lock").path)
        print("ready"); fflush(stdout)
        // EOF bounds the fixture if the test driver exits; it never touches power.
        _ = try FileHandle.standardInput.read(upToCount: 1)
        withExtendedLifetime(lease) {}
        exit(0)
    } catch { fputs("coordinator rejected\n", stderr); exit(1) }
}
// Exercise the shipped idle driver with its real health TTL. The parent may SIGSTOP
// this one unprivileged child; powerd, rather than a child timer, must expire its request.
if geteuid() != 0, arguments.count == 2, arguments[1] == "--idle-lease-hang" {
    guard GUISessionProbe.caller().map({ SystemProbe.consoleUserID == $0.uid }) == true else { exit(78) }
    MainActor.assumeIsolated {
        let driver = IdleAssertionDriver()
        let now = ContinuousTime.now
        driver.apply(expiry: now + IdleSessionPolicy.healthTTL, now: now)
        guard driver.state == .holding, let id = driver.assertionID, let expiry = driver.expiry else { exit(1) }
        let report: [String: Any] = ["pid": getpid(), "assertionID": id, "started": now,
            "expiry": expiry, "healthTTL": IdleSessionPolicy.healthTTL]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        // The finite OS request does not depend on this cleanup. This is an additional
        // child lifetime limit if its parent exits without stopping it.
        Thread.sleep(forTimeInterval: IdleSessionPolicy.healthTTL + 30)
        driver.end()
    }
    exit(0)
}
if geteuid() != 0, arguments.count == 2, arguments[1] == "--idle-snapshot" {
    let requests = SystemProbe.sleepBlockerSnapshot()
    let report: [String: Any] = ["queried": requests != nil, "continuous": ContinuousTime.now,
        "requests": requests?.map { ["pid": $0.pid, "kind": $0.kind.rawValue] as [String: Any] } ?? []]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(requests == nil ? 1 : 0)
}
if geteuid() != 0, arguments.count == 2, arguments[1] == "--gui-preflight" {
    exit(GUISessionProbe.caller().map { SystemProbe.consoleUserID == $0.uid } == true ? 0 : 78)
}
if geteuid() != 0, arguments.count == 6, arguments[1] == "--writer-gate",
   arguments[2] == "--support", arguments[4] == "--transaction" {
    exit(PowerWriterGate.perform(support: arguments[3], transaction: arguments[5]))
}
// Native fixed-operation OS stand-in for recovery CLI tests. A copied Mach-O keeps
// proc_pidpath identity meaningful; an interpreted script would identify its interpreter.
if geteuid() != 0, [["-a", "disablesleep", "0"], ["-a", "disablesleep", "1"], ["sleepnow"], ["displaysleepnow"]].contains(Array(arguments.dropFirst())),
   let root = ProcessInfo.processInfo.environment["TETHER_RECOVERY_TEST_ROOT"] {
    let folder = URL(fileURLWithPath: root).standardizedFileURL
    guard ["/tmp", "/private/tmp"].contains(folder.deletingLastPathComponent().path),
          folder.lastPathComponent.hasPrefix("tether-recovery-test-"),
          URL(fileURLWithPath: arguments[0]).standardizedFileURL.path == folder.appendingPathComponent("mock/pmset").path else { exit(64) }
    var entry = stat()
    guard lstat(folder.path, &entry) == 0, entry.st_uid == geteuid(),
          entry.st_mode & S_IFMT == S_IFDIR, entry.st_mode & 0o777 == 0o700 else { exit(64) }
    let behavior = ProcessInfo.processInfo.environment["TETHER_RECOVERY_FIXTURE"] ?? "success"
    if behavior == "delay" { signal(SIGTERM, SIG_IGN) }
    try? Data(String(getpid()).utf8).write(to: folder.appendingPathComponent("child.pid"))
    if behavior == "delay" { usleep(4_000_000) }
    if behavior == "fail" { exit(1) }
    guard ["success", "delay"].contains(behavior) else { exit(64) }
    try? Data(arguments.dropFirst().joined(separator: " ").utf8).write(to: folder.appendingPathComponent("effect"))
    exit(0)
}
guard geteuid() != 0, arguments.count == 3,
      ["registered", "before-registration", "resolve", "cleanup", "gated-success", "gated-before-registration",
       "gated-after-registration", "gated-invalid", "gated-recovery-deferred", "gated-gui-acquire", "gated-gui-display", "gated-gui-sleep",
       "gated-gui-release", "gated-gui-controller-exit"].contains(arguments[1]) else { fputs("Invalid fixture invocation\n", stderr); exit(64) }
let folder = URL(fileURLWithPath: arguments[2]).standardizedFileURL
guard ["/private/tmp", "/tmp"].contains(folder.deletingLastPathComponent().path),
      folder.lastPathComponent.hasPrefix(arguments[1].hasPrefix("gated-") ? "tether-recovery-test-" : "tether-writer-test-") else {
    fputs("Fixture must be inside /private/tmp: \(folder.path)\n", stderr); exit(64)
}
var info = stat()
guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { fputs("Unsafe fixture directory\n", stderr); exit(64) }
let journal = folder.appendingPathComponent("power-writer.json").path
let lockPath = RecoveryLock.path(supportDirectory: folder.path)
let identityPath = folder.appendingPathComponent("child-identity.json")
if arguments[1] == "cleanup" {
    // Test cleanup must not signal an unrelated process after PID reuse. This
    // private record belongs to the fixture, not the production writer journal.
    guard let data = try? Data(contentsOf: identityPath),
          let saved = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
          saved.pid > 1, saved.pid != getpid(), saved.uid == geteuid(), saved.started > 0,
          ProcessIdentity.sameExecutable(saved.executable, "/usr/bin/perl") else { exit(1) }
    if ProcessIdentity.exited(pid: saved.pid) { exit(0) }
    guard let current = ProcessIdentity.capture(pid: saved.pid) else { exit(1) }
    if !saved.matchesLifetime(current) { exit(0) }
    guard ProcessIdentity.sameExecutable(current.executable, "/usr/bin/perl") else { exit(1) }
    guard kill(saved.pid, SIGKILL) == 0 || errno == ESRCH else { exit(1) }
    let deadline = ContinuousTime.now + 2
    while ContinuousTime.now < deadline {
        if ProcessIdentity.exited(pid: saved.pid) { exit(0) }
        if let next = ProcessIdentity.capture(pid: saved.pid), !saved.matchesLifetime(next) { exit(0) }
        usleep(10_000)
    }
    exit(1)
}
if arguments[1] == "resolve" {
    guard PowerWriterJournal.resolve(journal, boot: ContinuousTime.bootID,
        expectedExecutable: "/usr/bin/perl", stopExpired: true) == .resolved,
        let lock = try? RecoveryLock.acquire(at: lockPath, timeout: 0),
        PowerWriterJournal.clearResolved(journal, boot: ContinuousTime.bootID, expectedExecutable: "/usr/bin/perl") else { exit(1) }
    withExtendedLifetime(lock) {}
    exit(0)
}
guard let lock = try? RecoveryLock.acquire(at: lockPath, timeout: 0) else { exit(1) }
if arguments[1].hasPrefix("gated-gui-") {
    guard let login = GUISessionProbe.caller(), SystemProbe.consoleUserID == login.uid,
          let coordinator = ProcessIdentity.capture(pid: getpid()) else { exit(64) }
    // The short-lived controller stand-in is this fixture's own child. It exits on
    // its own within three seconds even if the coordinator/test driver crashes.
    var controller: Process?
    var identity = coordinator
    if arguments[1] == "gated-gui-controller-exit" {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["3"]
        do { try child.run() } catch { exit(1) }
        guard let captured = ProcessIdentity.capture(pid: child.processIdentifier) else { exit(1) }
        controller = child; identity = captured
    }
    let owner = GUISessionOwner(bootID: ContinuousTime.bootID, process: identity, login: login)
    var state = HelperState()
    state.guiOwner = owner; state.controllerUID = login.uid
    state.appUID = login.uid; state.appPID = identity.pid; state.appStarted = identity.started
    guard JSONFile.write(state, to: folder.appendingPathComponent("helper-state.json").path,
                         permissions: 0o600, durable: true) else { exit(1) }
    let operation: [String]
    switch arguments[1] {
    case "gated-gui-display": operation = ["displaysleepnow"]
    case "gated-gui-sleep": operation = ["sleepnow"]
    case "gated-gui-release": operation = ["-a", "disablesleep", "0"]
    default: operation = ["-a", "disablesleep", "1"]
    }
    let result = PowerWriterJournal.run(folder.appendingPathComponent("mock/pmset").path,
        arguments: operation, lock: lock, journalPath: journal, boot: ContinuousTime.bootID, timeout: 5,
        intentEpoch: "gui-gate-test", intentRevision: 9, gateExecutable: coordinator.executable,
        guiOwner: owner, afterRegistration: { pid in
            try? Data(String(pid).utf8).write(to: folder.appendingPathComponent("gui-ready"))
            let deadline = ContinuousTime.now + 4
            while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("gui-permit").path),
                  ContinuousTime.now < deadline { usleep(5_000) }
            if let controller {
                if controller.isRunning { controller.terminate() }
                let until = ContinuousTime.now + 0.5
                while controller.isRunning, ContinuousTime.now < until { usleep(5_000) }
            }
        })
    var report: [String: String] = ["result": result == nil ? "missing" : "observed"]
    if let result {
        report["status"] = String(result.status)
        report["terminationConfirmed"] = String(result.terminationConfirmed)
        report["timedOut"] = String(result.timedOut)
    }
    guard JSONFile.write(report, to: folder.appendingPathComponent("gui-result.json").path,
                         permissions: 0o600, durable: true) else { exit(1) }
    exit(0)
}
if arguments[1].hasPrefix("gated-") {
    guard let gate = ProcessIdentity.capture(pid: getpid())?.executable else { exit(1) }
    let recovery = arguments[1] == "gated-recovery-deferred"
    let result = PowerWriterJournal.run(folder.appendingPathComponent("mock/pmset").path,
        arguments: recovery ? ["sleepnow"] : ["-a", "disablesleep", arguments[1] == "gated-invalid" ? "9" : "1"],
        lock: lock, journalPath: journal, boot: ContinuousTime.bootID, timeout: 2,
        intentEpoch: recovery ? "recovery" : "gated-test", intentRevision: 8, gateExecutable: gate,
        beforeRegistration: { pid in
            if arguments[1] == "gated-before-registration" {
                try? Data(String(pid).utf8).write(to: folder.appendingPathComponent("before-registration.pid"))
                while true { usleep(10_000) }
            }
        }, afterRegistration: { pid in
            if recovery {
                // A foreign request appears after parent verification and durable
                // registration. Only the last native gate can prevent execution.
                let observation: [String: Any] = ["power": "battery", "lidClosed": true,
                    "sleepDisabled": false, "fullWake": true, "foreignKeepAwake": true]
                guard let bytes = try? JSONSerialization.data(withJSONObject: observation) else { exit(1) }
                try? bytes.write(to: folder.appendingPathComponent("recovery-sleep.json"))
                try? Data(String(pid).utf8).write(to: folder.appendingPathComponent("registered.pid"))
            }
            if arguments[1] == "gated-after-registration" {
                try? Data(String(pid).utf8).write(to: folder.appendingPathComponent("after-registration.pid"))
                while true { usleep(10_000) }
            }
        })
    if recovery { exit(result?.status == PowerWriterGUIAuthority.denied && result?.terminationConfirmed == true ? 0 : 1) }
    if arguments[1] == "gated-invalid" { exit(result?.terminationConfirmed == true && result?.status != 0 ? 0 : 1) }
    exit(result?.status == 0 && result?.terminationConfirmed == true ? 0 : 1)
}
let writer = "$SIG{TERM}='IGNORE'; open(my $p,'>', $ARGV[0]) or die $!; print $p $$; close $p; select undef,undef,undef,4; open(my $f,'>', $ARGV[1]) or die $!; print $f 'late';"
let result = PowerWriterJournal.run("/usr/bin/perl", arguments: ["-e", writer,
    folder.appendingPathComponent("child.pid").path, folder.appendingPathComponent("late-write").path],
    lock: lock, journalPath: journal, boot: ContinuousTime.bootID, timeout: 1.5,
    intentEpoch: "test-epoch", intentRevision: 7,
    beforeRegistration: { pid in
        guard let identity = ProcessIdentity.capture(pid: pid),
              ProcessIdentity.sameExecutable(identity.executable, "/usr/bin/perl"),
              let data = try? JSONEncoder().encode(identity) else { exit(1) }
        do {
            try data.write(to: identityPath, options: .atomic)
            guard chmod(identityPath.path, 0o600) == 0 else { exit(1) }
        } catch { exit(1) }
        if arguments[1] == "before-registration" {
            try? Data(String(pid).utf8).write(to: folder.appendingPathComponent("before-registration.pid"))
            while true { usleep(10_000) } // Parent SIGKILL is the tested interruption.
        }
    })
exit(result?.status == 124 && result?.terminationConfirmed == true ? 0 : 1)
