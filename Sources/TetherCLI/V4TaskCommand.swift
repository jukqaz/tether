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
