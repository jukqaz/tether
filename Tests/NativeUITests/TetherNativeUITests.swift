import AppKit
import XCTest
import Vision

/// Runs the shipping Settings and MenuBarExtra scenes in the private fixture bundle.
/// Missing AX elements are failures. No production app, helper or system UI is queried.
@MainActor
final class TetherNativeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testLanguage = "en"
    private let bundleID = "io.github.jukqaz.tether.ui-tests"
    private let expectedExecutablePath = "__TETHER_UI_EXPECTED_EXECUTABLE_PATH__"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUnifiedCopyKoreanLightMenuStatesAndExpandedSettings() throws {
        try verifyUnifiedCopy(language: "ko", appearance: "light")
    }

    func testUnifiedCopyEnglishDarkMenuStatesAndExpandedSettings() throws {
        try verifyUnifiedCopy(language: "en", appearance: "dark")
    }

    private func verifyUnifiedCopy(language: String, appearance: String) throws {
        let korean = language == "ko"
        let prefix = "copy-\(language)-\(appearance)"
        try launch(language: language, scenario: "ac", appearance: appearance)
        try openMenu()
        try assertCopyMenu(title: korean ? "자동 유지 중" : "Automatic keep-awake active",
                           controls: ["automatic-pause-menu", "panel-start-manual", "panel-keep-display-awake"])
        try assertDisclosureCollapsed(try disclosureTriangle("panel-closed-lid-policy"))
        XCTAssertFalse(app.descendants(matching: .any)["panel-automatic"].firstMatch.isHittable,
                       "Automatic on/off stays inside the initially collapsed work details")
        copyEvidence("\(prefix)-automatic")
        try setAutomatic(false)
        try selectDurationPreset(try required("manual-duration-picker"),
            expected: korean ? ["30분", "1시간", "2시간", "종료할 때까지"] : ["30 min", "1 h", "2 h", "Until ended"],
            selected: korean ? "종료할 때까지" : "Until ended", evidenceName: "\(prefix)-untimed-choice", inSettings: false)
        try required("panel-start-manual").click()
        try waitForState(["manual": true, "holding": true])
        let manual = try state()
        let request = try XCTUnwrap(manual["manualRequestID"] as? String)
        try assertCopyMenu(title: korean ? "수동 유지 중" : "Manual keep-awake active",
                           controls: ["panel-end-manual", "panel-pause-all"])
        XCTAssertEqual(try required("panel-end-manual").label, korean ? "수동 유지 종료" : "End manual")
        let countdown = try required("panel-manual-countdown")
        // SwiftUI's combined Other exposes its accessible name but XCTest
        // omits AXValue here. Verify the visible glyphs, not that AX limitation.
        let requestOCR = VNRecognizeTextRequest()
        requestOCR.recognitionLevel = .accurate
        requestOCR.recognitionLanguages = korean ? ["ko-KR", "en-US"] : ["en-US"]
        try VNImageRequestHandler(data: countdown.screenshot().pngRepresentation).perform([requestOCR])
        let recognized = (requestOCR.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let compact = { (text: String) in text.filter { !$0.isWhitespace } }
        XCTAssertTrue(compact(recognized).contains(compact(korean ? "종료할 때까지" : "Until ended")),
                      "The complete untimed caption must be visible in native pixels: \(recognized)")
        XCTAssertFalse(app.descendants(matching: .any)["panel-extend-manual-30"].exists,
                       "Untimed keep-awake must not advertise a timed extension")
        copyEvidence("\(prefix)-manual-untimed")
        try setAutomatic(true)
        try waitForState(["automatic": true, "manual": true])
        XCTAssertEqual(try state()["manualRequestID"] as? String, request)
        try assertCopyMenu(title: korean ? "자동·수동 유지 중" : "Automatic + manual active",
                           controls: ["panel-end-manual", "panel-pause-all"])
        copyEvidence("\(prefix)-dual")
        try required("panel-pause-all").click()
        try waitForState(["manual": false, "holding": false, "paused": true])
        try assertCopyMenu(title: korean ? "모두 중지됨" : "All keep-awake stopped", controls: ["panel-pause-all"])
        XCTAssertEqual(try required("panel-pause-all").label, korean ? "중지 해제" : "Resume")
        copyEvidence("\(prefix)-all-stopped")
        try required("panel-pause-all").click()
        try waitForState(["paused": false, "manual": false, "holding": true])
        copyEvidence("\(prefix)-resumed-without-manual-revival")
        try openSettingsFromMenu()
        let window = try activateSettingsWindow()
        let beforeSettings = try state()
        let disclosures: [String: [String]] = [
            "safety": ["settings-unplug-details", "settings-closed-lid-display-details", "settings-power-scope-details"],
            "general": ["manual-defaults-application-details", "settings-manual-battery-details", "settings-manual-limits-application-details"],
            "protection": ["settings-work-rules-details", "settings-records-diagnostics-details", "settings-usage-statistics-details", "settings-protection-basis-details"],
            "system": ["settings-notifications-details", "settings-updates-details", "settings-app-advanced-details", "settings-app-behavior-details"]]
        for (page, title) in settingsPageNames {
            try selectPage(page, title: title)
            copyEvidence("\(prefix)-settings-\(page)-collapsed")
            if page == "general" {
                XCTAssertTrue(try required("manual-defaults-save-summary").exists)
                XCTAssertFalse(app.descendants(matching: .any)["manual-defaults-scope"].exists,
                               "Long application scope stays in the initially collapsed disclosure")
            }
            for identifier in disclosures[page] ?? [] { try expandSettingsDisclosure(identifier) }
            let scroll = try settingsPageScrollView()
            scroll.scroll(byDeltaX: 0, deltaY: 4000)
            try assertSettingsPageLayout(window, page: page, title: title)
            try assertVisibleCopyBounds(in: scroll, container: window)
            copyEvidence("\(prefix)-settings-\(page)-expanded-top")
            scroll.scroll(byDeltaX: 0, deltaY: -4000)
            try assertSettingsPageLayout(window, page: page, title: title)
            try assertVisibleCopyBounds(in: scroll, container: window)
            copyEvidence("\(prefix)-settings-\(page)-expanded-end")
        }
        let afterSettings = try state()
        for key in ["automatic", "manual", "holding", "paused", "keepDisplayAwake"] {
            XCTAssertEqual(afterSettings[key] as? Bool, beforeSettings[key] as? Bool,
                           "Reading translated settings must not change \(key)")
        }
        app.terminate(); app = nil
        try launch(language: language, scenario: "protection", appearance: appearance)
        try openMenu()
        try assertCopyMenu(title: korean ? "보호를 위해 중지됨" : "Stopped for protection", controls: ["panel-open-settings"])
        XCTAssertFalse(app.descendants(matching: .any)["panel-start-manual"].exists)
        copyEvidence("\(prefix)-protection")
    }

    /// Focused copy review retains native pixels, fixture state and surface bounds.
    /// Bulk anonymous AX geometry is covered by the dedicated layout suite.
    private func copyEvidence(_ name: String) {
        guard let app else { return }
        if let state = try? state(), let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(name)-fixture-state.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let menu = app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        let surface = menu.exists ? menu : settings
        guard surface.exists else { XCTFail("No copy-review surface for \(name)"); return }
        let before = surface.frame
        XCTAssertTrue(isLayoutFrame(before))
        let attachment = XCTAttachment(screenshot: surface.screenshot())
        attachment.name = "\(name)-screenshot"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(before, surface.frame, "Copy review surface must stay still during capture")
    }

    private func assertCopyMenu(title: String, controls: [String]) throws {
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch,
                                 description: "Localized native menu")
        let status = try required("panel-status")
        let visible = [status.label, status.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(visible.contains(title), "Wrong state wording: \(visible)")
        for identifier in controls {
            let control = try required(identifier)
            XCTAssertTrue(control.isHittable, "Localized action must remain reachable: \(identifier)")
            XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(control.frame),
                           "Localized actions must fit the compact panel")
            let accessibleName = control.label.isEmpty ? control.title : control.label
            XCTAssertFalse(accessibleName.isEmpty, "Localized actions must expose their accessible names")
            // Start and Settings intentionally expose different accessible
            // names. Measure their complete visible captions at the source font.
            let caption: String
            switch identifier {
            case "panel-start-manual": caption = testLanguage == "ko" ? "수동 유지 시작" : "Start manual"
            case "panel-open-settings": caption = testLanguage == "ko" ? "설정…" : "Settings…"
            case "panel-allow-closed-lid": caption = testLanguage == "ko" ? "덮개 닫고 사용 허용" : "Allow closed-lid use"
            case "panel-keep-display-awake": caption = testLanguage == "ko" ? "화면 켜두기 허용" : "Allow display keep-awake"
            default: caption = accessibleName
            }
            if [.checkBox, .switch, .toggle].contains(control.elementType) {
                XCTAssertEqual(control.label, caption, "The native Boolean input must name its complete visible caption")
                try assertCopyBooleanCaption(caption, control: control, identifier: identifier, in: panel)
                continue
            }
            let fontSize: CGFloat = identifier == "panel-open-settings" ? 12 : 14
            let width = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
            XCTAssertGreaterThanOrEqual(control.frame.width + 1, width,
                "The full translated control label must fit its native frame")
        }
        try assertVisibleCopyBounds(in: panel, container: panel)
    }

    private func assertCopyBooleanCaption(_ caption: String, control: XCUIElement,
                                          identifier: String, in panel: XCUIElement) throws {
        // macOS exposes a Switch's knob and its visible caption as siblings.
        // Anchor the caption to the input's actual native parent, not a nearby
        // text element or the knob's intentionally narrower AX bounds.
        let owners = panel.descendants(matching: .group).allElementsBoundByIndex.filter {
            $0.children(matching: control.elementType).matching(
                NSPredicate(format: "identifier == %@", identifier)).count == 1
        }
        XCTAssertEqual(owners.count, 1, "The Boolean input must have one native caption owner")
        let owner = try XCTUnwrap(owners.first)
        let captions = owner.children(matching: .staticText).allElementsBoundByIndex.filter {
            [$0.label, $0.title, $0.value as? String ?? ""].contains(caption)
        }
        XCTAssertEqual(captions.count, 1, "The same native owner must expose the complete translated caption once")
        let text = try XCTUnwrap(captions.first)
        let textFrame = text.frame
        XCTAssertTrue(isLayoutFrame(owner.frame) && isLayoutFrame(textFrame))
        XCTAssertTrue(text.isHittable, "The Boolean caption must be visible beside its reachable native input")
        XCTAssertTrue(owner.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
        XCTAssertTrue(owner.frame.insetBy(dx: -1, dy: -1).contains(textFrame))
        XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(textFrame),
                      "The complete Boolean caption must fit the compact panel")
        XCTAssertLessThanOrEqual(textFrame.maxX, control.frame.minX,
                                 "The visible caption must not overlap the native knob")
        XCTAssertGreaterThanOrEqual(textFrame.minY, control.frame.minY - 1)
        XCTAssertLessThanOrEqual(textFrame.maxY, control.frame.maxY + 1,
                                 "The caption must belong to the same native input row")
        let width = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        XCTAssertGreaterThanOrEqual(textFrame.width + 1, width,
                                   "The complete translated Boolean caption must fit its native text frame")
    }

    private func assertVisibleCopyBounds(in content: XCUIElement, container: XCUIElement) throws {
        let viewport = content.frame
        for element in content.descendants(matching: .staticText).allElementsBoundByIndex {
            let frame = element.frame
            guard isLayoutFrame(frame), frame.intersects(viewport), frame.minY >= viewport.minY,
                  frame.maxY <= viewport.maxY else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, container.frame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, container.frame.maxX + 1,
                                     "Translated text must stay inside its native reading surface")
        }
    }

    func testPowerBatteryDetailsKoreanLight() throws {
        try verifyPowerBatteryMenu(language: "ko", appearance: "light")
    }

    func testPowerBatteryDetailsEnglishDark() throws {
        try verifyPowerBatteryMenu(language: "en", appearance: "dark")
    }

    private func verifyPowerBatteryMenu(language: String, appearance: String) throws {
        try launch(language: language, scenario: "power-charging", appearance: appearance)
        XCTAssertEqual(try state()["powerBatteryVisible"] as? Bool, false)
        try openMenu()
        try waitForState(["powerBatteryVisible": true])
        try required("panel-start-manual").click()
        try waitForState(["manual": true, "holding": true])
        let before = try state()
        XCTAssertEqual(before["powerBatterySimulated"] as? Bool, true)
        XCTAssertEqual(before["powerBatteryReads"] as? Int, 0)
        try assertDisclosureCollapsed(try disclosureTriangle("panel-power-details"))
        let summary = try required("panel-power-summary")
        let summaryText = [summary.label, summary.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(summaryText.contains(language == "ko" ? "충전 28 W" : "Charging 28 W"), summaryText)
        evidence("power-\(language)-\(appearance)-collapsed")
        try expandMenuDisclosure("panel-power-details")
        try assertDisclosureValue("panel-power-details", expanded: true)
        XCTAssertFalse(app.descendants(matching: .any)["panel-power-summary"].exists,
                       "An expanded detail must not repeat its summary wattage")
        let menu = try required(app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch,
                                description: "Native power details panel")
        for (id, value) in [("net-power", "28.0 W"), ("reported-adapter-power", "94 W"),
                            ("voltage-current", "12.5 V"), ("eta", language == "ko" ? "약 48분" : "About 48 min")] {
            let element = try required("panel-power-\(id)")
            let text = [element.label, element.title, element.value as? String ?? ""].joined(separator: " ")
            XCTAssertTrue(text.contains(value), "Missing distinct power reading \(id): \(text)")
            XCTAssertGreaterThan(element.frame.width, 0)
            XCTAssertGreaterThanOrEqual(element.frame.minX, menu.frame.minX - 1)
            XCTAssertLessThanOrEqual(element.frame.maxX, menu.frame.maxX + 1,
                                      "Translated rows must stay within the compact panel")
        }
        let scroll = menu.scrollViews.firstMatch
        if scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: -1000) }
        XCTAssertTrue(try required("panel-power-observed-at").isHittable)
        XCTAssertTrue(try required("panel-open-settings").isHittable)
        XCTAssertTrue(try required("panel-pause-all").isHittable)
        let after = try state()
        for key in ["automatic", "manual", "holding", "paused", "keepDisplayAwake"] {
            XCTAssertEqual(after[key] as? Bool, before[key] as? Bool,
                           "Inspecting power details must not modify \(key)")
        }
        XCTAssertEqual(after["manualRequestID"] as? String, before["manualRequestID"] as? String)
        XCTAssertEqual(after["manualContinuousDeadline"] as? Double, before["manualContinuousDeadline"] as? Double)
        XCTAssertEqual(after["powerBatteryReads"] as? Int, 0)
        evidence("power-\(language)-\(appearance)-expanded-scroll-end")
        app.typeKey(.escape, modifierFlags: [])
        try waitForState(["powerBatteryVisible": false])
    }

    func testPowerBatteryExceptionsAndDesktop() throws {
        let cases = [("requery", "Checking power information again."),
                     ("stale", "Reading from 35 sec ago"),
                     ("partial", "No charger-reported value"),
                     ("ac-discharging", "6.0 W")]
        for (scenario, expected) in cases {
            try launch(language: "en", scenario: "power-" + scenario, appearance: "light")
            try openMenu(); try expandMenuDisclosure("panel-power-details")
            // SwiftUI flattens a DisclosureGroup's content container in native AX.
            // Inspect the stable visible leaf/row, rather than a synthetic wrapper.
            let target = scenario == "partial" ? "panel-power-charger-note"
                : scenario == "ac-discharging" ? "panel-power-net-power" : "panel-power-freshness"
            let content = try required(target)
            let combined = [content.label, content.title, content.value as? String ?? ""].joined(separator: " ")
            XCTAssertTrue(combined.contains(expected), "Wrong exception copy: \(combined)")
            if ["requery", "stale", "partial"].contains(scenario) {
                XCTAssertFalse(app.descendants(matching: .any)["panel-power-net-power"].exists,
                               "Unavailable or invalidated readings must never become 0 W")
            }
            if scenario == "partial" {
                XCTAssertFalse(combined.contains("Not connected"), "Adapter query failure is not an unplug event")
            }
            evidence("power-exception-\(scenario)")
            app.terminate(); app = nil
        }
        try launch(language: "en", scenario: "desktop", appearance: "dark")
        try openMenu()
        XCTAssertFalse(app.descendants(matching: .any)["panel-power-details"].exists)
        XCTAssertEqual(try state()["powerBatteryReads"] as? Int, 0)
        evidence("power-details-omitted-on-desktop")
    }

    override func tearDownWithError() throws {
        if let app {
            // hasSucceeded is finalized after tearDown. Before that, a clean
            // running test can still report false; retain broad failure evidence
            // only when XCTest has actually recorded a failure or exception.
            if (testRun?.totalFailureCount ?? 0) > 0 { evidence("failure") }
            app.terminate()
        }
    }

    func testLightAppearanceMenuAndFourSettingsPages() throws {
        try launch(language: "ko", scenario: "ac", appearance: "light")
        let application = try XCTUnwrap(try state()["application"] as? [String: Any])
        XCTAssertEqual(application["effectiveAppearance"] as? String, NSAppearance.Name.aqua.rawValue,
                       "The isolated fixture must actually render Aqua without changing the system appearance")
        try openMenu()
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch,
                                 description: "Light appearance native menu panel")
        let controls = try ["panel-keep-display-awake", "manual-duration-picker", "panel-start-manual",
                            "panel-open-settings", "panel-more-actions"].map { try required($0) }
        var frames: [CGRect] = []
        for control in controls {
            XCTAssertTrue(control.isHittable && control.isEnabled,
                          "Light appearance must preserve usable \(control.identifier)")
            let frame = control.frame
            XCTAssertTrue(isLayoutFrame(frame), "Light menu controls need measured native bounds")
            XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(frame),
                          "Light menu controls must fit inside the actual panel")
            for earlier in frames {
                XCTAssertFalse(earlier.insetBy(dx: 1, dy: 1).intersects(frame.insetBy(dx: 1, dy: 1)),
                               "Independent light menu controls must not overlap")
            }
            frames.append(frame)
        }
        evidence("light-menu")
        try openSettingsFromMenu()
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Light appearance native Settings window")
        for (page, title) in settingsPageNames {
            try selectPage(page, title: title)
            try assertSettingsPageLayout(window, page: page, title: title)
            let application = try XCTUnwrap(try state()["application"] as? [String: Any])
            XCTAssertEqual(application["effectiveAppearance"] as? String, NSAppearance.Name.aqua.rawValue,
                           "Every Settings page must retain the isolated light appearance")
            evidence("light-settings-\(page)")
        }
    }

    func testAutomaticOnlyRestMenuTimeAndConditionTemplates() throws {
        try launch(language: "en", scenario: "ac")
        try openMenu()
        try required("panel-start-manual").click()
        try waitForState(["automatic": true, "manual": true, "holding": true])
        let original = try state()
        let requestID = try XCTUnwrap(original["manualRequestID"] as? String)
        let deadline = try XCTUnwrap(original["manualContinuousDeadline"] as? Double)
        try required("automatic-pause-menu").click()
        try required(app.menuItems["For 30 minutes"], description: "30 minute automatic-only rest").click()
        try waitForState(["automatic": true, "automaticActive": false,
                          "automaticPauseActive": true, "manual": true, "holding": true, "paused": false])
        try waitForManualDeadline(deadline, requestID: requestID)
        XCTAssertTrue(try required("automatic-pause-summary").exists)
        evidence("automatic-only-rest-manual-kept")
        try required("automatic-pause-resume").click()
        try waitForState(["automaticActive": true, "automaticPauseActive": false, "manual": true])
        try waitForManualDeadline(deadline, requestID: requestID)
        app.typeKey(.escape, modifierFlags: [])
        try openSettings()
        try selectPage("system", title: "General")
        let menuDisplay = try revealSettingsControl(try required("settings-menu-bar-display"))
        menuDisplay.click()
        try required(app.menuItems["Icon + time remaining"], description: "Menu bar remaining-time option").click()
        try waitForState(["menuBarDetails": true, "manual": true, "holding": true])
        evidence("remaining-time-option-settings")
        try selectPage("safety", title: "Power & Lid")
        try revealSettingsControl(try required("settings-automatic-rules"))
        let rules = try revealSettingsControl(try required("settings-automatic-rules"))
        XCTAssertTrue(rules.isEnabled, "The actual advanced-rules editor entry must be enabled")
        rules.click()
        try required("settings-automatic-rules-sheet")
        try required("automatic-template-workHours").click()
        XCTAssertTrue(try required("automatic-rules-apply").exists)
        try waitForManualDeadline(deadline, requestID: requestID)
        evidence("work-hours-template-draft")
        app.typeKey(.escape, modifierFlags: [])
        try waitForState(["automatic": true, "manual": true, "holding": true])
    }

    func testDisplayAwakeOptionUsesCurrentSessionAndReleasesOnStop() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        try selectPage("safety", title: "전원·덮개")
        let row = try revealSettingsControl(try required("keep-display-awake-toggle"))
        // AppKit checkboxes carry their own ID; a SwiftUI row can instead
        // expose its actual input as a child. Never click an arbitrary label.
        let toggle: XCUIElement
        if [.checkBox, .switch, .toggle].contains(row.elementType) { toggle = row }
        else {
            toggle = try required(row.descendants(matching: .any).matching(NSPredicate(
                format: "elementType == %d OR elementType == %d OR elementType == %d",
                XCUIElement.ElementType.checkBox.rawValue, XCUIElement.ElementType.switch.rawValue,
                XCUIElement.ElementType.toggle.rawValue)).firstMatch, description: "Actual display-awake toggle")
        }
        XCTAssertEqual(toggle.label, "화면 켜두기 허용")
        try revealSettingsControl(toggle)
        toggle.click()
        try waitForState(["keepDisplayAwake": true, "displayHolding": true, "holding": true])
        evidence("display-awake-native-settings")
        toggle.click()
        try waitForState(["keepDisplayAwake": false, "displayHolding": false, "holding": true])
        toggle.click()
        try waitForState(["displayHolding": true])
        try openMenu()
        try required("panel-pause-all").click()
        try waitForState(["keepDisplayAwake": true, "displayHolding": false, "holding": false])
        evidence("display-awake-released-after-pause")
    }

    func testEnglishSettingsNavigationAndCloseReopen() throws {
        try launch(language: "en", scenario: "ac")
        try verifySettings(language: "en", minimumSize: true)
    }

    func testCoreSettingsExcludeRetiredShortcuts() throws {
        try launch(language: "en", scenario: "ac")
        try openSettings()
        let window = try activateSettingsWindow()
        // The retired optional controls must not replace the core settings.
        let beforeResize = try settingsGeometry(after: Date().timeIntervalSince1970,
                                               description: "core-settings-before-minimum-width")
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let after = Date().timeIntervalSince1970
        edge.click(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: -600, dy: 0)))
        _ = try settingsGeometry(after: after, description: "core-settings-minimum-width") {
            abs($0.frame.width - $0.minimumFrame.width) <= 1
                && $0.frame.width < beforeResize.frame.width - 2
        }
        try selectPage("system", title: "General")
        XCTAssertFalse(window.descendants(matching: .any)["settings-shortcuts-details"].exists)
        XCTAssertEqual(window.popUpButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shortcut-key-")).count, 0)
        try selectPage("protection", title: "Protection & Diagnostics")
        try required("settings-other-app-requests-details")
        XCTAssertTrue(try required("settings-review-sleep-influences").exists)
        try selectPage("safety", title: "Power & Lid")
        XCTAssertTrue(try required("keep-display-awake-toggle").exists)
        XCTAssertTrue(try required("settings-lock-policy-note").exists)
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        try revealSettingsControl(try required("settings-automatic-rules"))
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        evidence("english-core-settings-minimum-width")
    }

    func testSettingsScrollKeepsHeadersFixedAcrossAllPages() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        let window = try activateSettingsWindow()
        let pages = [("safety", "전원·덮개", ["settings-unplug-details", "settings-closed-lid-display-details", "settings-power-scope-details"]),
                     ("general", "수동 유지", ["settings-manual-battery-details"]),
                     ("protection", "보호·진단", ["settings-work-rules-details",
                        "settings-records-diagnostics-details", "settings-usage-statistics-details"]),
                     ("system", "일반", ["settings-updates-details"])]
        for (page, title, disclosures) in pages {
            try selectPage(page, title: title)
            for identifier in disclosures { try expandSettingsDisclosure(identifier) }
            let scroll = try settingsPageScrollView()
            scroll.scroll(byDeltaX: 0, deltaY: 4000)
            let selectedTab = try navigationControl(page, title: title, activateWindow: false).row
            let initialNavigation = try settingsNavigationFrame()
            let initialHeading = selectedTab.frame
            let pageHeading = try required("settings-page-heading")
            XCTAssertTrue([pageHeading.label, pageHeading.title, pageHeading.value as? String ?? ""].contains(title),
                          "The fixed page heading must identify the selected page")
            let initialPageHeading = pageHeading.frame
            XCTAssertTrue(isLayoutFrame(initialPageHeading), "The fixed page heading needs measured native bounds")
            let anchor = scroll.staticTexts.firstMatch
            try required(anchor, description: "Readable content anchor on \(page)")
            let initialAnchor = anchor.frame
            let initialPosition = verticalScrollValue(scroll)
            try assertSettingsPageLayout(window, page: page, title: title)
            try headerScrollEvidence("scroll-\(page)-top", window: window,
                                     selectedTab: selectedTab, scroll: scroll, anchor: anchor)
            scroll.scroll(byDeltaX: 0, deltaY: -160)
            assertFixedFrame(try settingsNavigationFrame(), equals: initialNavigation, description: "\(page) sidebar at middle")
            assertFixedFrame(selectedTab.frame, equals: initialHeading, description: "\(page) selected native sidebar row at middle")
            assertFixedFrame(pageHeading.frame, equals: initialPageHeading, description: "\(page) fixed page heading at middle")
            try assertSettingsPageLayout(window, page: page, title: title)
            let middleAnchor = anchor.frame
            let middlePosition = verticalScrollValue(scroll)
            let contentMoved = middleAnchor != initialAnchor || middlePosition != initialPosition
            var bodyObservation: [String: Any] = ["page": page,
                "testName": self.name, "fixtureBundleIdentifier": bundleID,
                "fixtureExecutablePath": expectedExecutablePath,
                "readingViewportFrame": layoutFrame(scroll.frame),
                "initialAnchorFrame": layoutFrame(initialAnchor), "middleAnchorFrame": layoutFrame(middleAnchor),
                "initialScrollbarValue": initialPosition ?? "unavailable",
                "middleScrollbarValue": middlePosition ?? "unavailable",
                "scrollObserved": contentMoved,
                "coverage": contentMoved ? "scroll observed" : "unverified"]
            if !contentMoved {
                // A compact page may fit even after every available disclosure is expanded.
                // Accept that condition only after measuring every readable
                // text/control, not merely an unchanged first content anchor.
                bodyObservation["contentFitObservation"] = try measureSettingsContentFit(scroll)
                bodyObservation["coverage"] = "expanded content fits"
            } else {
                XCTAssertTrue(contentMoved,
                              "The expanded \(page) body must actually move; an unscrolled screenshot cannot verify the header")
            }
            let bodyData = try JSONSerialization.data(withJSONObject: bodyObservation, options: [.sortedKeys])
            let bodyAttachment = XCTAttachment(data: bodyData, uniformTypeIdentifier: "public.json")
            bodyAttachment.name = "scroll-\(page)-body-observation.json"
            bodyAttachment.lifetime = .keepAlways; add(bodyAttachment)
            try headerScrollEvidence("scroll-\(page)-middle", window: window,
                                     selectedTab: selectedTab, scroll: scroll, anchor: anchor)
            scroll.scroll(byDeltaX: 0, deltaY: -4000)
            assertFixedFrame(try settingsNavigationFrame(), equals: initialNavigation, description: "\(page) sidebar at end")
            assertFixedFrame(selectedTab.frame, equals: initialHeading, description: "\(page) selected native sidebar row at end")
            assertFixedFrame(pageHeading.frame, equals: initialPageHeading, description: "\(page) fixed page heading at end")
            try assertSettingsPageLayout(window, page: page, title: title)
            let endAnchor = anchor.frame
            let endPosition = verticalScrollValue(scroll)
            // Another down gesture must leave the endpoint unchanged. Capture
            // geometry plus actual native pixels for the separate bleed review.
            scroll.scroll(byDeltaX: 0, deltaY: -4000)
            XCTAssertEqual(anchor.frame, endAnchor, "The final screenshot must be at the stable content endpoint")
            XCTAssertEqual(verticalScrollValue(scroll), endPosition)
            try headerScrollEvidence("scroll-\(page)-end", window: window,
                                     selectedTab: selectedTab, scroll: scroll, anchor: anchor)
        }
    }

    func testSettingsDisclosureExpansionSurvivesNativeSidebarRoundtrips() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        let before = try state()
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Compact Settings window")
        // Power disconnection begins expanded. A sidebar round trip must retain
        // an intentional collapse without preventing a later native expansion.
        try selectPage("safety", title: "전원·덮개")
        let unplug = try revealSettingsControl(try disclosureTriangle("settings-unplug-details"))
        try assertDisclosureExpanded(unplug)
        try clickSettingsDisclosure(unplug, identifier: "settings-unplug-details")
        try assertDisclosureValue("settings-unplug-details", expanded: false)
        try selectPage("general", title: "수동 유지")
        try selectPage("safety", title: "전원·덮개")
        let retainedUnplug = try revealSettingsControl(try disclosureTriangle("settings-unplug-details"))
        try assertDisclosureCollapsed(retainedUnplug)
        evidence("settings-unplug-collapse-retained")
        try expandSettingsDisclosure("settings-unplug-details")
        try revealSettingsControl(try required("settings-unplug-policy-control"))
        let afterUnplug = try state()
        for key in ["automatic", "automaticActive", "manual", "holding", "paused", "keepDisplayAwake", "displayHolding"] {
            XCTAssertEqual(afterUnplug[key] as? Bool, before[key] as? Bool,
                           "Collapsing and reopening power-disconnection details must not change simulated \(key)")
        }
        XCTAssertEqual(afterUnplug["power"] as? String, before["power"] as? String)
        evidence("settings-unplug-reexpanded-power-unchanged")
        let pages = [("safety", "전원·덮개", "settings-power-scope-details"),
                     ("general", "수동 유지", "settings-manual-battery-details"),
                     ("protection", "보호·진단", "settings-records-diagnostics-details"),
                     ("system", "일반", "settings-updates-details")]
        for (page, title, identifier) in pages {
            try selectPage(page, title: title)
            try expandSettingsDisclosure(identifier)
            try assertSettingsPageLayout(window, page: page, title: title)
        }
        // Window-owned disclosure state must survive native sidebar actions,
        // regardless of whether the split view retains or recreates its content.
        for (page, title, identifier) in pages {
            try selectPage(page, title: title)
            let triangle = try revealSettingsControl(try disclosureTriangle(identifier))
            try assertDisclosureExpanded(triangle)
            try assertSettingsPageLayout(window, page: page, title: title)
            evidence("settings-\(page)-disclosure-retained")
        }
        // An intentional collapse must persist too; preserving state must not
        // become an unconditional expand-on-return behavior.
        try selectPage("protection", title: "보호·진단")
        let diagnostics = try revealSettingsControl(try disclosureTriangle("settings-records-diagnostics-details"))
        try clickSettingsDisclosure(diagnostics, identifier: "settings-records-diagnostics-details")
        try assertDisclosureValue("settings-records-diagnostics-details", expanded: false)
        try selectPage("general", title: "수동 유지")
        try selectPage("protection", title: "보호·진단")
        try assertDisclosureCollapsed(try disclosureTriangle("settings-records-diagnostics-details"))
        let after = try state()
        for key in ["automatic", "manual", "holding", "paused", "keepDisplayAwake", "displayHolding"] {
            XCTAssertEqual(after[key] as? Bool, before[key] as? Bool,
                           "Disclosure navigation must not change simulated \(key)")
        }
        XCTAssertEqual(after["power"] as? String, before["power"] as? String)
        evidence("settings-disclosure-collapse-retained-power-unchanged")
    }

    func testSettingsPointerOpeningClearsInitialFocusAndKeyboardReopenPreservesTarget() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        try waitForSettingsFocus(isWindow: true)
        evidence("settings-pointer-initial-focus")

        // Tab eligibility depends on the user's macOS keyboard-navigation setting.
        // Keep that setting unchanged and observe whichever responder Tab reaches.
        app.typeKey(.tab, modifierFlags: [])
        let target = try settingsFocusAfterFreshObservation()
        try waitForState(["automatic": true, "manual": false])
        evidence("settings-after-real-tab")
        app.typeKey(",", modifierFlags: .command)
        try nativeSettingsNavigationHost()
        try waitForSettingsFocus(isWindow: target.isWindow, className: target.className,
                                 identity: target.identity)
        evidence("settings-keyboard-reopen-retains-target")
    }

    func testKeyboardFirstSettingsOpeningAndDurationMenuSelection() throws {
        try launch(language: "en", scenario: "ac")
        app.activate()
        // Do not click a landing button or title bar before the first keyboard opening.
        app.typeKey(",", modifierFlags: .command)
        try nativeSettingsNavigationHost()
        let target = try settingsFocusAfterFreshObservation()
        app.typeKey(",", modifierFlags: .command)
        try waitForSettingsFocus(isWindow: target.isWindow, className: target.className,
                                 identity: target.identity)
        evidence("settings-first-keyboard-opening")

        // Resolve the real, enabled native Cell before giving it input. A
        // SwiftUI key-view proxy's private class name does not prove its role;
        // actual up/down selection must change both the row and page together.
        try navigationControl("safety", title: "Power & Lid").action.click()
        try assertSelectedSidebarPage("safety")
        var navigationTarget = try settingsFocusAfterFreshObservation()
        // Pointer selection and keyboard focus are independent on macOS. Reach
        // the actual native outline via Tab, without changing system settings.
        for reverse in [true, false] {
            for attempt in 0..<8 where navigationTarget.isSidebar != true {
                app.typeKey(.tab, modifierFlags: reverse ? .shift : [])
                navigationTarget = try settingsFocusAfterFreshObservation()
                let observation = XCTAttachment(string:
                    "reverse=\(reverse) attempt=\(attempt + 1) class=\(navigationTarget.className) "
                    + "identity=\(navigationTarget.identity) nativeSidebar=\(String(describing: navigationTarget.isSidebar))")
                observation.name = "settings-sidebar-public-focus-\(reverse)-\(attempt + 1)"
                observation.lifetime = .keepAlways
                add(observation)
            }
        }
        XCTAssertEqual(navigationTarget.isSidebar, true,
                       "Arrow input requires an observed native outline descendant, not a detail control")
        let pages = settingsPageNames.map(\.page)
        var position = 0
        // Visit all four pages in both directions, with no endpoint wrap assumption.
        for delta in [1, 1, 1, -1, -1, -1] {
            let beforeInput = try settingsFocusAfterFreshObservation()
            XCTAssertEqual(beforeInput.isSidebar, true,
                           "Keyboard movement must remain in the observed native sidebar")
            app.typeKey(delta > 0 ? .downArrow : .upArrow, modifierFlags: [])
            position += delta
            XCTAssertTrue(pages.indices.contains(position), "The keyboard path must stay inside sidebar bounds")
            try assertSelectedSidebarPage(pages[position])
        }
        evidence("settings-sidebar-real-keyboard-selection")

        // Tab into the actual detail controls. Stop at the public AppKit popup
        // role, then prove its identity by opening the known unplug-policy menu.
        // This keeps the search bounded without classifying every KeyViewProxy
        // as either a sidebar or a detail control.
        var detailTarget = try settingsFocusAfterFreshObservation()
        for attempt in 0..<8 {
            app.typeKey(.tab, modifierFlags: [])
            detailTarget = try settingsFocusAfterFreshObservation()
            let observation = XCTAttachment(string:
                "attempt=\(attempt + 1) isWindow=\(detailTarget.isWindow) "
                + "class=\(detailTarget.className) identity=\(detailTarget.identity)")
            observation.name = "settings-sidebar-tab-to-detail-\(attempt + 1)"
            observation.lifetime = .keepAlways
            add(observation)
            if detailTarget.className == "NSPopUpButton" { break }
        }
        XCTAssertFalse(detailTarget.isWindow, "Tab from the sidebar must reach a usable detail control")
        XCTAssertEqual(detailTarget.className, "NSPopUpButton",
                       "The bounded Tab path must reach the actual native detail popup")
        XCTAssertNotEqual(detailTarget.identity, navigationTarget.identity,
                          "Entering detail must move to a different actual keyboard target")
        try assertSelectedSidebarPage("safety")
        let unplug = try required("settings-unplug-policy-control")
        XCTAssertEqual(unplug.elementType, .popUpButton)
        XCTAssertTrue(unplug.isEnabled && unplug.isHittable)
        XCTAssertTrue(try settingsPageScrollView().frame.insetBy(dx: -1, dy: -1).contains(unplug.frame),
                      "The complete keyboard-target popup must fit inside the current detail viewport")
        let savedUnplugChoice = unplug.value as? String
        app.typeKey(" ", modifierFlags: [])
        let unplugChoice = try required(app.menuItems["End all · Recommended"],
                                       description: "Keyboard-opened unplug policy menu")
        XCTAssertTrue(unplugChoice.isHittable, "Keyboard detail entry must open the actual unplug choices")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(unplugChoice.waitForNonExistence(timeout: 3), "Escape must dismiss the actual detail popup menu")
        XCTAssertEqual(unplug.value as? String, savedUnplugChoice,
                       "Inspecting the keyboard target must not change the saved unplug policy")
        try assertSelectedSidebarPage("safety")
        evidence("settings-sidebar-tab-enters-detail")

        let settings = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                    description: "Keyboard-opened Settings window")
        try required(settings.buttons[XCUIIdentifierCloseWindow], description: "Settings close button").click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        try openMenu()
        let picker = try required("manual-duration-picker")
        picker.click()
        try durationMenuItem("30 min", in: durationMenu(for: picker)).click()
        waitForSelectedManualMinutes(30)
        picker.click()
        let menu = try durationMenu(for: picker)
        try durationMenuItem("30 min", in: menu)
        menu.typeKey(.downArrow, modifierFlags: [])
        menu.typeKey(.return, modifierFlags: [])
        waitForSelectedManualMinutes(60)
        try waitForState(["automatic": true, "manual": false])
        picker.click()
        let reopened = try durationMenu(for: picker)
        try durationMenuItem("1 h", in: reopened)
        reopened.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 3), "Escape must close the focused native menu")
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        evidence("duration-real-keyboard-selection-and-escape")
    }

    func testKoreanScreenGalleryAndSecondaryFlows() throws {
        try launch(language: "ko", scenario: "ac")
        try openMenu()
        let initialPicker = try required("manual-duration-picker")
        initialPicker.click()
        let initialPresetMenu = try durationMenu(for: initialPicker)
        try durationMenuItem("30분", in: initialPresetMenu).click()
        XCTAssertTrue(initialPresetMenu.waitForNonExistence(timeout: 3),
                      "Selecting a duration must end its actual native tracking menu before querying footer actions")
        try verifyDisconnectSummary(containing: "macOS", evidenceName: "gallery-unplug-os-delegation")
        evidence("gallery-menu-automatic")
        try setAutomatic(false)
        try waitForState(["automatic": false, "manual": false, "holding": false])
        evidence("gallery-menu-off")
        try required("panel-start-manual").click()
        try waitForState(["automatic": false, "manual": true, "holding": true])
        if !app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch.exists {
            try openMenu()
        }
        XCTAssertEqual(try required("panel-end-manual").label, "수동 유지 종료")
        evidence("gallery-menu-manual")
        try required("panel-end-manual").click()
        let picker = try required("manual-duration-picker")
        picker.click()
        let presetMenu = try assertDurationMenuOptions(["30분", "1시간", "2시간", "종료할 때까지"],
                                                       in: durationMenu(for: picker))
        let firstPreset = try durationMenuItem("30분", in: presetMenu)
        waitForHittable(firstPreset, description: "Open Korean duration preset")
        try transientMenuEvidence(presetMenu, name: "gallery-menu-duration-presets")
        firstPreset.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(presetMenu.waitForNonExistence(timeout: 3), "Escape must dismiss the actual preset menu")
        XCTAssertTrue(firstPreset.waitForNonExistence(timeout: 3), "The dismissed preset item must leave the AX tree")
        evidence("gallery-menu-duration-presets-dismissed")
        try setAutomatic(true)
        try openSettingsFromMenu()
        try selectPage("general", title: "수동 유지")
        let general = try required("settings-page-general")
        XCTAssertFalse(general.descendants(matching: .any)["settings-manual-duration-picker"].exists,
                       "Manual duration selection must live only in the menu bar")
        XCTAssertFalse(general.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR title == %@", "유지 시간", "유지 시간")).firstMatch.exists,
            "General settings must not retain the manual duration row")
        evidence("gallery-settings-general")
        try selectPage("safety", title: "전원·덮개")
        XCTAssertFalse(app.descendants(matching: .any)["closed-lid-disconnect-picker"].exists,
                       "The unplug action is hidden while closed-lid work is off")
        evidence("gallery-settings-safety")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        try revealSettingsControl(try required("settings-automatic-rules"))
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-rehearsal"].exists)
        evidence("gallery-settings-safety-details")
        try selectPage("system", title: "일반")
        try expandSettingsDisclosure("settings-notifications-details")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Notification choices live inline in General")
        try required(app.checkBoxes["수동 유지 시간 만료 알림"], description: "Independent manual expiry notification")
        try required(app.checkBoxes["만료 전 예고"], description: "Optional expiry warning")
        try required(app.checkBoxes["과열·상태 확인 실패"], description: "Thermal and observation protection alerts")
        try required(app.checkBoxes["배터리 부족"], description: "Battery protection alerts")
        XCTAssertFalse(app.buttons["Tether 사용법…"].exists, "The separate guide button must be removed")
        let notifications = try revealSettingsControl(try disclosureTriangle("settings-notifications-details"))
        try clickSettingsDisclosure(notifications, identifier: "settings-notifications-details")
        try assertDisclosureValue("settings-notifications-details", expanded: false)
        evidence("gallery-settings-system")
        try expandSettingsDisclosure("settings-updates-details")
        evidence("gallery-settings-system-details")
        try selectPage("safety", title: "전원·덮개")
        try revealSettingsControl(try required("settings-helper-manage")).click()
        try required("settings-helper-sheet")
        try expandSettingsDisclosure("settings-helper-details")
        evidence("gallery-settings-safety-helper")
        try required("settings-helper-back").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        try selectPage("protection", title: "보호·진단")
        try expandSettingsDisclosure("settings-records-diagnostics-details")
        try required("settings-other-app-requests-details")
        let review = try required(app.buttons["settings-review-sleep-influences"], description: "Sleep influences button")
        XCTAssertTrue([review.label, review.title].contains("다른 앱의 잠자기 방지 요청 확인"),
                      "The compact Review action must retain its full accessible purpose")
        let scroll = try settingsPageScrollView()
        for _ in 0..<4 where !review.isHittable {
            XCTAssertTrue(scroll.exists, "Lower settings must have a native scroll view")
            scroll.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(review.isHittable)
        evidence("gallery-settings-protection-details")
        review.click()
        try required(app.staticTexts["앱·시스템 절전 영향"], description: "Sleep influences sheet title")
        evidence("gallery-sleep-influences")
        try required(app.buttons["닫기"], description: "Sleep influences close button").click()
        try waitForState(["automatic": true, "manual": false, "holding": true])
    }

    func testKoreanSettingsNavigationAtMinimumSizeAndCloseReopen() throws {
        try launch(language: "ko", scenario: "longError")
        try verifySettings(language: "ko", minimumSize: true)
    }

    func testSleepInfluencesPointerOpeningClearsOnlyInitialFocus() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        try selectPage("protection", title: "보호·진단")
        try required("settings-other-app-requests-details")
        let review = try required(app.buttons["settings-review-sleep-influences"], description: "Sleep influences button")
        XCTAssertTrue([review.label, review.title].contains("다른 앱의 잠자기 방지 요청 확인"),
                      "The compact Review action must retain its full accessible purpose")
        let scroll = try settingsPageScrollView()
        for _ in 0..<4 where !review.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -240) }
        waitForHittable(review, description: "Sleep influences button")
        let pointerOpened = Date().timeIntervalSince1970
        review.click()
        let settings = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                    description: "Settings hosting the review sheet")
        let sheet = try required(settings.sheets.firstMatch, description: "Sleep influences sheet")
        _ = try activityReviewFocus(after: pointerOpened) { $0["firstResponderIsWindow"] as? Bool == true }
        evidence("sleep-influences-pointer-no-initial-ring")

        // Tab behavior follows the existing macOS keyboard-navigation preference.
        // Observe its actual target rather than assuming every button is eligible.
        let typedAt = Date().timeIntervalSince1970
        app.typeKey(.tab, modifierFlags: [])
        let target = try activityReviewFocus(after: typedAt)
        let targetIdentity = try XCTUnwrap(target["firstResponderIdentity"] as? String)
        let targetClass = try XCTUnwrap(target["firstResponderClass"] as? String)
        app.activate()
        let reobservedAt = Date().timeIntervalSince1970
        _ = try activityReviewFocus(after: reobservedAt) {
            $0["firstResponderIdentity"] as? String == targetIdentity
                && $0["firstResponderClass"] as? String == targetClass
        }
        evidence("sleep-influences-later-keyboard-focus-preserved")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3), "Escape must dismiss the review sheet")

        // Initial keyboard/unknown presentation is verified by the AppKit
        // responder-lifecycle tests. This native case exercises shipping pointer
        // entry, subsequent real keyboard input, Escape and a fresh presentation.
        // A later pointer presentation needs a fresh one-shot owner; retaining
        // the previous sheet's handled state must not leave a new automatic ring.
        let pointerReopened = Date().timeIntervalSince1970
        review.click()
        let reopenedSheet = try required(settings.sheets.firstMatch, description: "Pointer-reopened review sheet")
        _ = try activityReviewFocus(after: pointerReopened) { $0["firstResponderIsWindow"] as? Bool == true }
        evidence("sleep-influences-pointer-reopen-no-initial-ring")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reopenedSheet.waitForNonExistence(timeout: 3))
        try waitForState(["automatic": true, "manual": false, "holding": true])
    }

    func testWelcomeKeepsCompactIndependentChoicesAndFixedCompletion() throws {
        try launch(language: "ko", scenario: "ac")
        let openedAt = Date().timeIntervalSince1970
        try required("ui-fixture-open-welcome").click()
        try required("welcome-content")
        var welcomeObservation: [String: Any]?
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(),
                  let observedAt = current["observedAt"] as? Double, observedAt > openedAt,
                  let window = current["welcomeWindow"] as? [String: Any],
                  window["identifier"] as? String == "tether-welcome-window",
                  window["visible"] as? Bool == true, window["key"] as? Bool == true else { return false }
            welcomeObservation = window
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 5), .completed,
                       "The visible Welcome window needs a fresh native geometry observation")
        let observation = try XCTUnwrap(welcomeObservation)
        let minimum = try XCTUnwrap(observation["contentMinSize"] as? [String: Any])
        // A full-size content view includes titlebar chrome in contentRect.
        // contentLayoutRect is the actual 560×448 reading/control surface.
        let frame = try XCTUnwrap(observation["contentLayoutRect"] as? [String: Any])
        let outerContent = try XCTUnwrap(observation["contentRect"] as? [String: Any])
        XCTAssertEqual(minimum["width"] as? Double ?? 0, 560, accuracy: 1)
        XCTAssertEqual(frame["width"] as? Double ?? 0, 560, accuracy: 1)
        XCTAssertEqual(frame["height"] as? Double ?? 0, 448, accuracy: 1)
        XCTAssertGreaterThanOrEqual(outerContent["width"] as? Double ?? 0, 560)
        XCTAssertGreaterThanOrEqual(outerContent["height"] as? Double ?? 0, 448)
        XCTAssertEqual(observation["isResizable"] as? Bool, false)
        XCTAssertTrue(try required("welcome-automatic-toggle").exists)
        XCTAssertTrue(try required("welcome-closed-lid-toggle").exists)
        XCTAssertTrue(try required("welcome-confirm-choices").isHittable)
        XCTAssertTrue(try required("welcome-confirm-choices").isEnabled,
                      "General work with closed-lid work off must not require an unused helper")
        evidence("welcome-native-independent-choices")
    }

    func testDiagnosticsPrioritizesAppsAndHistoryHasNoNestedScroll() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        try selectPage("protection", title: "보호·진단")
        try expandSettingsDisclosure("settings-records-diagnostics-details")
        let recent = try required("recent-activity-disclosure")
        let triangle = recent.elementType == .disclosureTriangle ? recent
            : recent.descendants(matching: .disclosureTriangle).firstMatch
        try revealSettingsControl(try required(triangle, description: "Recent activity disclosure triangle"))
        // Native grouped Form disclosure bounds include a leading inset. The label's
        // center does not toggle this control; click the visible arrow verified on screen.
        triangle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 26, dy: 0)).click()
        try assertDisclosureExpanded(triangle)
        let list = try required("recent-activity-list")
        XCTAssertEqual(list.descendants(matching: .scrollView).count, 0,
                       "Short history must use the Settings scroll, not its own clipped viewport")
        let rows = list.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recent-activity-common-"))
        XCTAssertEqual(rows.count, 2, "The initial AC fixture must preserve both observed records")
        let last = rows.element(boundBy: 1)
        try revealSettingsControl(last)
        let first = rows.element(boundBy: 0)
        XCTAssertGreaterThan(first.frame.height, 0)
        XCTAssertGreaterThan(last.frame.height, 0)
        XCTAssertGreaterThanOrEqual(first.frame.minY, list.frame.minY - 1)
        XCTAssertGreaterThanOrEqual(last.frame.minY, first.frame.maxY - 1,
                                    "Complete history rows must not overlap")
        XCTAssertLessThanOrEqual(last.frame.maxY, list.frame.maxY + 1)
        evidence("history-natural-height")
        try required("settings-other-app-requests-details")
        let review = try required(app.buttons["settings-review-sleep-influences"], description: "Sleep influences button")
        XCTAssertTrue([review.label, review.title].contains("다른 앱의 잠자기 방지 요청 확인"),
                      "The compact Review action must retain its full accessible purpose")
        try activateSettingsWindow()
        try revealSettingsControl(review)
        XCTAssertTrue(review.isHittable)
        review.click()
        try required("sleep-influences-conclusion")
        let request = try required("sleep-request-204")
        let refresh = try required("sleep-influences-refresh")
        XCTAssertLessThan(request.frame.maxY, refresh.frame.minY,
                          "The first actual request and its actions must fit above the persistent footer")
        XCTAssertTrue(app.buttons["Amphetamine 열기"].exists)
        let installed = try required("sleep-influences-installed-apps")
        let installedTriangle = installed.elementType == .disclosureTriangle ? installed
            : installed.descendants(matching: .disclosureTriangle).firstMatch
        let body = try required("sleep-influences-content")
        let viewport = body.frame.insetBy(dx: 0, dy: 8)
        // Native disclosure AX bounds include a leading inset outside the drawn
        // arrow. Check its vertical viewport position, then hit the visible arrow.
        for _ in 0..<5 where installedTriangle.frame.minY < viewport.minY
            || installedTriangle.frame.maxY > viewport.maxY {
            body.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertGreaterThanOrEqual(installedTriangle.frame.minY, viewport.minY)
        XCTAssertLessThanOrEqual(installedTriangle.frame.maxY, viewport.maxY,
                                 "The disclosure must be above the fixed footer")
        XCTAssertTrue(installedTriangle.isHittable)
        installedTriangle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 26, dy: 0)).click()
        try assertDisclosureExpanded(installedTriangle)
        let installedRows = installed.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sleep-installed-"))
        XCTAssertEqual(installedRows.count, 1,
                       "Only the install-only Keepresso fixture belongs in the additional-apps section")
        evidence("diagnostics-apps-first")
        try required(app.buttons["닫기"], description: "Close sleep influences").click()
        let logs = try disclosureTriangle("settings-records-diagnostics-details")
        // Returning from the influences modal must preserve the section the user
        // already opened, including its future recording and past report actions.
        try assertDisclosureExpanded(logs)
        XCTAssertTrue(app.staticTexts["문제 재현 기록"].exists)
        XCTAssertTrue(app.staticTexts["앞으로 기록할 시간"].exists)
        XCTAssertTrue(app.staticTexts["문제 보고서"].exists)
        XCTAssertEqual(try required("diagnostic-report-range").label, "과거 기록 범위",
                       "The report picker must describe past records without a duplicate accessibility label")
        let report = try required(app.buttons["보고서 저장…"], description: "Save report")
        try revealSettingsControl(report)
        evidence("logs-future-recording-past-report")
    }

    func testActiveRecordingRemainsVisibleOutsideCollapsedDiagnostics() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        try selectPage("protection", title: "보호·진단")
        let before = try state()
        XCTAssertEqual(before["recordingActive"] as? Bool, false)
        XCTAssertTrue(before["recordingUntil"] is NSNull)
        var originalRecordingDeadline: Double?

        func assertPowerUnchanged() throws {
            let current = try state()
            for key in ["automatic", "manual", "holding", "paused", "keepDisplayAwake", "displayHolding"] {
                XCTAssertEqual(current[key] as? Bool, before[key] as? Bool,
                    "Diagnostic recording must not change simulated \(key)")
            }
            for key in ["power", "powerCondition"] {
                XCTAssertEqual(current[key] as? String, before[key] as? String)
            }
            for key in ["thermal", "selectedManualMinutes"] {
                XCTAssertEqual(current[key] as? Int, before[key] as? Int)
            }
        }

        func assertActiveRecording() throws -> String {
            let status = try required("diagnostic-recording-status")
            let stop = try required("diagnostic-recording-stop")
            try revealSettingsControl(stop)
            XCTAssertTrue(stop.isEnabled, "The marked memory-only fixture must enable actual Stop")
            XCTAssertTrue(status.isHittable, "Current recording status must remain visible outside details")
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@", "diagnostic-recording-status")).count, 1,
                "Expanded details must not duplicate the current recording summary")
            XCTAssertEqual(app.buttons.matching(NSPredicate(
                format: "identifier == %@", "diagnostic-recording-stop")).count, 1,
                "Expanded details must not duplicate the current Stop action")
            let deadline = try required(status.descendants(matching: .staticText).matching(NSPredicate(
                format: "label ENDSWITH %@ OR title ENDSWITH %@ OR value ENDSWITH %@",
                "까지 기록 중", "까지 기록 중", "까지 기록 중")).firstMatch,
                description: "Current recording deadline")
            let detail = deadline.label.isEmpty ? deadline.value as? String ?? deadline.title : deadline.label
            XCTAssertTrue(deadline.isHittable, "The current end time must be visible alongside Stop")
            XCTAssertTrue(detail.contains(":"), "Timed recording must expose a clock deadline")
            XCTAssertFalse(detail.contains("직접 끝낼 때까지"), "New recording must have a finite deadline")
            let current = try state()
            XCTAssertEqual(current["recordingActive"] as? Bool, true)
            let until = try XCTUnwrap(current["recordingUntil"] as? Double,
                "The private fixture must expose the actual memory recording deadline")
            XCTAssertGreaterThan(until, Date().timeIntervalSince1970)
            if let originalRecordingDeadline {
                XCTAssertEqual(until, originalRecordingDeadline, accuracy: 0.001,
                    "Visual navigation must not restart the memory recording deadline")
            } else { originalRecordingDeadline = until }
            try assertPowerUnchanged()
            return detail
        }

        XCTAssertFalse(app.descendants(matching: .any)["diagnostic-recording-status"].firstMatch.exists)
        try expandSettingsDisclosure("settings-records-diagnostics-details")
        for identifier in ["diagnostic-report-save", "diagnostic-report-copy", "diagnostic-report-range",
                           "diagnostic-recording-duration"] {
            XCTAssertFalse(try required(identifier).isEnabled,
                "The recording exception must not enable \(identifier) in the render-only fixture")
        }
        XCTAssertFalse(try required(app.buttons["문제 발생 시점 표시"], description: "Diagnostic marker").isEnabled)
        let start = try required("diagnostic-recording-start")
        try revealSettingsControl(start)
        XCTAssertTrue(start.isEnabled, "The marked memory-only fixture must enable actual Start")
        start.click()
        try waitForState(["recordingActive": true])
        let deadline = try assertActiveRecording()
        evidence("recording-active-details-expanded")

        let diagnostics = try disclosureTriangle("settings-records-diagnostics-details")
        try assertDisclosureExpanded(diagnostics)
        try revealSettingsControl(diagnostics)
        diagnostics.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 26, dy: 0)).click()
        try assertDisclosureValue("settings-records-diagnostics-details", expanded: false)
        XCTAssertEqual(try assertActiveRecording(), deadline,
            "Collapsing diagnostics must retain the original visible deadline")
        evidence("recording-active-details-collapsed")

        try selectPage("general", title: "수동 유지")
        try selectPage("protection", title: "보호·진단")
        try assertDisclosureCollapsed(try disclosureTriangle("settings-records-diagnostics-details"))
        XCTAssertEqual(try assertActiveRecording(), deadline,
            "Page recreation must not hide current recording or restart its deadline")
        evidence("recording-active-after-page-roundtrip")

        let stop = try revealSettingsControl(try required("diagnostic-recording-stop"))
        XCTAssertTrue(stop.isEnabled, "Stop must remain enabled after the page roundtrip")
        stop.click()
        try waitForState(["recordingActive": false])
        XCTAssertTrue(try state()["recordingUntil"] is NSNull,
            "Actual Stop must clear the memory recording deadline")
        XCTAssertTrue(app.descendants(matching: .any)["diagnostic-recording-status"].firstMatch
            .waitForNonExistence(timeout: 3), "Actual Stop must remove the active status row")
        XCTAssertTrue(app.buttons["diagnostic-recording-stop"].waitForNonExistence(timeout: 3))
        try assertPowerUnchanged()
        try expandSettingsDisclosure("settings-records-diagnostics-details")
        XCTAssertTrue(try revealSettingsControl(try required("diagnostic-recording-start")).isHittable,
            "Inactive recording must restore the original Start control in details")
        XCTAssertFalse(app.buttons["diagnostic-recording-stop"].exists)
        evidence("recording-stopped-power-unchanged")
    }

    func testWelcomeInspectionDoesNotApplySavedChoicesOrStartWork() throws {
        try launch(language: "en", scenario: "ac")
        let before = try state()
        try required("ui-fixture-open-welcome").click()
        let content = try required("welcome-content")
        let done = try required("welcome-confirm-choices")
        XCTAssertTrue(done.isEnabled, "A general-only choice can finish without the closed-lid helper")

        func choice(_ identifier: String) throws -> XCUIElement {
            let row = try required(identifier)
            if [.checkBox, .switch, .toggle].contains(row.elementType) { return row }
            return try required(row.descendants(matching: .any).matching(NSPredicate(
                format: "elementType == %d OR elementType == %d OR elementType == %d",
                XCUIElement.ElementType.checkBox.rawValue, XCUIElement.ElementType.switch.rawValue,
                XCUIElement.ElementType.toggle.rawValue)).firstMatch,
                description: "Actual welcome choice \(identifier)")
        }

        func assertWorkUnchanged(after timestamp: Double) throws {
            var current: [String: Any]?
            let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                guard let value = observedState(), let observedAt = value["observedAt"] as? Double,
                      observedAt > timestamp else { return false }
                current = value; return true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 5), .completed,
                           "Draft inspection needs a fresh work observation")
            let after = try XCTUnwrap(current)
            for key in ["automatic", "manual", "holding", "paused", "canStartManual"] {
                XCTAssertEqual(after[key] as? Bool, before[key] as? Bool,
                               "Reviewing welcome choices must not apply saved work state \(key)")
            }
        }

        let automatic = try choice("welcome-automatic-toggle")
        let closedLid = try choice("welcome-closed-lid-toggle")
        XCTAssertTrue(automatic.isEnabled && closedLid.isEnabled)
        var changedAt = Date().timeIntervalSince1970
        automatic.click()
        try assertWorkUnchanged(after: changedAt)
        changedAt = Date().timeIntervalSince1970
        closedLid.click()
        XCTAssertFalse(done.isEnabled, "Selected closed-lid work still requires a prepared helper")
        XCTAssertTrue(content.exists, "An unprepared closed-lid choice must remain in setup")
        XCTAssertTrue(app.staticTexts["Required for closed-lid work"].exists,
                      "The selected option must explain its mandatory helper requirement")
        try assertWorkUnchanged(after: changedAt)
        evidence("welcome-selected-lid-unprepared-no-implicit-apply")

        changedAt = Date().timeIntervalSince1970
        closedLid.click()
        XCTAssertTrue(done.isEnabled, "Turning the unused lid choice off restores general-only completion")
        automatic.click()
        try assertWorkUnchanged(after: changedAt)
        evidence("welcome-general-choices-inspected-work-preserved")
        changedAt = Date().timeIntervalSince1970
        done.click()
        XCTAssertTrue(content.waitForNonExistence(timeout: 3), "General-only setup must actually finish without a helper")
        try assertWorkUnchanged(after: changedAt)
        evidence("welcome-general-finished-existing-work-preserved")
    }

    func testActualMenuManualAutomaticAndPauseTransitions() throws {
        try launch(language: "en", scenario: "ac")
        try openMenu()
        try expandMenuDisclosure("panel-closed-lid-policy")
        let automatic = try required("panel-automatic")
        XCTAssertEqual(automatic.label, "Allow automatic starts")
        XCTAssertEqual(try required("panel-allow-closed-lid").label, "Allow closed-lid use")
        XCTAssertEqual(try required("panel-keep-display-awake").label, "Allow display keep-awake")
        XCTAssertTrue(automatic.elementType == .switch || automatic.elementType == .checkBox,
                      "Automatic starts must expose a native Boolean control")
        XCTAssertTrue(automatic.isEnabled && automatic.isHittable,
                      "The automatic switch must remain enabled and reachable")
        XCTAssertTrue(isLayoutFrame(automatic.frame), "The switch needs measured native bounds")
        XCTAssertGreaterThanOrEqual(automatic.frame.height, 20)
        let automaticPanel = try required(app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch,
                                          description: "Menu panel containing the automatic switch")
        XCTAssertTrue(automaticPanel.frame.insetBy(dx: -1, dy: -1).contains(automatic.frame))
        // Native Switch owns its label in the accessibility tree. Do not
        // require a duplicate static-text element that macOS does not expose.
        try collapseMenuDisclosure("panel-closed-lid-policy")
        try setAutomatic(false)
        try waitForState(["automatic": false, "manual": false, "holding": false])

        let start = try required("panel-start-manual")
        XCTAssertEqual(start.label, "Start manually")
        XCTAssertTrue(start.isEnabled)
        XCTAssertGreaterThanOrEqual(start.frame.height, 24)
        let picker = try required("manual-duration-picker")
        XCTAssertTrue(picker.isHittable && picker.isEnabled)
        XCTAssertTrue(picker.frame.minY < start.frame.maxY && start.frame.minY < picker.frame.maxY,
                      "The inactive duration picker and Start must share one compact row")
        XCTAssertFalse(picker.frame.intersects(start.frame), "Compact duration and Start controls must not overlap")
        start.click()
        try waitForState(["automatic": false, "manual": true, "holding": true])
        let end = try required("panel-end-manual")
        XCTAssertEqual(end.label, "End manual")
        XCTAssertFalse(app.descendants(matching: .any)["manual-duration-picker"].firstMatch.isHittable,
                       "Presets must not appear during an active timer")
        let activeDetails = try disclosureTriangle("panel-closed-lid-policy")
        try assertDisclosureCollapsed(activeDetails)
        let beforeReadingDetails = try state()
        try expandMenuDisclosure("panel-closed-lid-policy")
        let afterReadingDetails = try state()
        for key in ["automatic", "manual", "holding", "paused"] {
            XCTAssertEqual(afterReadingDetails[key] as? Bool, beforeReadingDetails[key] as? Bool,
                           "Reading active work must not change simulated \(key)")
        }
        XCTAssertEqual(afterReadingDetails["manualRequestID"] as? String,
                       beforeReadingDetails["manualRequestID"] as? String)
        XCTAssertEqual(afterReadingDetails["manualContinuousDeadline"] as? Double,
                       beforeReadingDetails["manualContinuousDeadline"] as? Double,
                       "Expanding the work list must not restart the current timer")
        XCTAssertFalse(app.descendants(matching: .any)["panel-extend-manual-15"].exists,
                       "The compact active timer exposes only its single 30-minute extension")
        XCTAssertTrue(try required("panel-extend-manual-30").exists)
        let started = try state()
        let requestID = try XCTUnwrap(started["manualRequestID"] as? String)
        var deadline = try XCTUnwrap(started["manualContinuousDeadline"] as? Double)
        for minutes in [30] {
            let buttons = app.buttons.matching(identifier: "panel-extend-manual-\(minutes)")
            XCTAssertEqual(buttons.count, 1, "Each extension button needs its own native identifier")
            let button = try required(buttons.firstMatch, description: "Explicit +\(minutes) extension")
            XCTAssertTrue(button.isEnabled && button.isHittable)
            button.click()
            deadline += Double(minutes * 60)
            try waitForManualDeadline(deadline, requestID: requestID)
            XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 30,
                           "Extending current work must not change the next-session choice")
        }
        evidence("manual-explicit-extensions-confirmed")
        try required("panel-more-actions").click()
        XCTAssertFalse(app.descendants(matching: .any)["panel-next-manual-duration"].exists,
                       "More must not expose a second duration choice while a timer runs")
        app.typeKey(.escape, modifierFlags: [])
        try waitForState(["manual": true, "holding": true])
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 30)
        try waitForManualDeadline(deadline, requestID: requestID)
        try setAutomatic(true)
        try waitForState(["automatic": true, "manual": true, "holding": true])
        end.click()
        try waitForState(["automatic": true, "manual": false, "holding": true])

        try required("panel-start-manual").click()
        try waitForState(["automatic": true, "manual": true])
        try required("panel-pause-all").click()
        try waitForState(["manual": false, "holding": false, "paused": true])
        evidence("manual-automatic-pause")
        XCTAssertEqual(try required("panel-pause-all").label, "Resume")
        try required("panel-pause-all").click()
        try waitForState(["automatic": true, "manual": false, "paused": false])
        try setAutomatic(false)
        try required("panel-start-manual").click()
        try waitForState(["automatic": false, "manual": true])
        try required("panel-pause-all").click()
        try waitForState(["automatic": false, "manual": false, "paused": true])
        try required("panel-pause-all").click()
        try waitForState(["automatic": false, "manual": false, "holding": false, "paused": false])
        evidence("manual-only-resume-does-not-enable-automatic")
    }

    func testBatterySavedAutomaticWaitsAndManualEndEndsOnlyManualReason() throws {
        try launch(language: "en", scenario: "battery")
        try openMenu()
        try setAutomatic(true)
        try waitForState(["automatic": true, "manual": false, "holding": false])
        XCTAssertFalse(app.descendants(matching: .any)["panel-automatic-countdown"].exists)
        try required("panel-start-manual").click()
        try waitForState(["automatic": true, "manual": true, "holding": true])
        XCTAssertTrue(try required("panel-manual-countdown").isHittable)
        XCTAssertTrue(try required("panel-end-manual").isHittable)
        try required("panel-end-manual").click()
        try waitForState(["automatic": true, "manual": false, "holding": false])
        XCTAssertFalse(app.descendants(matching: .any)["panel-manual-countdown"].exists)
        evidence("battery-manual-and-saved-ac-automatic")

        try expandMenuDisclosure("panel-closed-lid-policy")
        let unplugPolicy = try required("panel-unplug-policy-summary")
        try revealMenuControl(unplugPolicy)
        let text = [unplugPolicy.label, unplugPolicy.title, unplugPolicy.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(text.contains("End all current work"),
                      "Using the battery must not replace the saved unplug policy with current battery guidance")
    }

    func testBatteryPresetSelectionDoesNotStartAndOmitsUnlimited() throws {
        try launch(language: "en", scenario: "battery")
        XCTAssertEqual(try state()["power"] as? String, "battery")
        try openMenu()
        let picker = try required("manual-duration-picker")
        try selectDurationPreset(picker, expected: ["30 min", "1 h", "2 h"],
                                 selected: "1 h", evidenceName: "battery-duration-presets", inSettings: false)
        try waitForState(["manual": false])
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        try required("panel-start-manual").click()
        try waitForState(["manual": true, "holding": true])
        try required("panel-end-manual").click()
        try waitForState(["manual": false])
        // Reopen the actual menu if macOS dismissed it after the session action.
        if !app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch.exists {
            try openMenu()
        }
        XCTAssertEqual(try required("manual-duration-picker").value as? String, "1 h")
        XCTAssertFalse(app.descendants(matching: .any)["custom-duration-input"].exists)
        evidence("battery-preset-saved")
    }

    func testMenuDurationSelectionSavesAndSettingsExposeACOnlyRules() throws {
        try launch(language: "en", scenario: "ac")
        try openMenu()
        try selectDurationPreset(try required("manual-duration-picker"),
            expected: ["30 min", "1 h", "2 h", "Until ended"],
            selected: "1 h", evidenceName: "menu-v5-manual-presets", inSettings: false)
        try waitForState(["manual": false, "holding": true])
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        try openSettingsFromMenu()
        try selectPage("general", title: "Manual")
        XCTAssertFalse(app.descendants(matching: .any)["automatic-ac-toggle"].exists,
                       "Manual settings must not duplicate the automatic-start master switch")
        XCTAssertFalse(app.descendants(matching: .any)["settings-go-to-automatic"].exists,
            "The native sidebar replaces a duplicate page-navigation link")
        try selectPage("safety", title: "Power & Lid")
        try required("settings-page-safety")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        try revealSettingsControl(try required("settings-automatic-rules"))
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-power-condition"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-battery-duration-picker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["manual-battery-continuation-toggle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-manual-duration-picker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-rehearsal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-rehearsal-sheet"].exists)
        try selectPage("system", title: "General")
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-history"].exists)
        try expandSettingsDisclosure("settings-updates-details")
        XCTAssertFalse(app.descendants(matching: .any)["update-after-work-schedule"].exists)
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        evidence("settings-core-features-without-retired-extras")
    }

    func testDesktopSettingsOmitBatteryAndClosedLidControls() throws {
        try launch(language: "en", scenario: "desktop")
        try openSettings()
        try selectPage("general", title: "Manual")
        try required("settings-page-general")
        XCTAssertFalse(app.staticTexts["Manual session"].exists,
                       "Desktop settings must omit the empty manual session section")
        XCTAssertFalse(app.descendants(matching: .any)["settings-manual-duration-picker"].exists,
                       "Manual duration selection must live only in the menu bar")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Keep working with the lid closed")).firstMatch.exists)
        try selectPage("protection", title: "Protection & Diagnostics")
        try required("settings-protection-rules-details")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Stop below")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Thermal protection"].exists)
        try selectPage("system", title: "General")
        try expandSettingsDisclosure("settings-notifications-details")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Notification choices live inline in General")
        XCTAssertFalse(app.checkBoxes["Battery protection"].exists,
                       "Expanding alerts must not reveal a battery option on a desktop Mac")
        evidence("desktop-settings")
    }

    func testDesktopRetiredBatteryChoiceRequiresExplicitACAutomaticOn() throws {
        try launch(language: "en", scenario: "desktopBatteryCondition")
        try waitForState(["automatic": false, "manual": false, "holding": false, "paused": false])
        try openSettings()
        XCTAssertFalse(app.descendants(matching: .any)["closed-lid-allow-toggle"].exists)
        try selectPage("safety", title: "Power & Lid")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-power-condition"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["closed-lid-allow-toggle"].exists)
        let window = try activateSettingsWindow()
        try required(window.buttons[XCUIIdentifierCloseWindow], description: "Settings close").click()
        try openMenu(); try setAutomatic(true)
        try waitForState(["automatic": true, "manual": false, "holding": true, "paused": false])
        evidence("desktop-explicit-ac-enable-after-retired-choice")
    }

    func testThermalProtectionPreventsManualStart() throws {
        try launch(language: "en", scenario: "protection")
        XCTAssertEqual(try state()["thermal"] as? Int, 2)
        try waitForState(["manual": false, "holding": false, "paused": true])
        try openMenu()
        XCTAssertFalse(app.descendants(matching: .any)["panel-start-manual"].exists,
                       "Serious thermal pressure must hide the unavailable manual start")
        try waitForState(["manual": false, "holding": false, "paused": true])
        try openSettingsFromMenu()
        try selectPage("protection", title: "Protection & Diagnostics")
        try required("settings-protection-rules-details")
        XCTAssertTrue(app.staticTexts["Thermal protection"].exists)
        evidence("thermal-protection")
    }

    func testManualControlsSurviveOverflowWithoutShowingNextTimerPresets() throws {
        try launch(language: "en", scenario: "overflowError")
        try openMenu(); try required("panel-start-manual").click()
        try waitForState(["manual": true, "holding": true])
        let countdown = try required("panel-manual-countdown")
        let end = try required("panel-end-manual")
        let extend = try required("panel-extend-manual-30")
        let beforeDetails = try state()
        let requestID = try XCTUnwrap(beforeDetails["manualRequestID"] as? String)
        let deadline = try XCTUnwrap(beforeDetails["manualContinuousDeadline"] as? Double)
        try expandMenuDisclosure("panel-problem-details")
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch,
                                 description: "Overflow panel")
        let more = try required("panel-more-actions")
        let settings = try required("panel-open-settings")
        // A native scroll view is needed only when the body exceeds its current
        // screen budget. Verify the actual user requirement in either layout:
        // timer controls and persistent actions remain visible and distinct.
        let controls = [countdown, end, extend, settings, more]
        var measured: [CGRect] = []
        for control in controls {
            XCTAssertTrue(control.exists && control.isHittable,
                          "Expanded recovery details must keep \(control.identifier) reachable")
            let frame = control.frame
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(frame),
                          "\(control.identifier) must fit within the current menu panel")
            for earlier in measured {
                XCTAssertFalse(earlier.insetBy(dx: 1, dy: 1).intersects(frame.insetBy(dx: 1, dy: 1)),
                               "Timer and footer actions must not overlap")
            }
            measured.append(frame)
        }
        XCTAssertFalse(app.descendants(matching: .any)["manual-duration-picker"].isHittable,
                       "Active work must expose its deadline rather than a next-session duration picker")
        let afterDetails = try state()
        XCTAssertEqual(afterDetails["manualRequestID"] as? String, requestID)
        XCTAssertEqual(afterDetails["manualContinuousDeadline"] as? Double, deadline,
                       "Expanding recovery details must neither restart nor extend the timer")
        for key in ["automatic", "manual", "holding", "paused"] {
            XCTAssertEqual(afterDetails[key] as? Bool, beforeDetails[key] as? Bool,
                           "Reading recovery details must not change simulated \(key)")
        }
        XCTAssertEqual(afterDetails["selectedManualMinutes"] as? Int, beforeDetails["selectedManualMinutes"] as? Int)
        evidence("manual-v4-controls-survive-overflow")
    }

    func testLongErrorMenuKeepsPersistentActionsReachable() throws {
        try launch(language: "ko", scenario: "longError")
        try openMenu()
        let settings = try required("panel-open-settings")
        let stop = try required("panel-pause-all")
        evidence("long-error-menu-collapsed")
        try expandMenuDisclosure("panel-problem-details")
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(stop.isHittable)
        XCTAssertFalse(settings.frame.intersects(stop.frame), "Persistent menu actions must not overlap")
        evidence("long-error-menu")
        try openSettingsFromMenu()
        try required("settings-page-safety")
    }

    func testOverflowErrorRetainsCompleteRecoveryAdvice() throws {
        try launch(language: "ko", scenario: "overflowError")
        try openMenu()
        let settings = try required("panel-open-settings")
        let stop = try required("panel-pause-all")
        XCTAssertFalse(settings.label.isEmpty && settings.title.isEmpty,
                       "The Settings action needs an accessible name")
        XCTAssertFalse(stop.label.isEmpty && stop.title.isEmpty,
                       "The pause action needs an accessible name")
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(stop.isHittable)
        XCTAssertFalse(settings.frame.intersects(stop.frame), "Persistent menu actions must not overlap")
        evidence("overflow-error-menu-collapsed")
        try expandMenuDisclosure("panel-problem-details")
        XCTAssertTrue(settings.isHittable && stop.isHittable,
                      "Expanding complete recovery advice must preserve the persistent actions")
        // Advice completeness is compared from paired layout/screenshot evidence;
        // footer assertions apply to both the baseline and the candidate.
        evidence("overflow-error-menu")
        let review = try required("panel-review-settings")
        let menu = app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch
        for _ in 0..<4 where !review.isHittable {
            let scroll = menu.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists, "Overflowing recovery advice needs a scroll body")
            scroll.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(review.isHittable)
        XCTAssertEqual(review.label, "보호·진단에서 확인…")
        review.click()
        try required("settings-page-protection")
        XCTAssertTrue(try required("settings-error-context").isHittable,
                      "The common diagnostics entry must retain the request's error context")
        evidence("generic-error-diagnostics-destination")
    }

    func testClosedLidSetupReviewOpensPowerSettingsWithoutBatteryFallback() throws {
        try launch(language: "en", scenario: "lidSetup")
        try waitForState(["automatic": true, "automaticActive": true, "manual": false, "holding": true])
        let before = try state()
        try openMenu()
        XCTAssertTrue(try required("panel-current-work-section").exists,
                      "General automatic work remains available while the closed-lid helper needs preparation")
        let reviewedAt = Date().timeIntervalSince1970
        try required("panel-review-settings").click()
        try nativeSettingsNavigationHost()
        try required("settings-page-safety")
        XCTAssertFalse(app.descendants(matching: .any)["settings-page-general"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-battery-duration-picker"].exists)
        var after: [String: Any]?
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(), let observedAt = current["observedAt"] as? Double,
                  observedAt > reviewedAt else { return false }
            after = current
            return ["automatic", "automaticActive", "manual", "holding", "paused"].allSatisfy {
                current[$0] as? Bool == before[$0] as? Bool
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 5), .completed,
                       "Reviewing closed-lid preparation must preserve general work; observed \(String(describing: after))")
        evidence("closed-lid-setup-review-destination")
    }

    func testLongWarningScrollKeepsBodyControlsUsable() throws {
        try launch(language: "ko", scenario: "overflowError")
        try openMenu()
        let menu = app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch
        try expandMenuDisclosure("panel-problem-details")
        let start = try required("panel-start-manual")
        let scroll = menu.scrollViews.firstMatch
        if !start.isHittable {
            XCTAssertTrue(scroll.waitForExistence(timeout: 3), "Overflowing content needs an accessible scroll body")
            for _ in 0..<4 where !start.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: -240)
            }
        }
        XCTAssertTrue(start.isHittable, "Manual controls must remain reachable below a long warning")
        try expandMenuDisclosure("panel-closed-lid-policy")
        let automatic = try required("panel-automatic")
        try revealMenuControl(automatic)
        XCTAssertTrue(automatic.isHittable, "Automatic control must remain reachable in the scroll body")
        automatic.click()
        try waitForState(["automatic": false, "manual": false, "holding": false, "paused": false])
        try collapseMenuDisclosure("panel-closed-lid-policy")
        XCTAssertTrue(try required("panel-open-settings").isHittable)
        XCTAssertFalse(app.buttons["panel-pause-all"].exists,
                       "An inactive compact panel must not show an unnecessary Stop all action")
        try revealMenuControl(start)
        start.click()
        try waitForState(["manual": true, "holding": true])
        let pause = try required("panel-pause-all")
        for _ in 0..<4 where !pause.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -240) }
        XCTAssertTrue(pause.isHittable, "Active work must retain a reachable Stop all action")
        evidence("overflow-body-controls")
    }

    private func launch(language: String, scenario: String, appearance: String? = nil) throws {
        testLanguage = language
        app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment = ["TETHER_UI_TESTING": "1", "TETHER_UI_TEST_LANGUAGE": language,
                                 "TETHER_UI_TEST_SCENARIO": scenario]
        if let appearance { app.launchEnvironment["TETHER_UI_TEST_APPEARANCE"] = appearance }
        app.launch()
        let layout = UserDefaults(suiteName: "com.apple.HIToolbox")?
            .string(forKey: "AppleCurrentKeyboardLayoutInputSourceID") ?? "unknown"
        let keyboard = XCTAttachment(string: layout)
        keyboard.name = "keyboard-layout"; keyboard.lifetime = .keepAlways; add(keyboard)
        try required("ui-fixture-open-settings")
        let initial = try state()
        XCTAssertEqual(initial["bundleID"] as? String, bundleID)
        XCTAssertEqual(initial["executablePath"] as? String, expectedExecutablePath,
            "The test must launch this run's signed fixture, not a registered older copy")
        for key in ["automatic", "manual", "holding", "paused", "power", "thermal"] {
            XCTAssertNotNil(initial[key], "Missing fixture state key: \(key)")
        }
        evidence("launch-\(language)-\(scenario)")
    }

    private func verifySettings(language: String, minimumSize: Bool) throws {
        try openSettings()
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Native Settings window")
        let pages = settingsPageNames
        if minimumSize {
            try verifySettingsResize(window, evidenceName: "settings-first-open")
            let current = try XCTUnwrap(pages.first { app.descendants(matching: .any)["settings-page-\($0.page)"].exists })
            try assertSettingsPageLayout(window, page: current.page, title: current.title, minimumViewport: true)
        }
        let navigation = try nativeSettingsNavigationHost(in: window)
        var frames: [CGRect] = []
        for (page, title) in pages {
            let target = try navigationControl(page, title: title)
            let control = target.row
            XCTAssertTrue(target.action.isHittable, "\(title) must be clickable in the native window")
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
            XCTAssertTrue(navigation.frame.insetBy(dx: -1, dy: -1).contains(control.frame),
                          "Each native navigation row must remain inside the actual sidebar")
            let visibleTitle = settingsVisibleTitle(page, accessibleTitle: title)
            let textWidth = (visibleTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
            XCTAssertGreaterThanOrEqual(control.frame.width + 1, textWidth, "\(visibleTitle) has insufficient room for its visible label")
            XCTAssertGreaterThanOrEqual(control.frame.height, 20)
            for earlier in frames {
                XCTAssertFalse(earlier.insetBy(dx: 1, dy: 1).intersects(control.frame.insetBy(dx: 1, dy: 1)), "Sidebar navigation rows overlap")
            }
            frames.append(control.frame)
            // The native sidebar row above is already resolved and validated. Do
            // not repeat activation, title checks and descendant queries.
            target.action.click()
            try assertSelectedPage(page)
            try assertSettingsPageLayout(window, page: page, title: title)
            try assertPreviewIndicator(in: window, avoiding: try settingsNavigationTargets().map(\.row))
            evidence("settings-\(language)-\(page)")
        }
        XCTAssertTrue(navigation.exists)
        app.activate()
        let close = try required(window.buttons[XCUIIdentifierCloseWindow], description: "Settings close button")
        waitForHittable(close, description: "Settings close button")
        close.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3), "The native Settings window must close")
        try openMenu()
        try openSettingsFromMenu()
        try required("settings-page-system")
        // The real Settings command remains available after the window is reused.
        app.activate()
        let reopening = Date().timeIntervalSince1970
        app.typeKey(",", modifierFlags: .command)
        try nativeSettingsNavigationHost()
        let reopened = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                    description: "Reopened native Settings window")
        _ = try settingsGeometry(after: reopening, description: "settings-\(language)-reopened-presentation")
        try assertSelectedPage("system")
        try assertSettingsPageLayout(reopened, page: "system", title: settingsPageNames.last!.title)
        if minimumSize {
            try verifySettingsResize(reopened, evidenceName: "settings-reopened")
            try assertSettingsPageLayout(reopened, page: "system", title: settingsPageNames.last!.title, minimumViewport: true)
        }
        evidence("settings-\(language)-reopened")
        let reopenedClose = try required(reopened.buttons[XCUIIdentifierCloseWindow], description: "Reopened Settings close button")
        waitForHittable(reopenedClose, description: "Reopened Settings close button")
        reopenedClose.click()
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 3), "Reopening must preserve the actual close action")
    }

    private struct SettingsGeometry {
        let frame: CGSize
        let contentRect: CGSize
        let contentLayoutRect: CGRect
        let contentMinimum: CGSize
        let frameMinimum: CGSize

        init?(_ state: [String: Any], after: Double) {
            guard let observedAt = state["observedAt"] as? Double, observedAt > after,
                  let window = state["settingsWindow"] as? [String: Any],
                  window["key"] as? Bool == true, window["visible"] as? Bool == true,
                  window["isResizable"] as? Bool == true, window["inLiveResize"] as? Bool == false,
                  let frame = Self.size(window["frame"]), frame.width > 0, frame.height > 0,
                  let contentRect = Self.size(window["contentRect"]), contentRect.width > 0, contentRect.height > 0,
                  let contentLayoutRect = Self.rect(window["contentLayoutRect"]),
                  contentLayoutRect.width > 0, contentLayoutRect.height > 0,
                  let contentMinimum = Self.size(window["contentMinSize"]),
                  let frameMinimum = Self.size(window["minSize"]) else { return nil }
            self.frame = frame; self.contentRect = contentRect
            self.contentLayoutRect = contentLayoutRect
            self.contentMinimum = contentMinimum; self.frameMinimum = frameMinimum
        }

        var minimumFrame: CGSize {
            // NSWindow's content minimum excludes native titlebar chrome. Its
            // frame minimum can impose an additional bound; honor both readings.
            CGSize(width: max(frameMinimum.width, contentMinimum.width + max(0, frame.width - contentRect.width)),
                   height: max(frameMinimum.height, contentMinimum.height + max(0, frame.height - contentRect.height)))
        }

        /// AppKit reports this rectangle in window coordinates, with Y up.
        /// Convert only after matching the fresh window dimensions to AX.
        func contentLayoutFrame(in accessibilityFrame: CGRect) -> CGRect {
            CGRect(x: accessibilityFrame.minX + contentLayoutRect.minX,
                   y: accessibilityFrame.maxY - contentLayoutRect.maxY,
                   width: contentLayoutRect.width, height: contentLayoutRect.height)
        }

        private static func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Any], let x = value["x"] as? Double,
                  let y = value["y"] as? Double, x.isFinite, y.isFinite,
                  let size = size(value) else { return nil }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }

        private static func size(_ value: Any?) -> CGSize? {
            guard let value = value as? [String: Any], let width = value["width"] as? Double,
                  let height = value["height"] as? Double, width.isFinite, height.isFinite,
                  width >= 0, height >= 0 else { return nil }
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }
    }

    private func settingsGeometry(after: Double, description: String,
                                  matching predicate: @escaping (SettingsGeometry) -> Bool = { _ in true }) throws -> SettingsGeometry {
        var matched: SettingsGeometry?
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let state = observedState(), let geometry = SettingsGeometry(state, after: after),
                  predicate(geometry) else { return false }
            matched = geometry
            return true
        }, object: nil)
        let result = XCTWaiter.wait(for: [expected], timeout: 5)
        if result != .completed { evidence("geometry-\(description)") }
        XCTAssertEqual(result, .completed, "Fresh native frame/minimum telemetry must confirm \(description)")
        return try XCTUnwrap(matched, "Missing native Settings geometry after \(description)")
    }

    private func verifySettingsResize(_ window: XCUIElement, evidenceName: String) throws {
        try activateSettingsWindow()
        let initial = try settingsGeometry(after: Date().timeIntervalSince1970, description: "\(evidenceName)-before-resize")
        XCTAssertEqual(initial.contentMinimum.width, 720, accuracy: 1)
        XCTAssertEqual(initial.contentMinimum.height, 560, accuracy: 1)
        evidence("\(evidenceName)-before-resize")

        // Exercise real growth first, including a reopened window that retained
        // its minimum size. A resizable bit alone never proves a working edge.
        // Capturing evidence can outlast the previous focus observation. Confirm
        // this app and Settings are active/key again before each distinct drag.
        try activateSettingsWindow()
        _ = try settingsGeometry(after: Date().timeIntervalSince1970,
                                 description: "\(evidenceName)-before-width-growth")
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        var after = Date().timeIntervalSince1970
        rightEdge.click(forDuration: 0.2, thenDragTo: rightEdge.withOffset(CGVector(dx: 100, dy: 0)))
        let wider = try settingsGeometry(after: after, description: "\(evidenceName)-wider") {
            $0.frame.width > initial.frame.width + 2
        }
        evidence("\(evidenceName)-wider")
        try activateSettingsWindow()
        _ = try settingsGeometry(after: Date().timeIntervalSince1970,
                                 description: "\(evidenceName)-before-height-growth")
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        after = Date().timeIntervalSince1970
        bottomEdge.click(forDuration: 0.2, thenDragTo: bottomEdge.withOffset(CGVector(dx: 0, dy: 100)))
        let taller = try settingsGeometry(after: after, description: "\(evidenceName)-taller") {
            $0.frame.height > wider.frame.height + 2
        }
        evidence("\(evidenceName)-taller")

        // Rounded corners are outside the resize hit area. Use straight edges
        // and compare both axes to the observed content/frame minima, not a fixed number
        // of outer height or an unchanged default window's height.
        try activateSettingsWindow()
        _ = try settingsGeometry(after: Date().timeIntervalSince1970,
                                 description: "\(evidenceName)-before-minimum-width")
        let shrinkRight = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        after = Date().timeIntervalSince1970
        shrinkRight.click(forDuration: 0.2, thenDragTo: shrinkRight.withOffset(CGVector(dx: -600, dy: 0)))
        let narrower = try settingsGeometry(after: after, description: "\(evidenceName)-minimum-width") {
            abs($0.frame.width - $0.minimumFrame.width) <= 1 && $0.frame.width < taller.frame.width - 2
        }
        evidence("\(evidenceName)-minimum-width")
        try activateSettingsWindow()
        _ = try settingsGeometry(after: Date().timeIntervalSince1970,
                                 description: "\(evidenceName)-before-minimum-height")
        let shrinkBottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        after = Date().timeIntervalSince1970
        shrinkBottom.click(forDuration: 0.2, thenDragTo: shrinkBottom.withOffset(CGVector(dx: 0, dy: -500)))
        let minimum = try settingsGeometry(after: after, description: "\(evidenceName)-minimum-height") {
            abs($0.frame.width - $0.minimumFrame.width) <= 1 && abs($0.frame.height - $0.minimumFrame.height) <= 1
                && $0.frame.height < narrower.frame.height - 2
        }
        XCTAssertEqual(minimum.contentMinimum.width, 720, accuracy: 1)
        XCTAssertEqual(minimum.contentMinimum.height, 560, accuracy: 1)
        XCTAssertEqual(window.frame.width, 720, accuracy: 1,
                       "A drag must resize Settings to its real minimum; an unchanged default window is not sufficient")
        XCTAssertEqual(window.frame.width, minimum.frame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, minimum.frame.height, accuracy: 1)
        evidence("\(evidenceName)-minimum-height")
    }

    private func assertSettingsPageLayout(_ window: XCUIElement, page: String, title: String,
                                          minimumViewport: Bool = false) throws {
        let selectedTarget = try navigationControl(page, title: title, activateWindow: false)
        let selectedTab = selectedTarget.row
        let navigationFrame = try settingsNavigationFrame()
        let toolbar = try nativeSettingsToolbar(in: window)
        XCTAssertTrue([selectedTarget.caption.label, selectedTarget.caption.title,
                       selectedTarget.caption.value as? String ?? ""].contains(title),
            "The selected native sidebar input must identify the page in the current language")
        XCTAssertTrue(selectedTarget.action.isHittable,
                      "The selected sidebar's actual Cell must remain reachable after native presentation")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(navigationFrame),
                      "Every native sidebar row must fit inside Settings")
        let body = try required("settings-page-\(page)")
        let scroll = try settingsPageScrollView()
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(body.frame),
                      "The entire reading page must fit inside Settings")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(scroll.frame),
                      "The actual reading viewport must fit inside Settings")
        XCTAssertGreaterThanOrEqual(scroll.frame.minY, toolbar.frame.maxY - 1,
                                   "The reading viewport must remain below the complete native toolbar")
        XCTAssertFalse(navigationFrame.insetBy(dx: 1, dy: 1).intersects(scroll.frame.insetBy(dx: 1, dy: 1)),
                       "Scrollable content must not overlap the native sidebar")
        XCTAssertGreaterThanOrEqual(scroll.frame.minX, navigationFrame.maxX - 1,
            "The reading viewport must sit beside, rather than under, the native sidebar")
        let close = try required(window.buttons[XCUIIdentifierCloseWindow], description: "Settings close button")
        XCTAssertTrue(close.isEnabled && close.isHittable,
                      "Native presentation must preserve an enabled, reachable close button")
        XCTAssertFalse(navigationFrame.insetBy(dx: 1, dy: 1).intersects(close.frame.insetBy(dx: 1, dy: 1)),
                       "Native sidebar rows must not overlap the titlebar close button")
        XCTAssertGreaterThanOrEqual(scroll.frame.minY, close.frame.maxY - 1,
                                   "Reading content must remain below native titlebar controls")
        let sidebar = try nativeSettingsNavigationHost(in: window)
        // The fixture identity lives in native toolbar chrome, not a footer.
        // Validate its actual parent and separation from every reading/control area.
        try assertPreviewIndicator(in: toolbar, avoiding: [sidebar, scroll, close])
        if minimumViewport {
            let headings = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@", "settings-page-heading"))
            XCTAssertEqual(headings.count, 1, "The selected page must have one fixed heading")
            let heading = try required("settings-page-heading")
            XCTAssertTrue([heading.label, heading.title, heading.value as? String ?? ""].contains(title),
                          "The fixed heading must expose the complete selected-page title")
            let headingFrame = heading.frame
            XCTAssertTrue(isLayoutFrame(headingFrame), "The fixed heading needs finite, nonempty native bounds")
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(headingFrame),
                          "The fixed heading must remain inside Settings")
            XCTAssertGreaterThanOrEqual(headingFrame.minX, navigationFrame.maxX - 1,
                                       "The fixed heading must remain beside the native sidebar")
            XCTAssertGreaterThanOrEqual(headingFrame.minY, toolbar.frame.maxY - 1,
                                       "The fixed heading must remain below the native toolbar")
            XCTAssertLessThanOrEqual(headingFrame.maxY, scroll.frame.minY + 1,
                                     "The fixed heading must remain above the reading viewport")
            // The title is content, not unused space. Measure the actual empty
            // margins around it against the 22pt top and 6pt bottom design insets.
            XCTAssertLessThanOrEqual(headingFrame.minY - toolbar.frame.maxY, 24,
                                     "The fixed heading must not leave excess empty space above its title")
            XCTAssertLessThanOrEqual(scroll.frame.minY - headingFrame.maxY, 8,
                                     "The reading viewport must follow the fixed heading without an unused gap")
            let geometry = try settingsGeometry(after: Date().timeIntervalSince1970,
                description: "\(page)-minimum-reading-content-layout")
            XCTAssertEqual(window.frame.width, geometry.frame.width, accuracy: 1,
                "AX and the fresh AppKit content layout must describe the same window width")
            XCTAssertEqual(window.frame.height, geometry.frame.height, accuracy: 1,
                "AX and the fresh AppKit content layout must describe the same window height")
            let layout = geometry.contentLayoutFrame(in: window.frame)
            XCTAssertTrue(isLayoutFrame(layout), "The actual content layout needs finite, nonempty bounds")
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(layout),
                "The measured application content layout must remain inside Settings")
            XCTAssertGreaterThanOrEqual(scroll.frame.minY, layout.minY - 1,
                "The reading viewport must start inside the actual content layout below native chrome")
            XCTAssertLessThanOrEqual(scroll.frame.maxY, layout.maxY + 1,
                "The reading viewport must not extend beyond the actual content layout")
            XCTAssertGreaterThanOrEqual(scroll.frame.height, layout.maxY - scroll.frame.minY - 24,
                "The reading viewport must fill the actual content area beneath the toolbar")
        }
    }

    private struct SettingsNavigationTarget {
        let row: XCUIElement
        let action: XCUIElement
        let caption: XCUIElement
    }

    private var settingsPageNames: [(page: String, title: String)] {
        testLanguage == "ko"
            ? [("safety", "전원·덮개"), ("general", "수동 유지"), ("protection", "보호·진단"), ("system", "일반")]
            : [("safety", "Power & Lid"), ("general", "Manual"),
               ("protection", "Protection & Diagnostics"), ("system", "General")]
    }

    private func settingsVisibleTitle(_ page: String, accessibleTitle: String) -> String {
        page == "protection" && testLanguage == "en" ? "Protection" : accessibleTitle
    }

    private func settingsNavigationTargets() throws -> [SettingsNavigationTarget] {
        try settingsPageNames.map { try navigationControl($0.page, title: $0.title, activateWindow: false) }
    }

    /// Measure the real selectable rows, separately from the native titlebar.
    /// The detail ScrollView may move; the four sidebar rows must stay fixed.
    private func settingsNavigationFrame() throws -> CGRect {
        let targets = try settingsNavigationTargets()
        XCTAssertEqual(targets.count, 4, "Settings must expose four measured native sidebar choices")
        let frame = targets.reduce(CGRect.null) { $0.union($1.row.frame) }
        XCTAssertTrue(isLayoutFrame(frame), "The native sidebar requires real, nonempty geometry")
        for (index, target) in targets.enumerated() {
            XCTAssertTrue(isLayoutFrame(target.row.frame), "Each native sidebar row requires measured bounds")
            if index > 0 {
                XCTAssertGreaterThanOrEqual(target.row.frame.minY, targets[index - 1].row.frame.maxY - 1,
                    "Sidebar pages must follow their approved top-to-bottom order")
            }
            for earlier in targets.prefix(index) {
                XCTAssertFalse(earlier.row.frame.insetBy(dx: 1, dy: 1)
                    .intersects(target.row.frame.insetBy(dx: 1, dy: 1)), "Native sidebar rows must not overlap")
            }
        }
        return frame
    }

    @discardableResult
    private func nativeSettingsNavigationHost() throws -> XCUIElement {
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "The exact native SwiftUI Settings window")
        return try nativeSettingsNavigationHost(in: window)
    }

    @discardableResult
    private func nativeSettingsNavigationHost(in window: XCUIElement) throws -> XCUIElement {
        let hosts = window.descendants(matching: .any).matching(identifier: "settings-sidebar").allElementsBoundByIndex
        let sidebar = try required(try XCTUnwrap(hosts.count == 1 ? hosts.first : nil,
            "Settings must expose one identified native sidebar, separate from its detail page"),
            description: "Native Settings sidebar")
        XCTAssertTrue(isLayoutFrame(sidebar.frame), "The native sidebar needs nonempty measured bounds")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(sidebar.frame))
        for (page, _) in settingsPageNames {
            XCTAssertEqual(try sidebarNavigationRows(in: sidebar, page: page).count, 1,
                "Each approved page must expose one actual native sidebar input")
        }
        return sidebar
    }

    private func nativeSettingsToolbar(in window: XCUIElement) throws -> XCUIElement {
        let toolbars = window.toolbars.allElementsBoundByIndex
        return try required(try XCTUnwrap(toolbars.count == 1 ? toolbars.first : nil,
            "The native Settings titlebar must remain measurable independently of the sidebar"),
            description: "Native Settings titlebar toolbar")
    }

    private func sidebarNavigationCaption(in sidebar: XCUIElement, page: String) throws -> XCUIElement {
        let matches = sidebar.descendants(matching: .staticText).matching(identifier: "settings-tab-\(page)")
        let caption = try required(try XCTUnwrap(matches.count == 1 ? matches.firstMatch : nil,
            "Each sidebar page must have exactly one stable native text anchor"),
            description: "Unique native sidebar caption \(page)")
        XCTAssertTrue(isLayoutFrame(caption.frame), "The sidebar caption must expose actual nonempty native bounds")
        XCTAssertTrue(sidebar.frame.insetBy(dx: -1, dy: -1).contains(caption.frame),
                      "The complete caption must belong to the actual sidebar")
        return caption
    }

    private func sidebarNavigationRows(in sidebar: XCUIElement, page: String) throws -> [XCUIElement] {
        let caption = try sidebarNavigationCaption(in: sidebar, page: page)
        // Captured native AX has four sibling OutlineRows with a Cell and one
        // identified StaticText each. Descendant-ID queries on an indexed row
        // can overmatch a sibling; spatial containment binds the unique anchor
        // to its actual native row without accepting an arbitrary text input.
        return sidebar.descendants(matching: .outlineRow).allElementsBoundByIndex.filter {
            isLayoutFrame($0.frame) && $0.frame.insetBy(dx: -1, dy: -1).contains(caption.frame)
        }
    }

    private func navigationControl(_ page: String, title: String,
                                   activateWindow: Bool = true) throws -> SettingsNavigationTarget {
        if activateWindow { try activateSettingsWindow() }
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Settings window containing native sidebar choice \(title)")
        let sidebar = try nativeSettingsNavigationHost(in: window)
        let caption = try sidebarNavigationCaption(in: sidebar, page: page)
        let matches = try sidebarNavigationRows(in: sidebar, page: page)
        let row = try required(try XCTUnwrap(matches.count == 1 ? matches.first : nil,
            "The native OutlineRow containing the unique caption must be unambiguous for \(title)"),
            description: "Native Settings sidebar row \(title)")
        XCTAssertTrue([caption.label, caption.title, caption.value as? String ?? ""].contains(title),
            "The anchored native sidebar caption must expose the full localized accessibility name \(title)")
        XCTAssertTrue(sidebar.frame.insetBy(dx: -1, dy: -1).contains(row.frame),
                      "The native row must belong to its actual Settings sidebar")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(row.frame),
                      "The native sidebar row must fit inside Settings")
        XCTAssertTrue(row.frame.insetBy(dx: -1, dy: -1).contains(caption.frame),
                      "The complete caption must remain inside its native OutlineRow")
        let visibleTitle = settingsVisibleTitle(page, accessibleTitle: title)
        let textWidth = (visibleTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        XCTAssertGreaterThanOrEqual(row.frame.width + 1, textWidth,
                                   "The sidebar row must allocate room for its complete visible title \(visibleTitle)")
        XCTAssertGreaterThanOrEqual(row.frame.height, 32,
                                   "The native sidebar must preserve its complete 32pt input row")
        XCTAssertGreaterThanOrEqual(caption.frame.width + 1, textWidth,
                                   "The measured native caption must allocate room for \(visibleTitle)")
        let cells = sidebar.descendants(matching: .cell).allElementsBoundByIndex.filter {
            isLayoutFrame($0.frame) && row.frame.insetBy(dx: -1, dy: -1).contains($0.frame)
                && $0.frame.insetBy(dx: -1, dy: -1).contains(caption.frame)
        }
        let action = try required(try XCTUnwrap(cells.count == 1 ? cells.first : nil,
            "The native row must contain exactly one actual Cell around its caption for \(title)"),
            description: "Native Settings sidebar Cell \(title)")
        waitForHittable(action, description: "Native Settings sidebar Cell \(title)")
        XCTAssertTrue(action.isEnabled, "The actual sidebar Cell must be an enabled input target for \(title)")
        // OutlineRow is a disabled AX container; actual activation belongs to
        // its measured enabled Cell. Every input still verifies selected content.
        return SettingsNavigationTarget(row: row, action: action, caption: caption)
    }

    @discardableResult
    private func activateSettingsWindow() throws -> XCUIElement {
        // Activate and raise this window, rather than whichever fixture window was
        // last key. A real title-bar click also makes foreground interference visible.
        activateFixture()
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Native Settings window to activate")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12)).click()
        let after = Date().timeIntervalSince1970
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(), let observedAt = current["observedAt"] as? Double,
                  observedAt > after, let application = current["application"] as? [String: Any],
                  let settings = current["settingsWindow"] as? [String: Any],
                  let keyNumber = application["keyWindowNumber"] as? Int,
                  let settingsNumber = settings["windowNumber"] as? Int else { return false }
            return application["active"] as? Bool == true && settings["key"] as? Bool == true
                && keyNumber == settingsNumber
        }, object: nil)
        let result = XCTWaiter.wait(for: [foreground], timeout: 5)
        if result != .completed { evidence("settings-foreground-interference") }
        XCTAssertEqual(result, .completed,
                       "Actual Settings must own foreground and the key window before sidebar input")
        return window
    }

    private func waitForHittable(_ element: XCUIElement, description: String) {
        let predicate = NSPredicate { _, _ in element.isHittable }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed { evidence("not-hittable-\(description)") }
        XCTAssertEqual(result, .completed, "Required control remains unhittable after activation: \(description)")
    }

    private func selectPage(_ page: String, title: String) throws {
        try navigationControl(page, title: title).action.click()
        try assertSelectedPage(page)
    }

    private func assertSelectedPage(_ page: String) throws {
        try required("settings-page-\(page)")
        for other in settingsPageNames.map(\.page) where other != page {
            XCTAssertFalse(app.descendants(matching: .any)["settings-page-\(other)"].exists,
                           "Selecting \(page) must change the real page")
        }
    }

    private func assertSelectedSidebarPage(_ page: String) throws {
        try assertSelectedPage(page)
        for item in settingsPageNames {
            let target = try navigationControl(item.page, title: item.title, activateWindow: false)
            XCTAssertEqual(target.row.isSelected, item.page == page,
                           "Keyboard page changes must match exactly one selected native OutlineRow")
            XCTAssertEqual(target.action.isSelected, item.page == page,
                           "The selected page must match its actual native Cell selection")
        }
    }

    private func openSettings() throws {
        try required("ui-fixture-open-settings").click()
        try nativeSettingsNavigationHost()
    }

    private func openMenu() throws {
        activateFixture()
        // MenuBarExtra is exposed as StatusItem on macOS, rather than MenuBarItem.
        let status = try required("tether-status-item")
        XCTAssertFalse(status.label.isEmpty && status.title.isEmpty, "The actual status item needs an accessible name")
        XCTAssertTrue(status.isHittable)
        status.click()
        // Automatic controls are intentionally absent while stopped or protected.
        // The persistent Settings action identifies the same native panel in every state.
        try required("panel-open-settings")
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch,
                                 description: "Native menu panel")
        // The native MenuButton AXTitle uses the app's accessibilityLabel,
        // while the visible footer caption has a separate localized ellipsis.
        let more = try menuMoreActions(in: panel)
        try assertPreviewIndicator(in: panel, avoiding: [try required("panel-open-settings"), more])
        evidence("actual-menu-bar-extra")
    }

    private func activateFixture() {
        let activationRequestedAt = Date().timeIntervalSince1970
        app.activate()
        let active = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let observed = observedState(),
                  let observedAt = observed["observedAt"] as? Double,
                  observedAt > activationRequestedAt,
                  let application = observed["application"] as? [String: Any] else { return false }
            return application["active"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed,
                       "A fresh native observation must confirm activation before sending input")
    }

    private func menuMoreActions(in panel: XCUIElement) throws -> XCUIElement {
        // Selecting a native duration popup can rematerialize this same footer
        // MenuButton with the system SF ellipsis name (observed: "더 보기") in
        // place of its explicit "다른 동작" label. Bind its exact stable ID and
        // native role, then require one of those precise localized purpose names;
        // never substitute another button, blank label or arbitrary ellipsis.
        let matches = panel.descendants(matching: .menuButton).matching(identifier: "panel-more-actions")
        let more = try required(matches.firstMatch, description: "Menu panel more-actions control with exact native role and identifier")
        XCTAssertEqual(matches.count, 1, "The panel must have one uniquely identified native More actions menu")
        let validNames = testLanguage == "ko" ? ["다른 동작", "더 보기"] : ["More actions", "More"]
        XCTAssertTrue([more.title, more.label].contains(where: validNames.contains),
                      "The identified native More control must retain a complete localized purpose name")
        waitForHittable(more, description: "Identified native More actions control")
        return more
    }

    private func verifyDisconnectSummary(containing expected: String, evidenceName: String) throws {
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch,
                                 description: "Menu panel containing current work details")
        try expandMenuDisclosure("panel-closed-lid-policy")
        let summary = try required(panel.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@", expected, expected, expected)).firstMatch,
            description: "Expanded closed-lid unplug summary")
        let text = [summary.label, summary.title, summary.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(text.contains(expected),
                      "The current unplug summary must preserve OS delegation and valid battery-work conditions")
        XCTAssertTrue(summary.isHittable, "Expanded unplug guidance must be visible inside the actual menu panel")
        evidence(evidenceName)
        try collapseMenuDisclosure("panel-closed-lid-policy")
    }

    private func assertPreviewIndicator(in container: XCUIElement, avoiding controls: [XCUIElement]) throws {
        let badge = try required(container.descendants(matching: .staticText)["preview-indicator"].firstMatch,
                                 description: "Preview identity in the current scene")
        let title = testLanguage == "ko" ? "미리보기" : "Preview"
        // Settings exposes AXLabel; the menu's StaticText can expose the same
        // localized identity only in AXValue. A nonempty wrong-language label still fails.
        let identity = badge.label.isEmpty ? (badge.value as? String ?? "") : badge.label
        XCTAssertTrue(identity.contains(title), "The simulated fixture must identify itself in the current language")
        XCTAssertTrue(badge.isHittable, "The Preview identity must remain visible in the native scene")
        XCTAssertTrue(container.frame.insetBy(dx: -1, dy: -1).contains(badge.frame),
                      "The Preview identity must fit inside its actual scene")
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        XCTAssertGreaterThanOrEqual(badge.frame.width + 1, textWidth,
                                   "An icon-only label must not replace the visible Preview text")
        XCTAssertGreaterThan(badge.frame.height, 10)
        for control in controls {
            XCTAssertFalse(badge.frame.insetBy(dx: 1, dy: 1).intersects(control.frame.insetBy(dx: 1, dy: 1)),
                           "The Preview identity must not overlap navigation or menu actions")
        }
    }

    private func settingsFocusAfterFreshObservation() throws -> (isWindow: Bool, className: String, identity: String, isSidebar: Bool?) {
        let after = Date().timeIntervalSince1970
        var matchedWindow: [String: Any]?
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(), let observedAt = current["observedAt"] as? Double,
                  let window = current["settingsWindow"] as? [String: Any],
                  observedAt > after, window["key"] as? Bool == true else { return false }
            matchedWindow = window
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 5), .completed,
                       "Focus must be observed after the real input in the key Settings window")
        let window = try XCTUnwrap(matchedWindow, "A fresh key-window observation is required")
        let isWindow = try XCTUnwrap(window["firstResponderIsWindow"] as? Bool)
        let className = try XCTUnwrap(window["firstResponderClass"] as? String)
        let identity = try XCTUnwrap(window["firstResponderIdentity"] as? String)
        XCTAssertFalse(className.isEmpty, "A key Settings window must expose its current responder")
        XCTAssertNotEqual(identity, "none", "The current responder must have an observable identity")
        let details = window["firstResponderDetails"] as? [String: Any]
        let outlineAncestor = details?["hasPublicOutlineViewAncestor"] as? Bool
        let sidebarDescendant = details?["focusViewIsDescendantOfSidebar"] as? Bool
        let isSidebar = outlineAncestor.flatMap { ancestor in sidebarDescendant.map { ancestor && $0 } }
        return (isWindow, className, identity, isSidebar)
    }

    private func waitForSettingsFocus(isWindow: Bool, className: String? = nil, identity: String? = nil) throws {
        let after = Date().timeIntervalSince1970
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(), let observedAt = current["observedAt"] as? Double,
                  observedAt > after, let window = current["settingsWindow"] as? [String: Any] else { return false }
            return window["key"] as? Bool == true && window["firstResponderIsWindow"] as? Bool == isWindow
                && (className == nil || window["firstResponderClass"] as? String == className)
                && (identity == nil || window["firstResponderIdentity"] as? String == identity)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "Settings must clear initial pointer focus and preserve an observed keyboard target")
    }


    private func openSettingsFromMenu() throws {
        try required("panel-open-settings").click()
        try nativeSettingsNavigationHost()
    }

    private func setAutomatic(_ enabled: Bool) throws {
        guard try state()["automatic"] as? Bool != enabled else { return }
        let identifier = "panel-closed-lid-policy"
        let details = try disclosureTriangle(identifier)
        let wasExpanded = (details.value as? NSNumber)?.boolValue ?? (details.value as? String == "1")
        if !wasExpanded { try expandMenuDisclosure(identifier) }
        let automatic = try required("panel-automatic")
        try revealMenuControl(automatic)
        automatic.click()
        if !wasExpanded { try collapseMenuDisclosure(identifier) }
    }

    @discardableResult
    private func assertDurationMenuOptions(_ expected: [String], in menu: XCUIElement, file: StaticString = #filePath,
                                           line: UInt = #line) throws -> XCUIElement {
        let first = try XCTUnwrap(expected.first, file: file, line: line)
        try durationMenuItem(first, in: menu, file: file, line: line)
        // Native macOS menu items expose AXTitle while AXLabel can be empty.
        let titles = menu.descendants(matching: .menuItem).allElementsBoundByIndex.map { item in
            item.label.isEmpty ? item.title : item.label
        }
        XCTAssertEqual(titles, expected, "The open duration menu must contain only its allowed presets", file: file, line: line)
        XCTAssertFalse(menu.descendants(matching: .menuItem).matching(durationTitle("Custom…")).firstMatch.exists,
                       file: file, line: line)
        XCTAssertFalse(menu.descendants(matching: .menuItem).matching(durationTitle("직접 입력…")).firstMatch.exists,
                       file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["custom-duration-input"].exists, file: file, line: line)
        return menu
    }

    private func durationMenu(for picker: XCUIElement) throws -> XCUIElement {
        let popup: XCUIElement
        if picker.elementType == .popUpButton { popup = picker }
        else {
            let candidates = picker.descendants(matching: .popUpButton)
            XCTAssertEqual(candidates.count, 1, "The identified duration control must contain one native PopUpButton")
            popup = try required(candidates.firstMatch, description: "Native duration PopUpButton")
        }
        // Observed popup AX places the tracking Menu below its PopUpButton.
        // Never search the app's unrelated main menus by an item identifier.
        let menu = try required(popup.menus.firstMatch, description: "This duration PopUpButton's native menu")
        XCTAssertEqual(popup.menus.count, 1, "The duration popup must expose one current tracking menu")
        return menu
    }

    private func durationTitle(_ title: String) -> NSPredicate {
        // Native items use the shared identifier menuAction: and carry the
        // preset in AXTitle. Subscript identifiers cannot identify that text.
        NSPredicate(format: "title == %@ OR label == %@ OR value == %@", title, title, title)
    }

    @discardableResult
    private func durationMenuItem(_ title: String, in menu: XCUIElement, file: StaticString = #filePath,
                                  line: UInt = #line) throws -> XCUIElement {
        let candidates = menu.descendants(matching: .menuItem).matching(durationTitle(title))
        let item = try required(candidates.firstMatch, description: "Exact duration preset \(title)", file: file, line: line)
        XCTAssertEqual(candidates.count, 1, "The current duration menu must contain one exact preset \(title)", file: file, line: line)
        return item
    }

    private func selectDurationPreset(_ picker: XCUIElement, expected: [String], selected: String,
                                      evidenceName: String, inSettings: Bool) throws {
        if inSettings {
            try revealSettingsControl(picker).click()
        } else {
            waitForHittable(picker, description: "Menu duration picker")
            picker.click()
        }
        let menu = try assertDurationMenuOptions(expected, in: durationMenu(for: picker))
        let selectedPreset = try durationMenuItem(selected, in: menu)
        waitForHittable(selectedPreset, description: "Duration preset \(selected)")
        try transientMenuEvidence(menu, name: evidenceName)
        selectedPreset.click()
        let selectedValue = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.value as? String == selected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedValue], timeout: 3), .completed,
                       "Choosing a preset must update the real picker")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 3), "Choosing a preset must dismiss the actual native menu")
        evidence("\(evidenceName)-selected")
    }

    private func transientMenuEvidence(_ menu: XCUIElement, name: String) throws {
        // A tracking menu is transient. Capture this menu only, then immediately
        // perform the tested key/selection; whole-app AX/layout evidence belongs
        // after dismissal. No activation, input or retry/reopen occurs here.
        let before = try state()
        let beforeFrame = menu.frame
        XCTAssertTrue(menu.exists && !beforeFrame.isEmpty && !beforeFrame.isInfinite,
                      "The actual transient menu must be visible before capture")
        let startedAt = Date().timeIntervalSince1970
        let screenshot = XCTAttachment(screenshot: menu.screenshot())
        screenshot.name = "\(name)-transient-menu-screenshot"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let finishedAt = Date().timeIntervalSince1970
        let after = try state()
        let stillOpen = menu.exists
        let observation: [String: Any] = [
            "scope": "actual native tracking menu only",
            "captureStartedAt": startedAt, "captureFinishedAt": finishedAt,
            "menuFrameBefore": layoutFrame(beforeFrame),
            "menuFrameAfter": stillOpen ? layoutFrame(menu.frame) as Any : NSNull(),
            "menuExistsAfter": stillOpen,
            "focusBefore": ["observedAt": before["observedAt"] ?? NSNull(),
                            "application": before["application"] ?? NSNull(),
                            "settingsWindow": before["settingsWindow"] ?? NSNull()],
            "focusAfter": ["observedAt": after["observedAt"] ?? NSNull(),
                           "application": after["application"] ?? NSNull(),
                           "settingsWindow": after["settingsWindow"] ?? NSNull()]]
        let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(name)-transient-menu-observation.json"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(stillOpen, "Transient capture must leave the menu open for the tested action")
        XCTAssertEqual((before["application"] as? [String: Any])?["active"] as? Bool, true,
                       "The tracking menu must belong to the active fixture before capture")
        XCTAssertEqual((after["application"] as? [String: Any])?["active"] as? Bool, true,
                       "Focus loss during transient capture is a failure, not a reason to reopen the menu")
    }

    private func assertDisclosureExpanded(_ control: XCUIElement) throws {
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if let value = control.value as? NSNumber { return value.boolValue }
            return control.value as? String == "1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed,
                       "Disclosure must be expanded before inspecting its content")
    }

    private func assertDisclosureCollapsed(_ control: XCUIElement) throws {
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if let value = control.value as? NSNumber { return !value.boolValue }
            return control.value as? String == "0"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 3), .completed,
                       "Compact secondary settings must begin collapsed")
    }

    private func currentDisclosureTriangle(_ identifier: String) -> XCUIElement? {
        let stableID = NSPredicate(format: "identifier == %@", identifier)
        let inputs = app.descendants(matching: .disclosureTriangle).matching(stableID)
        if inputs.count == 1 { return inputs.firstMatch }
        guard inputs.count == 0 else { return nil }
        let groups = app.descendants(matching: .group).matching(stableID)
        guard groups.count == 1 else { return nil }
        let group = groups.firstMatch
        let ownerFrame = group.frame
        guard isLayoutFrame(ownerFrame) else { return nil }
        // Contained PowerEvent sections expose their native expanded value on
        // a Group header (sometimes the owner itself). Other sections expose a
        // triangle. Only one native 0/1 header at this owner's top is valid;
        // nested disclosures further down must never substitute for it.
        let headers = ([group] + group.descendants(matching: .any).allElementsBoundByIndex).filter {
            guard [.group, .disclosureTriangle].contains($0.elementType), !$0.label.isEmpty,
                  isLayoutFrame($0.frame), abs($0.frame.minY - ownerFrame.minY) <= 1,
                  ownerFrame.insetBy(dx: -1, dy: -1).contains($0.frame) else { return false }
            if let value = $0.value as? NSNumber { return value.doubleValue == 0 || value.doubleValue == 1 }
            return ["0", "1"].contains($0.value as? String ?? "")
        }
        return headers.count == 1 ? headers.first : nil
    }

    private func disclosureTriangle(_ identifier: String) throws -> XCUIElement {
        try required(try XCTUnwrap(currentDisclosureTriangle(identifier),
            "The stable disclosure owner must identify one top native expanded-value header"),
            description: "Native disclosure header \(identifier)")
    }

    private func assertDisclosureValue(_ identifier: String, expanded: Bool) throws {
        // The native input's label and identifier can move to its Group when
        // the content opens. Resolve the same stable owner on each observation.
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let input = currentDisclosureTriangle(identifier) else { return false }
            if let value = input.value as? NSNumber { return value.boolValue == expanded }
            return input.value as? String == (expanded ? "1" : "0")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 3), .completed,
                       "The actual disclosure value must match its requested open/closed state")
    }

    private func expandSettingsDisclosure(_ identifier: String) throws {
        let triangle = try disclosureTriangle(identifier)
        try assertDisclosureCollapsed(triangle)
        try revealSettingsControl(triangle)
        try clickSettingsDisclosure(triangle, identifier: identifier)
        try assertDisclosureValue(identifier, expanded: true)
    }

    private func clickSettingsDisclosure(_ triangle: XCUIElement, identifier: String) throws {
        if triangle.descendants(matching: .staticText).count == 0 {
            // Native disclosures without a summary expose their 15pt title
            // directly as AXLabel, including SettingsDisclosure wrappers.
            // Paired failure captures confirmed this shape in both languages.
            // Validate the measured one-line control before using its arrow.
            XCTAssertEqual(triangle.elementType, .disclosureTriangle)
            XCTAssertTrue(triangle.isEnabled && triangle.isHittable)
            XCTAssertFalse(triangle.label.isEmpty, "The native disclosure must expose its title")
            XCTAssertTrue(isLayoutFrame(triangle.frame))
            XCTAssertGreaterThanOrEqual(triangle.frame.height, 12)
            XCTAssertLessThanOrEqual(triangle.frame.height, 20,
                                     "Only the observed one-line title can use this measured arrow click")
            XCTAssertEqual(triangle.descendants(matching: .staticText).count, 0,
                           "A changed one-line layout requires an explicit click-target review")
            let point = CGPoint(x: triangle.frame.minX + 26, y: triangle.frame.midY)
            let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                      description: "Settings containing the native helper arrow")
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(point))
            triangle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 26, dy: 0)).click()
            return
        }
        // Native AX bounds include the label's full row height. The observed
        // 35.5pt header center sits 10.25pt below its actual 15pt first title
        // line and arrow. Measure that line instead of guessing a Y inset.
        let title = try required(triangle.descendants(matching: .staticText).firstMatch,
                                 description: "Measured Settings disclosure title")
        let titleFrame = title.frame
        let triangleFrame = triangle.frame
        XCTAssertTrue(isLayoutFrame(titleFrame), "The Settings disclosure title must have measurable native bounds")
        let point = CGPoint(x: triangleFrame.minX + 26, y: titleFrame.midY)
        let window = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                  description: "Settings containing the disclosure arrow")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(point),
                      "The measured native disclosure arrow must be inside Settings")
        triangle.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: titleFrame.midY - triangleFrame.minY)).click()
    }

    private func expandMenuDisclosure(_ identifier: String) throws {
        let triangle = try disclosureTriangle(identifier)
        try assertDisclosureCollapsed(triangle)
        try revealMenuControl(triangle)
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch,
                                 description: "Panel containing compact disclosure")
        evidence("menu-disclosure-before-expanding")
        // Native DisclosureTriangle includes an invisible leading inset in its
        // AX bounds. Paired native screenshots confirm the arrow and label fit;
        // require the row's height/right edge and actual click target to fit.
        XCTAssertGreaterThanOrEqual(triangle.frame.minY, panel.frame.minY - 1)
        XCTAssertLessThanOrEqual(triangle.frame.maxY, panel.frame.maxY + 1)
        XCTAssertLessThanOrEqual(triangle.frame.maxX, panel.frame.maxX + 1)
        // The native triangle is at 17.5pt from the panel's leading edge;
        // its AX frame includes an extra 8.5pt leading inset. The wide
        // accessibility row's center is label text, not the arrow hit target.
        let arrowPoint = CGPoint(x: triangle.frame.minX + 26,
                                 y: triangle.frame.minY + min(7, triangle.frame.height / 2))
        XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(arrowPoint))
        waitForHittable(triangle, description: "Compact menu disclosure \(identifier)")
        triangle.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: min(7, triangle.frame.height / 2))).click()
        try assertDisclosureValue(identifier, expanded: true)
        if identifier == "manual-next-session-details" {
            XCTAssertTrue(app.popUpButtons["manual-duration-picker"].waitForExistence(timeout: 3),
                          "The expanded disclosure must expose its next-session duration picker")
        }
    }

    private func collapseMenuDisclosure(_ identifier: String) throws {
        try assertDisclosureValue(identifier, expanded: true)
        let triangle = try disclosureTriangle(identifier)
        try revealMenuControl(triangle)
        triangle.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: min(7, triangle.frame.height / 2))).click()
        try assertDisclosureValue(identifier, expanded: false)
    }

    private func revealMenuControl(_ control: XCUIElement) throws {
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-more-actions").firstMatch,
                                 description: "Menu panel containing a control to reveal")
        let scroll = panel.scrollViews.firstMatch
        if scroll.exists {
            for _ in 0..<5 {
                let viewport = scroll.frame.insetBy(dx: 0, dy: 4)
                if control.isHittable && control.frame.minY >= viewport.minY,
                   control.frame.maxY <= viewport.maxY { break }
                scroll.scroll(byDeltaX: 0, deltaY: control.frame.minY < viewport.minY ? 200 : -200)
            }
        }
        XCTAssertTrue(control.isHittable, "The menu control must be visible before interaction: \(control.identifier)")
    }

    @discardableResult
    private func revealSettingsControl(_ control: XCUIElement) throws -> XCUIElement {
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        if settings.exists {
            let scroll = try settingsPageScrollView()
            for _ in 0..<5 {
                let viewport = scroll.frame.insetBy(dx: 0, dy: 8)
                if control.frame.minY >= viewport.minY && control.frame.maxY <= viewport.maxY { break }
                scroll.scroll(byDeltaX: 0, deltaY: control.frame.minY < viewport.minY ? 180 : -180)
            }
            XCTAssertGreaterThanOrEqual(control.frame.minY, scroll.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, scroll.frame.maxY,
                                     "The control must fit in the visible Settings viewport")
        }
        XCTAssertTrue(control.isHittable, "The control must be reachable before interaction")
        return control
    }

    private func settingsPageScrollView() throws -> XCUIElement {
        let settings = try required(app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch,
                                    description: "Settings window containing the current page")
        let pages = settingsPageNames.map(\.page).map {
            settings.descendants(matching: .any)["settings-page-\($0)"].firstMatch
        }.filter { $0.exists }
        XCTAssertEqual(pages.count, 1, "Exactly one real Settings page must provide the reading viewport")
        let page = try XCTUnwrap(pages.first, "The current Settings page must exist")
        // Some native Forms put the page identifier on the ScrollView itself.
        // Otherwise query only this page, never an unrelated navigation scroll view.
        let scrolls = (page.elementType == .scrollView ? [page] : [])
            + page.descendants(matching: .scrollView).allElementsBoundByIndex
        XCTAssertEqual(scrolls.count, 1,
                       "The current native Form must provide exactly one reading scroll view; nested scrolling is not accepted")
        let scroll = try required(try XCTUnwrap(scrolls.count == 1 ? scrolls.first : nil,
            "The selected Settings page needs one native reading viewport"),
            description: "Current Settings page scroll view")
        XCTAssertTrue(page.frame.insetBy(dx: -1, dy: -1).contains(scroll.frame),
                      "The reading scroll view must belong to the current detail page")
        return scroll
    }

    @discardableResult
    private func required(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        try required(app.descendants(matching: .any)[identifier].firstMatch, description: identifier, file: file, line: line)
    }

    @discardableResult
    private func required(_ element: XCUIElement, description: String, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let exists = element.exists || element.waitForExistence(timeout: 5)
        if !exists { evidence("missing-\(description)") }
        return try XCTUnwrap(exists ? element : nil, "Required AX element unavailable: \(description)", file: file, line: line)
    }

    private func state() throws -> [String: Any] {
        try XCTUnwrap(observedState(), "The fixture must expose a complete JSON state observation")
    }

    private func activityReviewFocus(after: Double,
                                    matching predicate: @escaping ([String: Any]) -> Bool = { _ in true }) throws -> [String: Any] {
        var matched: [String: Any]?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let state = observedState(), let observedAt = state["observedAt"] as? Double,
                  observedAt > after, let sheet = state["activityReviewSheet"] as? [String: Any],
                  sheet["visible"] as? Bool == true, sheet["key"] as? Bool == true,
                  predicate(sheet) else { return false }
            matched = sheet
            return true
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed { evidence("sleep-influences-focus-failure") }
        XCTAssertEqual(result, .completed, "Fresh sheet focus telemetry must confirm the actual input path")
        return try XCTUnwrap(matched, "Missing native review-sheet focus observation")
    }

    /// A transient AX gap is not a test failure. Predicate callers retry until
    /// their deadline, without required()/XCTUnwrap recording an early failure.
    private func observedState() -> [String: Any]? {
        let landing = app.windows.containing(.any, identifier: "ui-fixture-state").firstMatch
        guard landing.exists else { return nil }
        let element = landing.descendants(matching: .any)["ui-fixture-state"].firstMatch
        guard element.exists else { return nil }
        let raw = (element.value as? String).flatMap { $0.hasPrefix("{") ? $0 : nil } ?? element.label
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    private func waitForManualDeadline(_ deadline: Double, requestID: String) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = observedState(),
                  let actual = current["manualContinuousDeadline"] as? Double else { return false }
            return current["manualRequestID"] as? String == requestID
                && abs(actual - deadline) < 0.001
                && current["manual"] as? Bool == true && current["holding"] as? Bool == true
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed { evidence("manual-extension-deadline-failure") }
        XCTAssertEqual(result, .completed, "The clicked extension must change the same active request's exact deadline")
    }

    private func waitForState(_ expected: [String: Bool]) throws {
        var lastObserved: [String: Any]?
        let predicate = NSPredicate { [self] _, _ in
            guard let current = observedState() else { return false }
            lastObserved = current
            return expected.allSatisfy { key, value in current[key] as? Bool == value }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed { evidence("state-transition-failure") }
        XCTAssertEqual(result, .completed, "Expected fixture state \(expected); last observation \(String(describing: lastObserved))")
    }

    private func waitForSelectedManualMinutes(_ minutes: Int) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            observedState()?["selectedManualMinutes"] as? Int == minutes
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "The actual preset selection must become \(minutes) minutes")
    }

    private func verticalScrollValue(_ scroll: XCUIElement) -> String? {
        let scrollbar = scroll.scrollBars.firstMatch
        guard scrollbar.exists else { return nil }
        return scrollbar.value.map { String(describing: $0) }
    }

    private func measureSettingsContentFit(_ scroll: XCUIElement) throws -> [String: Any] {
        let viewport = scroll.frame
        XCTAssertTrue(isLayoutFrame(viewport), "Content-fit coverage requires a measured reading viewport")
        let types: [XCUIElement.ElementType] = [.staticText, .button, .radioButton, .checkBox,
            .switch, .toggle, .popUpButton, .comboBox, .menuButton, .toolbarButton,
            .textField, .secureTextField, .searchField, .textView, .slider, .stepper,
            .link, .tab, .menuItem, .tableRow, .outlineRow, .cell, .outline, .disclosureTriangle]
        var records: [[String: Any]] = []
        for type in types {
            let candidates = scroll.descendants(matching: type).allElementsBoundByIndex
            for candidate in candidates {
                let record = try XCTUnwrap(layoutElement(candidate, allowAnonymous: true, expectedType: type),
                    "Every expanded content text/control must have actual nonempty native bounds")
                let frame = candidate.frame
                XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1,
                    "Content-fit coverage cannot accept text/control hidden above the viewport")
                XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1,
                    "Content-fit coverage cannot accept text/control extending below the viewport")
                records.append(record)
            }
        }
        XCTAssertGreaterThan(records.count, 0, "An empty AX query cannot prove that expanded content fits")
        return ["coverage": "expanded content fits", "scrollObserved": false,
                "measuredElementCount": records.count, "elements": records,
                "readingViewportFrame": layoutFrame(viewport),
                "scope": "All measured native text and controls in the expanded current reading viewport; this is content-fit evidence, not a scrolling pass"]
    }

    private func assertFixedFrame(_ frame: CGRect, equals expected: CGRect, description: String) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 1, description)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 1, description)
        XCTAssertEqual(frame.width, expected.width, accuracy: 1, description)
        XCTAssertEqual(frame.height, expected.height, accuracy: 1, description)
    }

    private func headerScrollEvidence(_ name: String, window: XCUIElement, selectedTab: XCUIElement,
                                      scroll: XCUIElement, anchor: XCUIElement) throws {
        let startedAt = Date().timeIntervalSince1970
        let initialWindow = window.frame
        let navigationTargets = try settingsNavigationTargets()
        let navigationFrame = navigationTargets.reduce(CGRect.null) { $0.union($1.row.frame) }
        let pageHeading = try required("settings-page-heading")
        let observation: [String: Any] = ["schemaVersion": 2, "step": name,
            "testName": self.name, "fixtureBundleIdentifier": bundleID,
            "fixtureExecutablePath": expectedExecutablePath,
            "scope": "Current native Settings sidebar, titlebar, fixed page heading and reading viewport; pixel bleed requires screenshot review",
            "windowFrame": layoutFrame(initialWindow), "navigationFrame": layoutFrame(navigationFrame),
            "navigationRowFrames": navigationTargets.map { layoutFrame($0.row.frame) },
            "nativeToolbarFrame": layoutFrame(try nativeSettingsToolbar(in: window).frame),
            "navigationRowElements": navigationTargets.map {
                ["elementType": $0.row.elementType.rawValue, "identifier": $0.row.identifier,
                 "label": $0.row.label, "frame": layoutFrame($0.row.frame)] as [String: Any]
            },
            "captionCoverage": "Native sidebar row bounds and complete localized names are measured; pixel rendering still requires screenshot review",
            "selectedTabTitle": selectedTab.label.isEmpty ? selectedTab.title : selectedTab.label,
            "selectedTabFrame": layoutFrame(selectedTab.frame), "readingViewportFrame": layoutFrame(scroll.frame),
            "pageHeadingTitle": pageHeading.label.isEmpty ? pageHeading.title : pageHeading.label,
            "pageHeadingFrame": layoutFrame(pageHeading.frame),
            "contentAnchorLabel": anchor.label, "contentAnchorFrame": layoutFrame(anchor.frame),
            "verticalScrollbarValue": verticalScrollValue(scroll) ?? "unavailable",
            "captureStartedAt": startedAt]
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "\(name)-screenshot"; screenshot.lifetime = .keepAlways; add(screenshot)
        var completed = observation
        completed["captureFinishedAt"] = Date().timeIntervalSince1970
        completed["sameWindowFrame"] = window.frame == initialWindow
        if let data = try? JSONSerialization.data(withJSONObject: completed, options: [.sortedKeys]) {
            let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            geometry.name = "\(name)-header-geometry.json"; geometry.lifetime = .keepAlways; add(geometry)
        }
    }

    private func evidence(_ name: String) {
        guard let app else { return }
        let probe = app.descendants(matching: .any)["ui-fixture-state"].firstMatch
        if probe.exists {
            let raw = (probe.value as? String).flatMap { $0.hasPrefix("{") ? $0 : nil } ?? probe.label
            let state = XCTAttachment(string: raw)
            state.name = "\(name)-fixture-state"; state.lifetime = .keepAlways; add(state)
        }
        // Routine captures already retain complete typed geometry and state.
        // Dumping the entire app tree again at every resize/tab step duplicates
        // the same AX traversal. Keep that broad diagnostic for failures only;
        // no behavioral assertion or native screenshot is removed.
        let includeTree = name == "failure" || name.hasPrefix("missing-") || name.hasPrefix("not-hittable-")
        if includeTree {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name)-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
        }
        // Do not activate here: failure evidence must retain the observed focus.
        // App screenshots can span unbounded native menu descendants; prefer the scene container.
        let settingsWindow = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        // Native sheets can extend beyond their parent window. Bind the screenshot
        // and AX geometry to the presented sheet, not the window underneath it.
        let settingsSheet = settingsWindow.sheets.firstMatch
        let menuDialog = app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch
        let container = menuDialog.exists ? menuDialog : (settingsSheet.exists ? settingsSheet : (settingsWindow.exists ? settingsWindow : app.windows.firstMatch))
        if container.exists && !container.frame.isEmpty && !container.frame.isInfinite {
            let screenshotName = "\(name)-screenshot"
            let surface = menuDialog.exists ? "menu" : (settingsWindow.exists ? "settings" : "landing")
            let captureStartedAt = Date().timeIntervalSince1970
            let initialFrame = container.frame
            // Bind to this current container's AX elements once. No input or activation
            // occurs between layout observation and the corresponding screenshot.
            var layout = layoutObservation(container, step: screenshotName, surface: surface,
                                           windowFrame: initialFrame)
            layout["accessibilityTreeAttached"] = includeTree
            let screenshot = XCTAttachment(screenshot: container.screenshot())
            screenshot.name = screenshotName; screenshot.lifetime = .keepAlways; add(screenshot)
            let finalFrame = container.frame
            layout["captureStartedAt"] = captureStartedAt
            layout["captureFinishedAt"] = Date().timeIntervalSince1970
            layout["windowFrameAfterScreenshot"] = layoutFrame(finalFrame)
            layout["sameWindowFrame"] = initialFrame == finalFrame
            // XCTest exposes current AX queries and screenshots separately, not an
            // atomic combined snapshot. Frame stability is evidence, not a claim that
            // an occluded or moving view was frozen while it was observed.
            if let data = try? JSONSerialization.data(withJSONObject: layout, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "\(name)-layout.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func layoutObservation(_ container: XCUIElement, step: String, surface: String,
                                   windowFrame: CGRect) -> [String: Any] {
        let types: [XCUIElement.ElementType] = [.staticText, .button, .radioButton, .checkBox,
            .switch, .toggle, .popUpButton, .comboBox, .menuButton, .toolbarButton,
            .textField, .secureTextField, .searchField, .textView, .segmentedControl,
            .slider, .stepper, .link, .tab, .menuItem, .tableRow, .outlineRow, .cell, .outline]
        // AppKit headings can differ between legacy and modern AX types. A mixed
        // identity-bound result reused a window-button identity for a heading in
        // an observed XCTest failure. Resolve each type by its current query index.
        let appOwned = NSPredicate(format: "NOT (identifier BEGINSWITH %@)", "_XCUI:")
        var elements: [[String: Any]] = []
        var composites: [[String: Any]] = []
        var unmeasured: [[String: Any]] = []
        for type in types {
            let query = container.descendants(matching: type).matching(appOwned)
            let count = query.count
            for index in 0..<count {
                let candidate = query.element(boundBy: index)
                guard var record = layoutElement(candidate, expectedType: type) else {
                    unmeasured.append(["elementType": layoutType(type), "queryIndex": index,
                        "reason": "Typed AX element was unavailable, changed type, or had no nonempty measurable frame/label"])
                    continue
                }
                // Native parents and their child labels/segments have expected
                // overlap. Keep parents separate from independent leaf geometry.
                var childTypes: [String] = []
                if type != .staticText {
                    let children = candidate.children(matching: .any).matching(appOwned)
                    let childCount = children.count
                    for childIndex in 0..<childCount {
                        let child = children.element(boundBy: childIndex)
                        guard child.exists else {
                            unmeasured.append(["elementType": layoutType(type), "queryIndex": index,
                                "childQueryIndex": childIndex, "reason": "Direct child unavailable during observation"])
                            continue
                        }
                        if isLayoutFrame(child.frame) { childTypes.append(layoutType(child.elementType)) }
                    }
                }
                record["childTypes"] = childTypes
                record["composite"] = !childTypes.isEmpty
                record["ancestorIdentifiers"] = NSNull()
                record["parentIdentifier"] = NSNull()
                record["duplicateOf"] = NSNull()
                if childTypes.isEmpty { elements.append(record) }
                else { composites.append(record) }
            }
        }
        var scrollViews: [[String: Any]] = []
        var scrollMembership: [String: [[String: Any]]] = [:]
        let scrollQuery = container.descendants(matching: .scrollView).matching(appOwned)
        let scrollCount = scrollQuery.count
        for index in 0..<scrollCount {
            let scroll = scrollQuery.element(boundBy: index)
            if let record = layoutElement(scroll, allowAnonymous: true,
                                          expectedType: .scrollView) {
                scrollViews.append(record)
                let viewport: [String: Any] = ["queryIndex": scrollViews.count - 1,
                    "frame": record["frame"]!, "relationship": "typed-descendant-exact-match"]
                // Query actual descendants of this observed ScrollView. Geometry
                // alone cannot establish ancestry, especially for anonymous AX nodes.
                for type in types {
                    let descendants = scroll.descendants(matching: type).matching(appOwned)
                    for childIndex in 0..<descendants.count {
                        // Membership needs only the exact typed identity. The
                        // leaf pass already records enabled/hittable values;
                        // querying those actions again cannot add ancestry.
                        if let identity = layoutIdentity(descendants.element(boundBy: childIndex), expectedType: type) {
                            scrollMembership[identity, default: []].append(viewport)
                        }
                    }
                }
            } else {
                unmeasured.append(["elementType": "scrollView", "queryIndex": index,
                    "reason": "Scroll viewport unavailable or has no nonempty measurable frame"])
            }
        }
        for index in elements.indices {
            let matches = layoutIdentity(elements[index]).flatMap { scrollMembership[$0] } ?? []
            elements[index]["observedScrollViewport"] = matches.count == 1 ? matches[0] : NSNull()
        }
        for index in composites.indices {
            let matches = layoutIdentity(composites[index]).flatMap { scrollMembership[$0] } ?? []
            composites[index]["observedScrollViewport"] = matches.count == 1 ? matches[0] : NSNull()
        }
        return ["schemaVersion": 1, "step": step, "surface": surface,
                "containerIdentifier": container.identifier,
                "windowFrame": layoutFrame(windowFrame),
                "elements": elements, "compositeElements": composites, "scrollViews": scrollViews,
                "measurementCompleteness": unmeasured.isEmpty ? "complete" : "partial",
                "unmeasuredElements": unmeasured,
                "meta": ["provenance": ["sourceExecutableSHA256": "", "testName": self.name,
                    "fixtureBundleIdentifier": bundleID, "fixtureExecutablePath": expectedExecutablePath]],
                "coordinateSpace": "screenPoints",
                "schemaNotes": ["elementType is the public XCUIElement type name",
                    "elements contains nonempty leaf text and controls; native parents are in compositeElements",
                    "scrollViews describes viewports, so offscreen content can be distinguished from clipping",
                    "observedScrollViewport is a single exact typed descendant match; missing or ambiguous membership remains null",
                    "standard _XCUI: window chrome is excluded before resolving app-owned typed queries",
                    "unmeasuredElements is unknown evidence and must not be scored as a passed geometry check",
                    "null ancestry and duplicateOf mean unobserved, not an inferred relationship"]]
    }

    private func layoutIdentity(_ record: [String: Any]) -> String? {
        let keys = ["elementType", "identifier", "label", "valueString", "frame"]
        let identity = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            record[key].map { (key, $0) }
        })
        guard identity.count == keys.count,
              let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func layoutIdentity(_ element: XCUIElement, expectedType: XCUIElement.ElementType) -> String? {
        guard element.exists, let snapshot = try? element.snapshot(),
              snapshot.elementType == expectedType else { return nil }
        let frame = snapshot.frame
        guard isLayoutFrame(frame) else { return nil }
        return layoutIdentity(["elementType": layoutType(expectedType), "identifier": snapshot.identifier,
            "label": snapshot.label, "valueString": snapshot.value.map { String(describing: $0) } ?? "",
            "frame": layoutFrame(frame)])
    }

    private func layoutElement(_ element: XCUIElement, allowAnonymous: Bool = false,
                               expectedType: XCUIElement.ElementType? = nil) -> [String: Any]? {
        guard element.exists, let snapshot = try? element.snapshot() else { return nil }
        let type = snapshot.elementType
        guard expectedType == nil || type == expectedType else { return nil }
        let frame = snapshot.frame
        guard isLayoutFrame(frame) else { return nil }
        let identifier = snapshot.identifier
        let label = snapshot.label
        let value = snapshot.value.map { String(describing: $0) } ?? ""
        guard allowAnonymous || !identifier.isEmpty || !label.isEmpty || !value.isEmpty else { return nil }
        return ["identifier": identifier, "elementType": layoutType(type),
                "label": label, "valueString": value, "frame": layoutFrame(frame),
                "enabled": snapshot.isEnabled, "hittable": element.isHittable]
    }

    private func isLayoutFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && !frame.isInfinite && frame.origin.x.isFinite &&
        frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite
    }

    private func layoutFrame(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.origin.x), "y": Double(frame.origin.y),
         "width": Double(frame.size.width), "height": Double(frame.size.height)]
    }

    private func layoutType(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .staticText: "staticText"
        case .button: "button"
        case .radioButton: "radioButton"
        case .checkBox: "checkBox"
        case .switch: "switch"
        case .toggle: "toggle"
        case .popUpButton: "popUpButton"
        case .comboBox: "comboBox"
        case .menuButton: "menuButton"
        case .toolbarButton: "toolbarButton"
        case .textField: "textField"
        case .secureTextField: "secureTextField"
        case .searchField: "searchField"
        case .textView: "textView"
        case .segmentedControl: "segmentedControl"
        case .slider: "slider"
        case .stepper: "stepper"
        case .link: "link"
        case .tab: "tab"
        case .menuItem: "menuItem"
        case .tableRow: "tableRow"
        case .outlineRow: "outlineRow"
        case .cell: "cell"
        case .outline: "outline"
        case .scrollView: "scrollView"
        case .group: "group"
        case .other: "other"
        default: "xcuiType-\(type.rawValue)"
        }
    }
}
