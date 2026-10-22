import XCTest
@testable import TetherCore

final class V4SettingsHistoryTests: XCTestCase {
    func testTypedExportRoundTripIsCanonicalAndContainsNoRuntimeState() throws {
        var document = V4SettingsDocument()
        let condition = V4Condition(id: UUID(), kind: .timeWindow, timeWindow: .init(startMinute: 0, endMinute: 60, weekdays: [7, 1, 3]))
        document.settings = V4Fixture.settings([[condition]])
        let data = try V4SettingsTransfer.encode(document)
        let decoded = try V4SettingsTransfer.decode(data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(try V4SettingsTransfer.encode(decoded), data)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["requestID", "bootID", "ownerID", "lease", "paused", "protectionActive"] { XCTAssertFalse(text.contains("\"\(key)\"")) }
    }
    func testImportCreatesDisabledDistinctCopiesAndPreservesGlobals() {
        let condition = V4Condition(id: UUID(), kind: .appRunning, target: "app")
        var current = V4SettingsDocument(); current.settings = V4Fixture.settings([[condition]])
        current.preferences.allowDisplay = true
        let source = current
        let ids = source.settings.presets.map(\.id) + source.settings.presets.flatMap(\.groups).map(\.id) + [condition.id]
        let replacements = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
        let preview = V4SettingsTransfer.previewImport(source, current: current, replacementIDs: replacements)
        XCTAssertFalse(preview.issues.contains(where: \.blocking))
        XCTAssertEqual(preview.candidate.settings.presets.count, 2)
        XCTAssertEqual(preview.candidate.settings.activePresetID, current.settings.activePresetID)
        XCTAssertTrue(preview.candidate.preferences.allowDisplay)
        XCTAssertFalse(preview.candidate.settings.presets[1].enabled)
        XCTAssertEqual(preview.candidate.settings.presets[1].name, "Work (2)")
    }
    func testUnknownANDConditionCannotBeDroppedOnImport() throws {
        let condition = V4Condition(id: UUID(), kind: .unsupported, target: "future-provider")
        var source = V4SettingsDocument(); source.settings = V4Fixture.settings([[condition]])
        let data = try V4SettingsTransfer.encode(source)
        XCTAssertThrowsError(try V4SettingsTransfer.decode(data))
    }
    func testPreviewCASRejectsSameGenerationContentChange() {
        let current = V4SettingsDocument(); var source = current; source.settings.notifyTaskEnd = true
        let preview = V4SettingsTransfer.preview(source: source, current: current, selected: [.notifications], activeManual: false)
        var changed = current; changed.preferences.allowDisplay = true
        XCTAssertEqual(V4SettingsTransfer.apply(preview, current: changed, activeManual: false).disposition, .rejected)
    }
    func testActiveManualBlocksGlobalChangeButAllowsNextRequestDefault() {
        let current = V4SettingsDocument(); var source = current
        source.preferences.allowDisplay = true; source.preferences.nextManualMinutes = 60
        let global = V4SettingsTransfer.preview(source: source, current: current, selected: [.globalFeatures], activeManual: true)
        XCTAssertTrue(global.affectsActiveManual)
        XCTAssertNil(V4SettingsTransfer.apply(global, current: current, activeManual: true).document)
        let defaults = V4SettingsTransfer.preview(source: source, current: current, selected: [.manualDefaults], activeManual: true)
        XCTAssertEqual(V4SettingsTransfer.apply(defaults, current: current, activeManual: true).disposition, .accepted)
    }
    func testHistoryBoundsNoOpAndDeletedRollback() {
        var history = V4SettingsHistory(); history.maximumEntries = 2
        var before = V4SettingsDocument()
        var generationOnly = before; generationOnly.generation += 1
        XCTAssertEqual(history.recordChange(before: before, after: generationOnly, id: UUID(), at: 0, source: .user), .alreadyProcessed)
        for index in 0..<3 {
            var after = before; after.settings.notifyTaskEnd.toggle()
            XCTAssertEqual(history.recordChange(before: before, after: after, id: UUID(), at: Double(index), source: .user), .accepted)
            before = after
        }
        XCTAssertEqual(history.entries.count, 2)
        let id = history.entries[0].id
        let preview = history.previewRollback(id: id, current: before, selected: [.notifications], activeManual: false)!
        history.delete(id: id)
        XCTAssertEqual(history.applyRollback(id: id, preview: preview, current: before, activeManual: false).disposition, .rejected)
        history.noteHistoryWriteFailure(); XCTAssertTrue(history.missingHistory)
    }
    func testPreviouslySavedCustomDefaultRoundTripsAndDoesNotBlockUnrelatedRollback() throws {
        for minutes in [17, 42] {
            var before = V4SettingsDocument(); before.preferences.nextManualMinutes = minutes
            XCTAssertEqual(try V4SettingsTransfer.decode(V4SettingsTransfer.encode(before)), before)
            var after = before; after.settings.notifyTaskEnd = true
            var history = V4SettingsHistory(); let id = UUID()
            XCTAssertEqual(history.recordChange(before: before, after: after, id: id, at: 100, source: .user), .accepted)
            let preview = try XCTUnwrap(history.previewRollback(id: id, current: after, selected: [.notifications], activeManual: true))
            let restored = try XCTUnwrap(history.applyRollback(id: id, preview: preview, current: after, activeManual: true).document)
            XCTAssertEqual(restored.preferences.nextManualMinutes, minutes)
            XCTAssertFalse(restored.settings.notifyTaskEnd)
        }
    }
    func testUnsafeStoredDefaultAndCustomNewPresetAreStillRejected() {
        for minutes in [0, -1, Int.max] {
            var document = V4SettingsDocument(); document.preferences.nextManualMinutes = minutes
            XCTAssertFalse(V4SettingsTransfer.validate(document).isEmpty)
        }
        var settings = V4Fixture.settings([[.init(id: UUID(), kind: .appRunning, target: "app")]])
        settings.presets[0].nextManualMinutes = 17
        XCTAssertTrue(V4RuleEngine.validate(settings).contains("invalid-manual-default"))
    }
    func testPreservedCustomDefaultDoesNotOverrideBatteryStartedSnapshotCap() throws {
        var document = V4SettingsDocument(); document.preferences.nextManualMinutes = 180
        XCTAssertEqual(try V4SettingsTransfer.decode(V4SettingsTransfer.encode(document)).preferences.nextManualMinutes, 180)
        var snapshot = V4Fixture.manual(deadline: 180 * 60)
        XCTAssertTrue(snapshot.isActive(at: 7200), "AC-started snapshots can retain a longer explicit duration")
        snapshot.batteryStartedAt = 0
        XCTAssertFalse(snapshot.isActive(at: 7200), "Even after AC connection, a battery-started snapshot cannot exceed original start +120m")
    }
    func testEndActionAndProtectionNotificationPreferencesRoundTripAndLegacyDefaults() throws {
        var document = V4SettingsDocument()
        document.preferences.disconnectAction = .followOS
        document.preferences.notifyHeat = false; document.preferences.notifyBatteryProtection = false
        let decoded = try V4SettingsTransfer.decode(V4SettingsTransfer.encode(document))
        XCTAssertEqual(decoded, document)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(V4AppPreferences())) as? [String: Any])
        for key in ["disconnectAction", "notifyHeat", "notifyBatteryProtection"] { legacyJSON.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(V4AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(legacy.disconnectAction, .sleepIfClosed)
        XCTAssertTrue(legacy.notifyHeat); XCTAssertTrue(legacy.notifyBatteryProtection)
        XCTAssertEqual(legacy.nextManualMinutes, 30)
        var unlimited = document; unlimited.preferences.nextManualMinutes = nil
        XCTAssertNil(try V4SettingsTransfer.decode(V4SettingsTransfer.encode(unlimited)).preferences.nextManualMinutes)
    }
    func testUnknownEndActionOrWrongNotificationTypeFailsDecode() throws {
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(V4AppPreferences())) as? [String: Any])
        for (key, value) in [("disconnectAction", "forceShutdown" as Any), ("notifyHeat", "false" as Any), ("notifyBatteryProtection", 1 as Any)] {
            var changed = baseline; changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(V4AppPreferences.self, from: JSONSerialization.data(withJSONObject: changed)))
        }
    }
    func testProtectionNotificationChangesAreTrackedAndRestoredWithoutChangingEndAction() throws {
        let current = V4SettingsDocument(); var source = current
        source.preferences.notifyHeat = false; source.preferences.notifyBatteryProtection = false
        source.preferences.disconnectAction = .followOS
        XCTAssertEqual(V4SettingsTransfer.changedParts(from: current, to: source), [.notifications, .globalFeatures])
        let preview = V4SettingsTransfer.preview(source: source, current: current, selected: [.notifications], activeManual: true)
        XCTAssertEqual(preview.changedParts, [.notifications]); XCTAssertFalse(preview.affectsActiveManual)
        let restored = try XCTUnwrap(V4SettingsTransfer.apply(preview, current: current, activeManual: true).document)
        XCTAssertFalse(restored.preferences.notifyHeat); XCTAssertFalse(restored.preferences.notifyBatteryProtection)
        XCTAssertEqual(restored.preferences.disconnectAction, .sleepIfClosed)
    }
    func testEndActionRestoreIsAtomicAndDeferredWhileManualIsActive() throws {
        let current = V4SettingsDocument(); var source = current
        source.preferences.disconnectAction = .followOS; source.preferences.notifyHeat = false
        let blocked = V4SettingsTransfer.preview(source: source, current: current, selected: [.globalFeatures, .notifications], activeManual: true)
        XCTAssertTrue(blocked.affectsActiveManual)
        XCTAssertNil(V4SettingsTransfer.apply(blocked, current: current, activeManual: true).document)
        let allowed = V4SettingsTransfer.preview(source: source, current: current, selected: [.globalFeatures], activeManual: false)
        let restored = try XCTUnwrap(V4SettingsTransfer.apply(allowed, current: current, activeManual: false).document)
        XCTAssertEqual(restored.preferences.disconnectAction, .followOS)
        XCTAssertTrue(restored.preferences.notifyHeat)
    }
    func testSingleProtectionNotificationToggleProducesHistoryAndRollback() throws {
        let before = V4SettingsDocument(); var after = before
        after.preferences.notifyBatteryProtection = false
        var history = V4SettingsHistory(); let id = UUID()
        XCTAssertEqual(history.recordChange(before: before, after: after, id: id, at: 100, source: .user), .accepted)
        let preview = try XCTUnwrap(history.previewRollback(id: id, current: after, selected: [.notifications], activeManual: true))
        let restored = try XCTUnwrap(history.applyRollback(id: id, preview: preview, current: after, activeManual: true).document)
        XCTAssertTrue(restored.preferences.notifyBatteryProtection)
    }
}
