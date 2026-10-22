import Foundation
import TetherCore

struct CLITaskReceipt: Encodable {
    let schemaVersion = 1
    var jobID: UUID
    var eventID: UUID
    var sequence: UInt64
    var scope: V4Scope
    var scopeToken: String?
    var result: V4WorkEventResult?
    var receipt: UserSessionReply
}

/// No background process is spawned. The caller sends heartbeats only while the actual task is active.
func performTaskCommand(_ words: [String]) -> Never {
    guard let input = V4CLITaskInput(words: words, newJobID: UUID(), newEventID: UUID()) else {
        fail(L("Usage: tether task begin|working|waiting|idle|heartbeat|finish|fail|cancel [--job-id UUID] [--event-id UUID] [--seq N] [--scope TOKEN] [--producer ID] [--ttl 1...300] [--deadline CONTINUOUS_SECONDS] [--json]. Follow-up events require job-id, seq and scope.",
               "사용법: tether task begin|working|waiting|idle|heartbeat|finish|fail|cancel [--job-id UUID] [--event-id UUID] [--seq N] [--scope TOKEN] [--producer ID] [--ttl 1...300] [--deadline CONTINUOUS_SECONDS] [--json]. 후속 사건에는 job-id·seq·scope가 필요합니다."), code: 2)
    }
    do {
        let client = try userSessionClient(); let snapshot = try client.snapshot()
        guard let scope = snapshot.workScope else { throw UserSessionFailure("coordinatorUnavailable") }
        guard input.scope == nil || input.scope == scope else { throw UserSessionFailure("superseded") }
        let event = input.event(scope: scope)
        let reply = try client.perform(.status, workEvent: event)
        guard reply.workEventResult != nil else { throw UserSessionFailure("requestVerificationFailed") }
        let report = CLITaskReceipt(jobID: event.jobID, eventID: event.eventID, sequence: event.sequence,
            scope: event.scope, scopeToken: V4CLITaskInput.encodeScope(event.scope), result: reply.workEventResult, receipt: reply)
        // Every response is structured so scripts can retain identity rather than scrape localized text.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        exit(reply.workEventResult?.disposition == .accepted || reply.workEventResult?.disposition == .alreadyProcessed ? 0 : 1)
    } catch { fail(error.localizedDescription) }
}

func performManualPIDCommand(_ words: [String]) -> Never {
    let filtered = words.filter { $0 != "--json" }
    guard let pidIndex = filtered.firstIndex(of: "--pid"), pidIndex + 2 == filtered.count,
          let pid = Int32(filtered[pidIndex + 1]), pid > 1,
          let command = TetherCommand.parse(Array(filtered[..<pidIndex])),
          case .manual = command else {
        fail(L("Usage: tether manual [time|unlimited] --pid PID [--json]", "사용법: tether manual [시간|unlimited] --pid PID [--json]"), code: 2)
    }
    guard let process = ProcessIdentity.capture(pid: pid), process.uid == geteuid(), !ProcessIdentity.exited(pid: pid) else {
        fail(L("The selected process identity could not be verified. No manual session was requested.", "선택한 프로세스 신원을 확인하지 못해 수동 유지를 요청하지 않았습니다."))
    }
    let identity = V4ProcessIdentity(pid: pid, startIdentity: process.started, executableIdentity: process.executable)
    do {
        let reply = try userSessionClient().perform(command, manualPID: identity)
        printUserSession(reply, command: command, json: words.contains("--json"))
        exit(0)
    } catch { fail(error.localizedDescription) }
}
