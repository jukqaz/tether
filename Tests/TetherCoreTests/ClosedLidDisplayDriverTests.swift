import Foundation
import XCTest
@testable import TetherCore

/// These fakes do not instantiate a native brightness adapter, call pmset, or
/// read real displays. Every assertion below concerns policy and ownership only.
final class ClosedLidDisplayDriverTests: XCTestCase {
    @MainActor func testOffAndUnchangedNeverAcquireBrightness() {
        for mode in [ClosedLidDisplayMode.off, .unchanged] {
            let backend = BrightnessFake(); let journal = BrightnessJournalFake()
            let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
            driver.update(mode: mode, eligible: true)
            XCTAssertTrue(backend.writes.isEmpty)
            XCTAssertEqual(backend.readCount, 0)
            XCTAssertNil(journal.record)
            XCTAssertEqual(driver.state, mode == .unchanged ? .unchanged : .inactive)
        }
    }

    @MainActor func testConfirmedZeroAndReleaseRestoresOnlyOriginal() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        // Startup recovery with no debt must not prevent a later release.
        driver.recover()
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .brightnessZero)
        XCTAssertEqual(backend.writes, [0])
        XCTAssertEqual(journal.record?.original, 0.7)
        XCTAssertEqual(journal.record?.phase, .applied)
        XCTAssertTrue(driver.hasRecoveryDebt)
        driver.update(mode: .zeroBrightness, eligible: false)
        XCTAssertEqual(backend.writes, [0, 0.7])
        XCTAssertFalse(driver.hasRecoveryDebt)
        XCTAssertNil(journal.record)
        driver.update(mode: .zeroBrightness, eligible: false)
        XCTAssertEqual(backend.writes.count, 2, "An unchanged observation must not restore again")
    }

    @MainActor func testUserChangeIsPreservedDuringHoldAndAtEnd() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        backend.value = 0.4
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .userChangePreserved)
        XCTAssertNil(journal.record)
        for _ in 0..<4 { driver.update(mode: .zeroBrightness, eligible: true) }
        driver.update(mode: .zeroBrightness, eligible: false)
        XCTAssertEqual(backend.writes, [0])
        XCTAssertEqual(backend.value, 0.4)
    }

    @MainActor func testReadFailureAndUnknownOrExternalTopologyDoNotWrite() {
        let cases: [ClosedLidDisplayIssue] = [.brightnessReadUnavailable, .topologyUnavailable,
                                             .externalDisplayPresent, .privateAPIUnavailable]
        for issue in cases {
            let backend = BrightnessFake(); let journal = BrightnessJournalFake()
            if issue == .brightnessReadUnavailable { backend.readable = false }
            else { backend.support = .init(availability: .unavailable, issue: issue) }
            let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
            driver.update(mode: .zeroBrightness, eligible: true)
            XCTAssertTrue(backend.writes.isEmpty)
            XCTAssertNil(journal.record)
            XCTAssertEqual(driver.state, .unavailable(issue))
        }
    }

    @MainActor func testConflictingDisplayRequirementDefersWithoutFallback() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true, destructiveChangeAllowed: false)
        XCTAssertEqual(driver.state, .deferred)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    @MainActor func testJournalMustCommitBeforeAnyNativeWrite() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        journal.saveFails = true
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .unavailable(.journalUnavailable))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    @MainActor func testFailedWriteMayHaveChangedValueAndKeepsOriginalForRecovery() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.writeSucceeds = false
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .recoveryPending(.brightnessWriteFailed))
        XCTAssertEqual(journal.record?.phase, .prepared)
        backend.writeSucceeds = true
        driver.update(mode: .zeroBrightness, eligible: false)
        XCTAssertEqual(backend.value, 0.7)
        XCTAssertNil(journal.record)
    }

    @MainActor func testPostWriteReadFailureNeverClaimsZeroAndRetainsDebt() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.afterWrite = { backend.readable = false }
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .recoveryPending(.brightnessReadUnavailable))
        XCTAssertTrue(driver.hasRecoveryDebt)
        backend.afterWrite = nil
        backend.readable = true
        driver.retryRecovery()
        XCTAssertEqual(backend.value, 0.7)
        XCTAssertFalse(driver.hasRecoveryDebt)
    }

    @MainActor func testStartupRecoveryDoesNotConsumeLaterFailedAcquisitionRecovery() {
        for failure in ["readback", "appliedJournal"] {
            let backend = BrightnessFake(); let journal = BrightnessJournalFake()
            let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
            driver.recover()
            if failure == "readback" {
                backend.afterWrite = { backend.readable = false }
            } else {
                journal.afterSave = { journal.saveFails = true }
            }
            driver.update(mode: .zeroBrightness, eligible: true)
            XCTAssertEqual(backend.value, 0)
            XCTAssertTrue(driver.hasRecoveryDebt)
            XCTAssertNotEqual(driver.state, .brightnessZero)
            backend.afterWrite = nil; backend.readable = true
            journal.afterSave = nil; journal.saveFails = false
            driver.recover()
            XCTAssertEqual(backend.value, 0.7, failure)
            XCTAssertEqual(backend.writes, [0, 0.7], failure)
            XCTAssertFalse(driver.hasRecoveryDebt, failure)
            XCTAssertNil(journal.record, failure)
        }
    }

    @MainActor func testAcquisitionRechecksUserBrightnessAfterDurableJournalWrite() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        journal.afterSave = { backend.value = 0.5 }
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.recover()
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .userChangePreserved)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.value, 0.5)
        XCTAssertFalse(driver.hasRecoveryDebt)
        XCTAssertNil(journal.record)
        driver.update(mode: .zeroBrightness, eligible: true)
        driver.update(mode: .off, eligible: false)
        XCTAssertTrue(backend.writes.isEmpty, "A later observation must not re-zero the user's value")
        XCTAssertEqual(backend.value, 0.5)
    }

    @MainActor func testCrashAfterPreparedWriteRecoversWithoutResumingOldHold() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.value = 0
        journal.record = .init(target: backend.target, original: 0.8, phase: .prepared)
        let relaunched = ClosedLidDisplayDriver(backend: backend, journal: journal)
        relaunched.recover()
        XCTAssertEqual(backend.writes, [0.8])
        XCTAssertFalse(relaunched.hasRecoveryDebt)
        XCTAssertEqual(relaunched.state, .inactive)
    }

    @MainActor func testCrashRecoveryDoesNotOverwriteSubsequentUserChange() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.value = 0.3
        journal.record = .init(target: backend.target, original: 0.8, phase: .applied)
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.recover()
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(driver.state, .userChangePreserved)
        XCTAssertFalse(driver.hasRecoveryDebt)
    }

    @MainActor func testMissingTargetAndRecoveryFailurePreserveOriginalAndBoundRetries() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.readable = false
        journal.record = .init(target: backend.target, original: 0.8, phase: .applied)
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        for _ in 0..<5 { driver.update(mode: .off, eligible: false) }
        XCTAssertEqual(backend.readCount, 1)
        XCTAssertEqual(driver.state, .recoveryPending(.recoveryTargetUnavailable))
        XCTAssertEqual(journal.record?.original, 0.8)
        backend.readable = true; backend.value = 0
        driver.retryRecovery()
        XCTAssertEqual(backend.writes, [0.8])
        XCTAssertNil(journal.record)
    }

    @MainActor func testReadAgainAfterJournalCommitPreservesConcurrentUserChange() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.value = 0
        journal.record = .init(target: backend.target, original: 0.8, phase: .applied)
        journal.afterSave = { backend.value = 0.5 }
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.recover()
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.value, 0.5)
        XCTAssertFalse(driver.hasRecoveryDebt)
    }

    @MainActor func testRemovalFailureRetainsRecordWithoutRepeatedRestoreWrite() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        journal.removeFails = true
        driver.update(mode: .off, eligible: false)
        XCTAssertEqual(driver.state, .recoveryPending(.journalUnavailable))
        XCTAssertEqual(backend.writes, [0, 0.7])
        journal.removeFails = false
        driver.retryRecovery()
        XCTAssertEqual(backend.writes, [0, 0.7])
        XCTAssertFalse(driver.hasRecoveryDebt)
    }

    @MainActor func testNewExternalDisplayRestoresPanelAndNeverTouchesAnotherTarget() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        backend.support = .init(availability: .unavailable, issue: .externalDisplayPresent)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(backend.writes, [0, 0.7])
        XCTAssertEqual(driver.state, .unavailable(.externalDisplayPresent))
        XCTAssertTrue(backend.writeTargets.allSatisfy { $0 == backend.target })
        XCTAssertFalse(driver.hasRecoveryDebt)
    }

    @MainActor func testOriginalZeroIsNotOwnedAndHasNoInventedRestore() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        backend.value = 0
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertEqual(driver.state, .brightnessZero)
        XCTAssertFalse(driver.hasRecoveryDebt)
        backend.value = 0.4
        driver.update(mode: .zeroBrightness, eligible: true)
        driver.update(mode: .off, eligible: false)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.value, 0.4)
    }

    @MainActor func testUnreadableJournalBlocksAcquisitionUntilExplicitRetry() {
        let backend = BrightnessFake(); let journal = BrightnessJournalFake()
        journal.loadFails = true
        let driver = ClosedLidDisplayDriver(backend: backend, journal: journal)
        driver.update(mode: .zeroBrightness, eligible: true)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertTrue(driver.hasRecoveryDebt)
        journal.loadFails = false
        driver.retryRecovery()
        XCTAssertFalse(driver.hasRecoveryDebt)
    }
}

private final class BrightnessFake: ClosedLidDisplayBrightnessBackend {
    let target = ClosedLidDisplayTarget(id: 7, vendor: 100, model: 200)
    var support: ClosedLidDisplaySupport = .init(availability: .candidateRequiresPhysicalValidation,
        target: .init(id: 7, vendor: 100, model: 200))
    var value: Float = 0.7
    var readable = true
    var writeSucceeds = true
    var readCount = 0
    var writes: [Float] = []
    var writeTargets: [ClosedLidDisplayTarget] = []
    var afterWrite: (() -> Void)?
    func read(target: ClosedLidDisplayTarget) -> Float? {
        readCount += 1
        return readable && target == self.target ? value : nil
    }
    func write(_ brightness: Float, target: ClosedLidDisplayTarget) -> Bool {
        writes.append(brightness); writeTargets.append(target)
        value = brightness; afterWrite?()
        return writeSucceeds
    }
}

private final class BrightnessJournalFake: ClosedLidDisplayRecoveryJournaling {
    enum Failure: Error { case expected }
    var record: ClosedLidDisplayRecoveryRecord?
    var saveFails = false, loadFails = false, removeFails = false
    var afterSave: (() -> Void)?
    func load() throws -> ClosedLidDisplayRecoveryRecord? {
        if loadFails { throw Failure.expected }; return record
    }
    func save(_ record: ClosedLidDisplayRecoveryRecord) throws {
        if saveFails { throw Failure.expected }; self.record = record; afterSave?()
    }
    func remove() throws {
        if removeFails { throw Failure.expected }; record = nil
    }
}
