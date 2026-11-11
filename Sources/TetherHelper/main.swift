import Foundation
import TetherCore

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
// Metadata queries must terminate before constructing a daemon or touching
// production settings. Older helpers do not recognize this entry point.
if arguments.contains("--version") {
    guard arguments.count == 2 else { exit(64) }
    print("TetherHelper \(TetherPaths.version) build=\(TetherPaths.build) coordinator=\(WorkSessionLease.coordinatorVersion)")
    exit(0)
}
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--writer-gate"), !arguments.contains("--validate-settings") {
    guard let support = option("--support"), let transaction = option("--transaction") else { exit(64) }
    exit(PowerWriterGate.perform(support: support, transaction: transaction))
}

if arguments.contains("--recovery-write"), !arguments.contains("--validate-settings") {
    exit(PowerRecoveryCommand.perform(.write, support: option("--support") ?? TetherPaths.supportDirectory,
        operation: option("--operation")))
}

// Private recovery entry point, before helper initialization. It never writes pmset.
// Only the root-owned journal may identify the expired writer it can terminate.
if arguments.contains("--power-writer-recovery"), !arguments.contains("--validate-settings") {
    let path = option("--journal-file") ?? TetherPaths.supportDirectory + "/power-writer.json"
    let boot = ContinuousTime.bootID
    if arguments.contains("--recovery-lock-stdin") {
        let lockPath = RecoveryLock.path(supportDirectory: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        guard let lock = try? RecoveryLock.adoptingInput(at: lockPath),
              PowerWriterJournal.clearResolved(path, boot: boot, expectedExecutable: "/usr/bin/pmset") else { exit(1) }
        withExtendedLifetime(lock) {}
        exit(0)
    }
    switch PowerWriterJournal.resolve(path, boot: boot, expectedExecutable: "/usr/bin/pmset", stopExpired: true) {
    case .resolved: exit(0)
    case .active: exit(75)
    case .unresolved: exit(1)
    }
}

if arguments.contains("--validate-settings") {
    if arguments.contains("--helper-install-target") {
        print("helper-install-target-v1 \(HelperInstallProbe.target.rawValue)"); exit(0)
    }
    if arguments.contains("--writer-gate-capability") {
        print(PowerWriterGate.capability); exit(0)
    }
    if arguments.contains("--recovery-write-capability") {
        print(PowerRecoveryCommand.capability); exit(0)
    }
    // Probe through an already-recognized, terminating mode. Older helpers return
    // only settings-valid; never send them a new flag that would start a daemon.
    if arguments.contains("--writer-recovery-capability") {
        print("power-writer-recovery-v1"); exit(0)
    }
    let path = option("--control") ?? TetherPaths.controlPath
    guard let value = JSONFile.read(Control.self, from: path), value.isSupported else {
        fputs("Settings cannot be migrated; original was not modified.\n", stderr); exit(1)
    }
    print("settings-valid"); exit(0)
}
if arguments.contains("--check-service") {
    let client = ServiceClient(path: option("--socket") ?? TetherPaths.productionSocket)
    guard let reply = try? client.perform(ServiceRequest(.snapshot)),
          reply.isCurrentHelperReady() else { exit(1) }
    print("helper-ready \(TetherPaths.version) protocol=2 schema=\(Control.currentSchema)"); exit(0)
}

let helper = Helper(dryRun: arguments.contains("--dry-run"),
                    controlPath: option("--control") ?? TetherPaths.controlPath,
                    statusPath: option("--status") ?? TetherPaths.statusPath,
                    fakePath: option("--fake"))
helper.trimLogIfNeeded()
helper.start()
RunLoop.main.run()
