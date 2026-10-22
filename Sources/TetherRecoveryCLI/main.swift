import Foundation
import TetherCore

// Independent of the long-lived helper; no daemon or arbitrary executable mode exists.
let arguments = CommandLine.arguments
func value(_ key: String) -> String? {
    guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
if arguments == [arguments[0], "--capability"] {
    print(PowerRecoveryCommand.capability); exit(0)
}
if arguments == [arguments[0], "--gate-capability"] {
    print(PowerWriterGate.capability); exit(0)
}
if arguments.count == 4, arguments[1] == "--prepare-logs", arguments[2] == "--support" {
    exit(PowerRecoveryCommand.prepareLogs(support: arguments[3]))
}
if arguments.count == 4, arguments[1] == "--prepare-upgrades", arguments[2] == "--support" {
    exit(PowerRecoveryCommand.prepareUpgradeStorage(support: arguments[3]))
}
if arguments.dropFirst().first == "--writer-gate" {
    guard let support = value("--support"), let transaction = value("--transaction") else { exit(64) }
    exit(PowerWriterGate.perform(support: support, transaction: transaction))
}
let mode: PowerRecoveryCommand.Mode
switch arguments.dropFirst().first {
case "--resolve": mode = .resolve
case "--clear": mode = .clear
case "--write": mode = .write
default: fputs("Invalid recovery operation\n", stderr); exit(64)
}
guard let support = value("--support") else { exit(64) }
exit(PowerRecoveryCommand.perform(mode, support: support, operation: value("--operation")))
