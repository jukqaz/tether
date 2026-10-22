import XCTest
@testable import TetherCore

final class V4CLIInputTests: XCTestCase {
    func parse(_ words: [String]) -> V4CLITaskInput? {
        .init(words: words, newJobID: UUID(), newEventID: UUID())
    }
    func testBeginCreatesIdentityButFollowupRequiresOriginalScope() {
        XCTAssertNotNil(parse(["task", "begin"]))
        XCTAssertNil(parse(["task", "heartbeat"]))
        let token = V4CLITaskInput.encodeScope(V4Fixture.scope)!
        let job = UUID()
        let parsed = parse(["task", "heartbeat", "--job-id", job.uuidString, "--seq", "1", "--scope", token])
        XCTAssertEqual(parsed?.scope, V4Fixture.scope)
        XCTAssertEqual(parsed?.jobID, job)
        var newer = V4Fixture.scope; newer.powerGeneration += 1
        XCTAssertEqual(parsed?.event(scope: newer).scope, V4Fixture.scope)
    }
    func testDuplicateUnknownAndInvalidOptionsFailClosed() {
        for options in [["--ttl", "nan"], ["--ttl", "301"], ["--ttl", "0"], ["--seq", "-1"],
                        ["--ttl", "30", "--ttl", "40"], ["--scope", "invalid"], ["--unexpected", "x"], ["--producer"]] {
            XCTAssertNil(parse(["task", "begin"] + options))
        }
    }
    func testStateAliasesDoNotAcceptArbitraryCommandsOrClaimExitSuccess() {
        let scope = V4CLITaskInput.encodeScope(V4Fixture.scope)!
        for action in ["working", "waiting", "idle", "heartbeat", "finish", "fail", "cancel"] {
            let value = parse(["task", action, "--job-id", UUID().uuidString, "--seq", "42", "--scope", scope])
            XCTAssertNotNil(value); XCTAssertNil(value?.event(scope: V4Fixture.scope).exitCode)
            XCTAssertEqual(value?.event(scope: V4Fixture.scope).evidence, .direct)
        }
        XCTAssertNil(parse(["task", "run", "rm", "-rf"]))
    }
}
