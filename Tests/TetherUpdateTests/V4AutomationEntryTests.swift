import Carbon
import XCTest
import TetherCore
@testable import Tether

private final class V4ShortcutMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class V4ShortcutRegistrarFixture: V4ShortcutRegistering {
    var rejectRegistration = false
    var rejectUnregistration = false
    var events: [String] = []
    var handlers: [UUID: @MainActor () -> Void] = [:]
    func register(_ chord: V4ShortcutChord, handler: @escaping @MainActor () -> Void) throws -> UUID {
        events.append("register:\(chord.keyCode)")
        if rejectRegistration { throw V4ShortcutFailure.conflict }
        let token = UUID(); handlers[token] = handler; return token
    }
    func unregister(_ token: UUID) -> Bool {
        events.append("unregister")
        if rejectUnregistration { return false }
        handlers.removeValue(forKey: token); return true
    }
}

final class V4AutomationEntryTests: XCTestCase {
    @MainActor
    func testFreshInstallRegistersNoKeyAndWritesNoPreference() {
        let defaults = V4ShortcutMemoryDefaults()
        let registrar = V4ShortcutRegistrarFixture()
        let controller = V4ShortcutController(defaults: defaults, registrar: registrar) { _ in XCTFail("No key was assigned") }
        controller.activateSavedAssignments()
        XCTAssertTrue(registrar.events.isEmpty)
        XCTAssertTrue(controller.assignments.isEmpty)
        XCTAssertNil(defaults.data(forKey: V4ShortcutController.defaultsKey))
    }

    @MainActor
    func testReplacementConflictPreservesOldRegistrationAndSavedBytes() throws {
        let defaults = V4ShortcutMemoryDefaults()
        let registrar = V4ShortcutRegistrarFixture()
        let controller = V4ShortcutController(defaults: defaults, registrar: registrar) { _ in }
        let old = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(controller.assign(old, to: .startManual))
        let bytes = try XCTUnwrap(defaults.data(forKey: V4ShortcutController.defaultsKey))
        let oldToken = try XCTUnwrap(registrar.handlers.keys.first)
        registrar.events.removeAll(); registrar.rejectRegistration = true
        XCTAssertFalse(controller.assign(V4ShortcutChord(keyCode: 46, modifiers: old.modifiers), to: .startManual))
        XCTAssertEqual(registrar.events, ["register:46"])
        XCTAssertNotNil(registrar.handlers[oldToken])
        XCTAssertEqual(controller.assignments[.startManual], old)
        XCTAssertEqual(defaults.data(forKey: V4ShortcutController.defaultsKey), bytes)
        XCTAssertTrue(controller.activeActions.contains(.startManual))
        XCTAssertNotNil(controller.lastError)
    }

    @MainActor
    func testReplacementRegistersBeforeReleasingAndDispatchesExactScope() throws {
        let registrar = V4ShortcutRegistrarFixture()
        var actions: [V4AutomationAction] = []
        let controller = V4ShortcutController(defaults: V4ShortcutMemoryDefaults(), registrar: registrar) { actions.append($0) }
        let old = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(controller.assign(old, to: .endManual))
        registrar.events.removeAll()
        XCTAssertTrue(controller.assign(V4ShortcutChord(keyCode: 46, modifiers: old.modifiers), to: .endManual))
        XCTAssertEqual(registrar.events, ["register:46", "unregister"])
        XCTAssertEqual(registrar.handlers.count, 1)
        try XCTUnwrap(registrar.handlers.values.first)()
        XCTAssertEqual(actions, [.endManual], "A manual-end shortcut must not become Pause all")
    }

    @MainActor
    func testDuplicateAndUnmodifiedAssignmentsDoNotCallOSAdapter() {
        let registrar = V4ShortcutRegistrarFixture()
        let controller = V4ShortcutController(defaults: V4ShortcutMemoryDefaults(), registrar: registrar) { _ in }
        let chord = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(controller.assign(chord, to: .pauseAll))
        registrar.events.removeAll()
        XCTAssertFalse(controller.assign(chord, to: .startManual))
        XCTAssertFalse(controller.assign(V4ShortcutChord(keyCode: 17, modifiers: 0), to: .startManual))
        XCTAssertTrue(registrar.events.isEmpty)
        XCTAssertEqual(controller.assignments[.pauseAll], chord)
        XCTAssertNil(controller.assignments[.startManual])
    }

    @MainActor
    func testSavedExplicitChoiceRestoresOnceAndClearRemovesRegistration() {
        let defaults = V4ShortcutMemoryDefaults()
        let firstRegistrar = V4ShortcutRegistrarFixture()
        let first = V4ShortcutController(defaults: defaults, registrar: firstRegistrar) { _ in }
        let chord = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(first.assign(chord, to: .automaticOff)); first.deactivate()
        let registrar = V4ShortcutRegistrarFixture()
        let restored = V4ShortcutController(defaults: defaults, registrar: registrar) { _ in }
        XCTAssertTrue(registrar.events.isEmpty, "Reading settings does not register a key")
        restored.activateSavedAssignments(); restored.activateSavedAssignments()
        XCTAssertEqual(registrar.events, ["register:17"])
        XCTAssertTrue(restored.assign(nil, to: .automaticOff))
        XCTAssertTrue(restored.activeActions.isEmpty)
        XCTAssertTrue(registrar.handlers.isEmpty)
        XCTAssertNil(restored.assignments[.automaticOff])
    }

    @MainActor
    func testUnregisterFailureKeepsOldAssignment() {
        let defaults = V4ShortcutMemoryDefaults()
        let registrar = V4ShortcutRegistrarFixture()
        let controller = V4ShortcutController(defaults: defaults, registrar: registrar) { _ in }
        let old = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(controller.assign(old, to: .pauseAll))
        let before = defaults.data(forKey: V4ShortcutController.defaultsKey)
        registrar.rejectUnregistration = true
        XCTAssertFalse(controller.assign(nil, to: .pauseAll))
        XCTAssertEqual(controller.assignments[.pauseAll], old)
        XCTAssertEqual(defaults.data(forKey: V4ShortcutController.defaultsKey), before)
        XCTAssertTrue(controller.activeActions.contains(.pauseAll))
    }

    @MainActor
    func testFailedReplacementCannotDispatchAnUncommittedNewKey() {
        let registrar = V4ShortcutRegistrarFixture()
        var actions: [V4AutomationAction] = []
        let controller = V4ShortcutController(defaults: V4ShortcutMemoryDefaults(), registrar: registrar) { actions.append($0) }
        let old = V4ShortcutChord(keyCode: 17, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(controller.assign(old, to: .pauseAll))
        registrar.rejectUnregistration = true
        XCTAssertFalse(controller.assign(V4ShortcutChord(keyCode: 46, modifiers: old.modifiers), to: .pauseAll))
        for handler in registrar.handlers.values { handler() }
        XCTAssertEqual(actions, [.pauseAll], "Only the committed original key may dispatch when cleanup also fails")
        XCTAssertEqual(controller.assignments[.pauseAll], old)
    }

    @MainActor
    func testAutomationStatusIsReadOnlyAndPreviewEntryRequiresExplicitTestBoundary() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        let denied = await model.performV4Automation(.startManual)
        XCTAssertEqual(denied.outcome, .unconfirmed)
        XCTAssertFalse(work.status.manualActive)
        let before = work.manualRequestID
        let status = await model.performV4Automation(.status, allowPreview: true)
        XCTAssertTrue(status.succeeded)
        XCTAssertEqual(work.manualRequestID, before)
        XCTAssertFalse(work.status.automaticEnabled)
    }

    @MainActor
    func testAutomationScopesKeepManualAndSavedAutomaticIndependent() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        let start = await model.performV4Automation(.startManual, minutes: 15, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(start.outcome, .accepted)
        let id = try XCTUnwrap(work.manualRequestID)
        let duplicate = await model.performV4Automation(.startManual, minutes: 30, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(duplicate.outcome, .rejected)
        XCTAssertEqual(work.manualRequestID, id)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        _ = await model.performV4Automation(.automaticOff, allowPreview: true)
        XCTAssertEqual(work.manualRequestID, id)
        XCTAssertTrue(work.status.manualActive)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        let pause = await model.performV4Automation(.pauseAll, allowPreview: true)
        XCTAssertTrue(pause.succeeded)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertTrue(work.status.automaticEnabled)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        XCTAssertTrue(model.workPaused)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertFalse(work.status.holding)
    }

    @MainActor
    func testBatteryUnlimitedAutomationRejectsWithoutCreatingRequest() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready", "--battery"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        work.endManual()
        let reply = await model.performV4Automation(.startManual, minutes: nil, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(reply.outcome, .rejected)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertNil(work.manualRequestID)
    }
}
