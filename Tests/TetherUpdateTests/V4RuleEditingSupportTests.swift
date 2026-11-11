import Foundation
import XCTest
import TetherCore
@testable import Tether

final class V4RuleEditingSupportTests: XCTestCase {
    func testTemplateCreatesDraftWithoutReplacingExistingGroupsOrOptions() throws {
        var saved = V4Settings()
        saved.generation = 19
        saved.stopOnLowPowerMode = true
        saved.notifyTaskEnd = true
        saved.experimentalProvidersEnabled = true
        saved.nextManualOptions = .init(display: false, closedLid: true, releaseDisplayAfterIdle: 600)
        let original = V4Preset(id: UUID(), name: "Existing", groups: [
            .init(id: UUID(), conditions: [
                .init(id: UUID(), kind: .appRunning, target: "org.example.Writer"),
                .init(id: UUID(), kind: .wifiSSID, target: "Office")
            ]),
            .init(id: UUID(), conditions: [.init(id: UUID(), kind: .externalDisplay, target: "42")])
        ], options: .init(display: true, closedLid: false), nextManualMinutes: 15, enabled: false)
        saved.presets = [original]
        saved.activePresetID = original.id

        let draft = V4RuleStarter.workHours.adding(to: saved, nextManualMinutes: 60)

        XCTAssertEqual(saved.presets, [original], "Editing a draft must not mutate the saved settings")
        XCTAssertEqual(saved.automaticMode, .acConnected)
        XCTAssertEqual(draft.presets.first, original, "Existing AND/OR groups and disabled state must survive")
        XCTAssertEqual(draft.generation, saved.generation)
        XCTAssertEqual(draft.nextManualOptions, saved.nextManualOptions)
        XCTAssertTrue(draft.stopOnLowPowerMode)
        XCTAssertTrue(draft.notifyTaskEnd)
        XCTAssertTrue(draft.experimentalProvidersEnabled)
        let added = try XCTUnwrap(V4RuleEngine.activePreset(draft))
        XCTAssertNotEqual(added.id, original.id)
        XCTAssertEqual(added.options, saved.nextManualOptions)
        XCTAssertEqual(added.nextManualMinutes, 60)
        XCTAssertTrue(V4RuleEngine.validate(draft).isEmpty)
    }

    func testWorkHoursStartsWithWeekdayNineToFiveAndIndependentIdentities() throws {
        let first = V4RuleStarter.workHours.adding(to: .init(), nextManualMinutes: 30)
        let second = V4RuleStarter.workHours.adding(to: first, nextManualMinutes: 30)
        let preset = try XCTUnwrap(V4RuleEngine.activePreset(second))
        let condition = try XCTUnwrap(preset.groups.first?.conditions.first)
        XCTAssertEqual(condition.kind, .timeWindow)
        XCTAssertEqual(condition.timeWindow, V4TimeWindow(startMinute: 540, endMinute: 1020, weekdays: Set(2...6)))
        XCTAssertNotEqual(first.presets[0].name, preset.name)
        XCTAssertNotEqual(first.presets[0].groups[0].id, preset.groups[0].id)
        XCTAssertNotEqual(first.presets[0].groups[0].conditions[0].id, condition.id)
        XCTAssertFalse(V4RuleStarter.needsTargetSelection(second))
    }

    func testAppAndDisplayTemplatesRequireExplicitTargetBeforeApply() {
        for starter in [V4RuleStarter.application, .externalDisplay] {
            var draft = starter.adding(to: .init(), nextManualMinutes: nil)
            XCTAssertTrue(V4RuleStarter.needsTargetSelection(draft))
            XCTAssertNil(draft.presets[0].nextManualMinutes)
            draft.presets[0].groups[0].conditions[0].target = "  \n"
            XCTAssertTrue(V4RuleStarter.needsTargetSelection(draft))
            draft.presets[0].groups[0].conditions[0].target = starter == .application ? "org.example.Editor" : "42"
            XCTAssertFalse(V4RuleStarter.needsTargetSelection(draft))
        }
    }

    func testTargetRequirementDoesNotBlockPowerOnlyOrDisabledCopies() {
        var draft = V4RuleStarter.application.adding(to: .init(), nextManualMinutes: 30)
        draft.presets[0].enabled = false
        XCTAssertFalse(V4RuleStarter.needsTargetSelection(draft))
        draft.presets[0].enabled = true
        draft.automaticMode = .acConnected
        XCTAssertFalse(V4RuleStarter.needsTargetSelection(draft))
    }

    func testTemplateLimitDoesNotSilentlyDropExistingPresets() {
        var settings = V4Settings()
        settings.presets = (0..<V4RuleEngine.maximumPresets).map {
            V4Preset(id: UUID(), name: "Preset \($0)", groups: [])
        }
        XCTAssertFalse(V4RuleStarter.canAdd(to: settings))
        XCTAssertEqual(V4RuleStarter.workHours.adding(to: settings, nextManualMinutes: 30), settings)
    }

    func testUnrepresentableManualDurationDoesNotInvalidateNewPreset() {
        let draft = V4RuleStarter.workHours.adding(to: .init(), nextManualMinutes: 240)
        XCTAssertTrue(V4RuleEngine.validate(draft).isEmpty)
    }

    func testAppSelectionKeepsProviderIdentifierAndUsesLocalizedDisplayName() throws {
        let application = try XCTUnwrap(V4SelectedApplication(url: URL(fileURLWithPath: "/Applications/Editor.app"),
            info: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.Example.Editor", "CFBundleName": "Editor"],
            localizedInfo: ["CFBundleDisplayName": "편집기"]))
        XCTAssertEqual(application.bundleIdentifier, "org.Example.Editor", "The provider uses a case-sensitive identifier match")
        XCTAssertEqual(application.name, "편집기")
    }

    func testInvalidAppMetadataCannotReplaceAConditionTarget() {
        let url = URL(fileURLWithPath: "/Applications/Editor.app")
        XCTAssertNil(V4SelectedApplication(url: url, info: [:]))
        XCTAssertNil(V4SelectedApplication(url: url, info: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": " \n"]))
        XCTAssertNil(V4SelectedApplication(url: url, info: ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "org.example.Editor"]))
        XCTAssertNil(V4SelectedApplication(url: URL(fileURLWithPath: "/Applications/Editor.bundle"),
            info: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.example.Editor"]))
        XCTAssertNil(V4SelectedApplication(url: URL(string: "https://example.invalid/Editor.app")!,
            info: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.example.Editor"]))
    }

    func testAppWithoutDisplayNameUsesSelectedFilename() throws {
        let application = try XCTUnwrap(V4SelectedApplication(url: URL(fileURLWithPath: "/Applications/My Editor.app"),
            info: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.example.Editor"]))
        XCTAssertEqual(application.name, "My Editor")
    }
}
