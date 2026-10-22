import XCTest
@testable import TetherCore

final class UpdatePolicyTests: XCTestCase {
    @MainActor func testLegacyBuildOnlyAttemptDoesNotBlockCurrentContractAndOffIsPreserved() throws {
        let domain = "io.github.jukqaz.tether.upgrade-attempt-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(String(TetherPaths.build), forKey: "helperUpgradeAttemptedBuild")
        defaults.set(false, forKey: "enabled")
        XCTAssertTrue(HelperUpgradeAttempt.claim(in: defaults))
        XCTAssertEqual(defaults.string(forKey: HelperUpgradeAttempt.preferenceKey), HelperUpgradeAttempt.currentContractID)
        XCTAssertFalse(HelperUpgradeAttempt.claim(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "enabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "helperUpgradeAttemptedBuild"), String(TetherPaths.build))
    }

    @MainActor func testCoordinatorContractChangeAllowsOneNewAutomaticAttempt() throws {
        let domain = "io.github.jukqaz.tether.upgrade-attempt-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let oldContract = "\(TetherPaths.version):\(TetherPaths.build):protocol2:schema\(Control.currentSchema):coordinator3"
        defaults.set(oldContract, forKey: HelperUpgradeAttempt.preferenceKey)
        XCTAssertNotEqual(oldContract, HelperUpgradeAttempt.currentContractID)
        XCTAssertTrue(HelperUpgradeAttempt.claim(in: defaults))
        XCTAssertFalse(HelperUpgradeAttempt.claim(in: defaults))
    }

    func testCandidateChannelMatchesTheCurrentChoice() {
        for channel in UpdateChannel.allCases {
            XCTAssertTrue(channel.accepts(candidateChannel: nil))
            XCTAssertEqual(channel.accepts(candidateChannel: "beta"), channel == .beta)
            XCTAssertFalse(channel.accepts(candidateChannel: "nightly"))
        }
    }
    func testExplicitChannelSurvivesChangingInstalledChannel() {
        XCTAssertEqual(UpdateChannel.resolve(saved: "stable", bundled: "beta"), .stable)
        XCTAssertEqual(UpdateChannel.resolve(saved: "beta", bundled: "stable"), .beta)
        XCTAssertEqual(UpdateChannel.resolve(saved: nil, bundled: "beta"), .beta)
        XCTAssertEqual(UpdateChannel.resolve(saved: "invalid", bundled: nil), .stable)
        XCTAssertEqual(UpdateChannel.stable.allowedChannels, [])
        XCTAssertEqual(UpdateChannel.beta.allowedChannels, ["beta"])
    }
    @MainActor func testClosedAndUnknownLidDeferWithoutAutomaticResume() {
        for initial: Bool? in [true, nil] {
            var lid = initial, calls = 0
            let gate = UpdateRelaunchGate(lidClosed: { lid })
            XCTAssertTrue(gate.canTerminateForUpdate) // Ordinary quit remains possible.
            XCTAssertTrue(gate.postpone { calls += 1 })
            XCTAssertTrue(gate.waiting)
            XCTAssertFalse(gate.canTerminateForUpdate)
            XCTAssertFalse(gate.resume()); XCTAssertEqual(calls, 0)
            lid = false
            XCTAssertEqual(calls, 0) // No automatic install on opening.
            XCTAssertTrue(gate.resume()); XCTAssertEqual(calls, 1)
            XCTAssertFalse(gate.resume()); XCTAssertEqual(calls, 1)
        }
    }
    @MainActor func testLidClosingAfterApprovalPreventsTermination() {
        var lid: Bool? = false
        let gate = UpdateRelaunchGate(lidClosed: { lid })
        XCTAssertFalse(gate.postpone { XCTFail("Sparkle must retain the immediate path") })
        XCTAssertTrue(gate.canTerminateForUpdate)
        lid = true; XCTAssertFalse(gate.canTerminateForUpdate)
        lid = nil; XCTAssertFalse(gate.canTerminateForUpdate)
        gate.finish(); XCTAssertTrue(gate.canTerminateForUpdate)
    }
    @MainActor func testAbortedCycleCannotRunStaleContinuation() {
        var lid: Bool? = true
        let gate = UpdateRelaunchGate(lidClosed: { lid })
        XCTAssertTrue(gate.postpone { XCTFail("aborted continuation") })
        gate.finish(); lid = false
        XCTAssertFalse(gate.waiting); XCTAssertFalse(gate.resume())
        XCTAssertTrue(gate.canTerminateForUpdate)
    }
    @MainActor func testResumeClearsCallbackBeforeReentrancy() {
        var lid: Bool? = true, calls = 0
        let gate = UpdateRelaunchGate(lidClosed: { lid })
        XCTAssertTrue(gate.postpone { calls += 1; XCTAssertFalse(gate.resume()) })
        lid = false
        XCTAssertTrue(gate.resume()); XCTAssertEqual(calls, 1)
    }
}
