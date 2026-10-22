import AppKit
import XCTest

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

    override func tearDownWithError() throws {
        if let app {
            // hasSucceeded is finalized after tearDown. Before that, a clean
            // running test can still report false; retain broad failure evidence
            // only when XCTest has actually recorded a failure or exception.
            if (testRun?.totalFailureCount ?? 0) > 0 { evidence("failure") }
            app.terminate()
        }
    }

    func testLightAppearanceMenuAndThreeSettingsPages() throws {
        try launch(language: "ko", scenario: "ac", appearance: "light")
        let application = try XCTUnwrap(try state()["application"] as? [String: Any])
        XCTAssertEqual(application["effectiveAppearance"] as? String, NSAppearance.Name.aqua.rawValue,
                       "The isolated fixture must actually render Aqua without changing the system appearance")
        try openMenu()
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-open-settings").firstMatch,
                                 description: "Light appearance native menu panel")
        let controls = try ["panel-automatic", "manual-duration-picker", "panel-start-manual",
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
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Light appearance native Settings window")
        for (page, title) in [("general", "잠자기 방지"), ("safety", "자동 시작"), ("system", "앱 설정")] {
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
        try selectPage("system", title: "App settings")
        let menuDisplay = try revealSettingsControl(try required("settings-menu-bar-display"))
        menuDisplay.click()
        try required(app.menuItems["Icon + time remaining"], description: "Menu bar remaining-time option").click()
        try waitForState(["menuBarDetails": true, "manual": true, "holding": true])
        evidence("remaining-time-option-settings")
        try selectPage("safety", title: "Automatic start")
        try required("settings-automatic-rules").click()
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
        let row = try revealSettingsControl(try required("keep-display-awake-toggle"))
        // The identifier belongs to the full row. Its center is the label, not
        // necessarily the native switch on the right-hand side.
        let toggle = try required(row.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d OR elementType == %d",
            XCUIElement.ElementType.checkBox.rawValue, XCUIElement.ElementType.switch.rawValue,
            XCUIElement.ElementType.toggle.rawValue)).firstMatch, description: "Actual display-awake toggle")
        XCTAssertEqual(toggle.label, "덮개가 열려 있을 때 화면 켜두기")
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
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let after = Date().timeIntervalSince1970
        edge.click(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: -600, dy: 0)))
        _ = try settingsGeometry(after: after, description: "core-settings-minimum-width") {
            abs($0.frame.width - 560) <= 1
        }
        try selectPage("system", title: "App settings")
        XCTAssertFalse(window.descendants(matching: .any)["settings-shortcuts-details"].exists)
        XCTAssertEqual(window.popUpButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shortcut-key-")).count, 0)
        try expandSettingsDisclosure("settings-other-app-requests-details")
        XCTAssertTrue(try required("settings-review-sleep-influences").exists)
        try selectPage("general", title: "Keep awake")
        XCTAssertTrue(try required("keep-display-awake-toggle").exists)
        XCTAssertTrue(try required("settings-lock-policy-note").exists)
        try selectPage("safety", title: "Automatic start")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        evidence("english-core-settings-minimum-width")
    }

    func testSettingsScrollKeepsHeadersFixedAcrossAllPages() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        let window = try activateSettingsWindow()
        let pages = [("general", "잠자기 방지", ["settings-protection-rules-details", "settings-work-rules-details"]),
                     ("safety", "자동 시작", ["settings-automatic-behavior-details"]),
                     ("system", "앱 설정", ["settings-protection-alerts-details",
                        "settings-helper-details", "settings-updates-details", "settings-records-diagnostics-details"])]
        for (page, title, disclosures) in pages {
            try selectPage(page, title: title)
            for identifier in disclosures { try expandSettingsDisclosure(identifier) }
            let scroll = try settingsPageScrollView()
            scroll.scroll(byDeltaX: 0, deltaY: 4000)
            let navigation = try required("settings-navigation")
            let heading = try required("settings-page-heading")
            let initialNavigation = navigation.frame
            let initialHeading = heading.frame
            let anchor = scroll.staticTexts.firstMatch
            try required(anchor, description: "Readable content anchor on \(page)")
            let initialAnchor = anchor.frame
            let initialPosition = verticalScrollValue(scroll)
            try assertSettingsPageLayout(window, page: page, title: title)
            headerScrollEvidence("scroll-\(page)-top", window: window, navigation: navigation,
                                 heading: heading, scroll: scroll, anchor: anchor)
            scroll.scroll(byDeltaX: 0, deltaY: -160)
            assertFixedFrame(navigation.frame, equals: initialNavigation, description: "\(page) tabs at middle")
            assertFixedFrame(heading.frame, equals: initialHeading, description: "\(page) heading at middle")
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
            if !contentMoved && page == "safety" {
                // This tab can fit even after its only disclosure is expanded.
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
            headerScrollEvidence("scroll-\(page)-middle", window: window, navigation: navigation,
                                 heading: heading, scroll: scroll, anchor: anchor)
            scroll.scroll(byDeltaX: 0, deltaY: -4000)
            assertFixedFrame(navigation.frame, equals: initialNavigation, description: "\(page) tabs at end")
            assertFixedFrame(heading.frame, equals: initialHeading, description: "\(page) heading at end")
            try assertSettingsPageLayout(window, page: page, title: title)
            let endAnchor = anchor.frame
            let endPosition = verticalScrollValue(scroll)
            // Another down gesture must leave the endpoint unchanged. Capture
            // geometry plus actual native pixels for the separate bleed review.
            scroll.scroll(byDeltaX: 0, deltaY: -4000)
            XCTAssertEqual(anchor.frame, endAnchor, "The final screenshot must be at the stable content endpoint")
            XCTAssertEqual(verticalScrollValue(scroll), endPosition)
            headerScrollEvidence("scroll-\(page)-end", window: window, navigation: navigation,
                                 heading: heading, scroll: scroll, anchor: anchor)
        }
    }

    func testSettingsDisclosureExpansionSurvivesNativeTabRoundtrips() throws {
        try launch(language: "ko", scenario: "ac")
        try openSettings()
        let before = try state()
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Compact Settings window")
        let pages = [("general", "잠자기 방지", "settings-protection-rules-details"),
                     ("safety", "자동 시작", "settings-automatic-behavior-details"),
                     ("system", "앱 설정", "settings-records-diagnostics-details")]
        for (page, title, identifier) in pages {
            try selectPage(page, title: title)
            try expandSettingsDisclosure(identifier)
            try assertSettingsPageLayout(window, page: page, title: title)
        }
        // Each page view is replaced on selection. Its window-owned disclosure
        // state must survive the actual segment actions, not just a binding copy.
        for (page, title, identifier) in pages {
            try selectPage(page, title: title)
            let triangle = try revealSettingsControl(try disclosureTriangle(identifier))
            try assertDisclosureExpanded(triangle)
            try assertSettingsPageLayout(window, page: page, title: title)
            evidence("settings-\(page)-disclosure-retained")
        }
        // An intentional collapse must persist too; preserving state must not
        // become an unconditional expand-on-return behavior.
        let diagnostics = try revealSettingsControl(try disclosureTriangle("settings-records-diagnostics-details"))
        try clickSettingsDisclosure(diagnostics)
        try assertDisclosureCollapsed(diagnostics)
        try selectPage("general", title: "잠자기 방지")
        try selectPage("system", title: "앱 설정")
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
        try required("settings-navigation")
        try waitForSettingsFocus(isWindow: target.isWindow, className: target.className,
                                 identity: target.identity)
        evidence("settings-keyboard-reopen-retains-target")
    }

    func testKeyboardFirstSettingsOpeningAndDurationMenuSelection() throws {
        try launch(language: "en", scenario: "ac")
        app.activate()
        // Do not click a landing button or title bar before the first keyboard opening.
        app.typeKey(",", modifierFlags: .command)
        try required("settings-navigation")
        let target = try settingsFocusAfterFreshObservation()
        app.typeKey(",", modifierFlags: .command)
        try waitForSettingsFocus(isWindow: target.isWindow, className: target.className,
                                 identity: target.identity)
        evidence("settings-first-keyboard-opening")

        // Give the native segmented navigation keyboard focus, then change
        // actual pages horizontally. Keep macOS keyboard-navigation unchanged.
        try navigationControl("general", title: "Keep awake").action.click()
        var navigationTarget = try settingsFocusAfterFreshObservation()
        // Native key-view order may enter the page first. Observe the bounded
        // reverse/forward path before sending arrows to a segmented responder.
        for reverse in [true, false] {
            for attempt in 0..<8 where !isNativeSettingsNavigationResponder(navigationTarget) {
                app.typeKey(.tab, modifierFlags: reverse ? .shift : [])
                navigationTarget = try settingsFocusAfterFreshObservation()
                let observation = XCTAttachment(string:
                    "direction=\(reverse ? "reverse" : "forward") attempt=\(attempt + 1) "
                    + "isWindow=\(navigationTarget.isWindow) class=\(navigationTarget.className) identity=\(navigationTarget.identity)")
                observation.name = "settings-segment-focus-\(reverse ? "reverse" : "forward")-\(attempt + 1)"
                observation.lifetime = .keepAlways
                add(observation)
            }
        }
        XCTAssertTrue(isNativeSettingsNavigationResponder(navigationTarget),
                      "Arrow input requires a native segmented/radio responder, not \(navigationTarget.className)")
        // Native segmented controls keep keyboard focus separate from selection.
        // Activate the key segment first; reverse Tab need not enter at the
        // segment previously selected with the pointer.
        app.typeKey(" ", modifierFlags: [])
        _ = try settingsFocusAfterFreshObservation()
        let pages = ["general", "safety", "system"]
        let selected = pages.filter { app.descendants(matching: .any)["settings-page-\($0)"].exists }
        XCTAssertEqual(selected.count, 1, "Keyboard activation must leave one real page selected")
        var position = try XCTUnwrap(selected.first.flatMap { pages.firstIndex(of: $0) })
        for (key, delta) in [(XCUIKeyboardKey.rightArrow, 1), (.rightArrow, 1),
                            (.leftArrow, -1), (.leftArrow, -1)] {
            XCTAssertTrue(isNativeSettingsNavigationResponder(try settingsFocusAfterFreshObservation()),
                          "Keyboard movement and activation must stay on the native tab control")
            app.typeKey(key, modifierFlags: [])
            app.typeKey(" ", modifierFlags: [])
            position = (position + delta + pages.count) % pages.count
            try assertSelectedPage(pages[position])
        }
        evidence("settings-segment-real-keyboard-selection")

        let settings = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
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
        if !app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch.exists {
            try openMenu()
        }
        XCTAssertEqual(try required("panel-end-manual").label, "타이머 끝내기")
        evidence("gallery-menu-manual")
        try required("panel-end-manual").click()
        let picker = try required("manual-duration-picker")
        picker.click()
        let presetMenu = try assertDurationMenuOptions(["30분", "1시간", "2시간", "끄기 전까지"],
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
        let general = try required("settings-page-general")
        XCTAssertFalse(general.descendants(matching: .any)["settings-manual-duration-picker"].exists,
                       "Manual duration selection must live only in the menu bar")
        XCTAssertFalse(general.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR title == %@", "유지 시간", "유지 시간")).firstMatch.exists,
            "General settings must not retain the manual duration row")
        evidence("gallery-settings-general")
        XCTAssertFalse(app.descendants(matching: .any)["closed-lid-disconnect-picker"].exists,
                       "The unplug action is hidden while closed-lid work is off")
        try selectPage("safety", title: "자동 시작")
        evidence("gallery-settings-safety")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        try expandSettingsDisclosure("settings-automatic-behavior-details")
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-rehearsal"].exists)
        evidence("gallery-settings-safety-details")
        try selectPage("system", title: "앱 설정")
        try expandSettingsDisclosure("settings-protection-alerts-details")
        try required(app.checkBoxes["수동 유지 종료 알림"], description: "Independent manual expiry notification")
        try required(app.checkBoxes["만료 5분 전 예고"], description: "Optional expiry warning")
        try required(app.checkBoxes["과열·상태 확인 실패"], description: "Thermal and observation protection alerts")
        try required(app.checkBoxes["배터리 부족"], description: "Battery protection alerts")
        XCTAssertFalse(app.buttons["Tether 사용법…"].exists, "The separate guide button must be removed")
        XCTAssertFalse(app.sheets.firstMatch.exists, "App settings must not open a separate guide sheet")
        evidence("gallery-settings-system")
        try expandSettingsDisclosure("settings-helper-details")
        try expandSettingsDisclosure("settings-records-diagnostics-details")
        try expandSettingsDisclosure("settings-updates-details")
        try expandSettingsDisclosure("settings-other-app-requests-details")
        let review = try required(app.buttons["settings-review-sleep-influences"], description: "Sleep influences button")
        XCTAssertTrue([review.label, review.title].contains("다른 앱의 잠자기 방지 요청 확인"),
                      "The compact Review action must retain its full accessible purpose")
        let scroll = try settingsPageScrollView()
        for _ in 0..<4 where !review.isHittable {
            XCTAssertTrue(scroll.exists, "Lower settings must have a native scroll view")
            scroll.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(review.isHittable)
        evidence("gallery-settings-system-details")
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
        try selectPage("system", title: "앱 설정")
        try expandSettingsDisclosure("settings-other-app-requests-details")
        let review = try required(app.buttons["settings-review-sleep-influences"], description: "Sleep influences button")
        XCTAssertTrue([review.label, review.title].contains("다른 앱의 잠자기 방지 요청 확인"),
                      "The compact Review action must retain its full accessible purpose")
        let scroll = try settingsPageScrollView()
        for _ in 0..<4 where !review.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -240) }
        waitForHittable(review, description: "Sleep influences button")
        let pointerOpened = Date().timeIntervalSince1970
        review.click()
        let settings = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
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
        try required("ui-fixture-open-welcome").click()
        try required("welcome-content")
        let observation = try XCTUnwrap(try state()["welcomeWindow"] as? [String: Any])
        let minimum = try XCTUnwrap(observation["contentMinSize"] as? [String: Any])
        let frame = try XCTUnwrap(observation["contentRect"] as? [String: Any])
        XCTAssertEqual(minimum["width"] as? Double ?? 0, 560, accuracy: 1)
        XCTAssertEqual(frame["width"] as? Double ?? 0, 560, accuracy: 1)
        XCTAssertEqual(frame["height"] as? Double ?? 0, 448, accuracy: 1)
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
        try selectPage("system", title: "앱 설정")
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
        XCTAssertGreaterThan(list.frame.height, 108,
                             "Two complete three-line records need more than the old 108pt estimate")
        XCTAssertLessThanOrEqual(last.frame.maxY, list.frame.maxY + 1)
        evidence("history-natural-height")
        try expandSettingsDisclosure("settings-other-app-requests-details")
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
        try selectPage("system", title: "앱 설정")
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
        try assertDisclosureCollapsed(diagnostics)
        XCTAssertEqual(try assertActiveRecording(), deadline,
            "Collapsing diagnostics must retain the original visible deadline")
        evidence("recording-active-details-collapsed")

        try selectPage("general", title: "잠자기 방지")
        try selectPage("system", title: "앱 설정")
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
        let automatic = try required("panel-automatic")
        XCTAssertEqual(automatic.label, "Allow automatic starts")
        XCTAssertGreaterThanOrEqual(automatic.frame.height, 16)
        try setAutomatic(false)
        try waitForState(["automatic": false, "manual": false, "holding": false])

        let start = try required("panel-start-manual")
        XCTAssertEqual(start.label, "Start manual session")
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
        XCTAssertEqual(end.label, "End timer")
        XCTAssertFalse(app.descendants(matching: .any)["manual-duration-picker"].firstMatch.isHittable,
                       "Presets must not appear during an active timer")
        let activeDetails = try disclosureTriangle("panel-active-work-details")
        try assertDisclosureCollapsed(activeDetails)
        let beforeReadingDetails = try state()
        try expandMenuDisclosure("panel-active-work-details")
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
        if !app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch.exists {
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
            expected: ["30 min", "1 h", "2 h", "Until turned off"],
            selected: "1 h", evidenceName: "menu-v5-manual-presets", inSettings: false)
        try waitForState(["manual": false, "holding": true])
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        try openSettingsFromMenu()
        XCTAssertFalse(app.descendants(matching: .any)["automatic-ac-toggle"].exists,
                       "Stay Awake must link to automatic settings without duplicating its master switch")
        try revealSettingsControl(try required("settings-go-to-automatic")).click()
        try required("settings-page-safety")
        XCTAssertTrue(try required("automatic-ac-toggle").exists)
        XCTAssertTrue(try required("settings-automatic-rules").exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-power-condition"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["automatic-battery-duration-picker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["manual-battery-continuation-toggle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-manual-duration-picker"].exists)
        try expandSettingsDisclosure("settings-automatic-behavior-details")
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-rehearsal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-rehearsal-sheet"].exists)
        try selectPage("system", title: "App settings")
        XCTAssertFalse(app.descendants(matching: .any)["settings-open-history"].exists)
        try expandSettingsDisclosure("settings-updates-details")
        XCTAssertFalse(app.descendants(matching: .any)["update-after-work-schedule"].exists)
        XCTAssertEqual(try state()["selectedManualMinutes"] as? Int, 60)
        evidence("settings-core-features-without-retired-extras")
    }

    func testDesktopSettingsOmitBatteryAndClosedLidControls() throws {
        try launch(language: "en", scenario: "desktop")
        try openSettings()
        try required("settings-page-general")
        XCTAssertFalse(app.staticTexts["Manual session"].exists,
                       "Desktop settings must omit the empty manual session section")
        XCTAssertFalse(app.descendants(matching: .any)["settings-manual-duration-picker"].exists,
                       "Manual duration selection must live only in the menu bar")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Keep working with the lid closed")).firstMatch.exists)
        try expandSettingsDisclosure("settings-protection-rules-details")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Stop below")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Thermal protection"].exists)
        try selectPage("system", title: "App settings")
        try expandSettingsDisclosure("settings-protection-alerts-details")
        XCTAssertFalse(app.checkBoxes["Battery protection"].exists,
                       "Expanding alerts must not reveal a battery option on a desktop Mac")
        evidence("desktop-settings")
    }

    func testDesktopRetiredBatteryChoiceRequiresExplicitACAutomaticOn() throws {
        try launch(language: "en", scenario: "desktopBatteryCondition")
        try waitForState(["automatic": false, "manual": false, "holding": false, "paused": false])
        try openSettings()
        XCTAssertFalse(app.descendants(matching: .any)["closed-lid-allow-toggle"].exists)
        try selectPage("safety", title: "Automatic start")
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
        try expandSettingsDisclosure("settings-protection-rules-details")
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
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch,
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
        try required("settings-page-general")
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
        let menu = app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch
        for _ in 0..<4 where !review.isHittable {
            let scroll = menu.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists, "Overflowing recovery advice needs a scroll body")
            scroll.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(review.isHittable)
        XCTAssertEqual(review.label, "앱 설정에서 진단…")
        review.click()
        try required("settings-page-system")
        XCTAssertTrue(try required("settings-error-context").isHittable,
                      "The common diagnostics entry must retain the request's error context")
        evidence("generic-error-diagnostics-destination")
    }

    func testClosedLidSetupReviewOpensAppSettingsWithoutBatteryFallback() throws {
        try launch(language: "en", scenario: "lidSetup")
        try waitForState(["automatic": true, "automaticActive": true, "manual": false, "holding": true])
        let before = try state()
        try openMenu()
        XCTAssertTrue(try required("panel-current-work-section").exists,
                      "General automatic work remains available while the closed-lid helper needs preparation")
        let reviewedAt = Date().timeIntervalSince1970
        try required("panel-review-settings").click()
        try required("settings-navigation")
        try required("settings-page-system")
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
        let menu = app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch
        try expandMenuDisclosure("panel-problem-details")
        let start = try required("panel-start-manual")
        let automatic = try required("panel-automatic")
        let scroll = menu.scrollViews.firstMatch
        if !start.isHittable {
            XCTAssertTrue(scroll.waitForExistence(timeout: 3), "Overflowing content needs an accessible scroll body")
            for _ in 0..<4 where !start.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: -240)
            }
        }
        XCTAssertTrue(start.isHittable, "Manual controls must remain reachable below a long warning")
        XCTAssertTrue(automatic.isHittable, "Automatic control must remain reachable in the scroll body")
        automatic.click()
        try waitForState(["automatic": false, "manual": false, "holding": false, "paused": false])
        XCTAssertTrue(try required("panel-open-settings").isHittable)
        XCTAssertFalse(app.buttons["panel-pause-all"].exists,
                       "An inactive compact panel must not show an unnecessary Stop all action")
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
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Native Settings window")
        let titles = language == "ko" ? ["잠자기 방지", "자동 시작", "앱 설정"]
                                       : ["Keep awake", "Automatic start", "App settings"]
        if minimumSize {
            try verifySettingsResize(window, evidenceName: "settings-first-open")
            try assertSettingsPageLayout(window, page: "general", title: titles[0], minimumViewport: true)
        }
        let pages = ["general", "safety", "system"]
        let navigation = try required("settings-navigation")
        var frames: [CGRect] = []
        for (page, title) in zip(pages, titles) {
            let target = try navigationControl(page, title: title)
            let control = target.row
            XCTAssertTrue(target.action.isHittable, "\(title) must be clickable in the native window")
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
            XCTAssertTrue(navigation.frame.insetBy(dx: -1, dy: -1).contains(control.frame),
                          "Each native segment must remain inside the top navigation")
            let visibleTitle = title
            let textWidth = (visibleTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            XCTAssertGreaterThanOrEqual(control.frame.width + 1, textWidth, "\(visibleTitle) has insufficient room for its visible label")
            XCTAssertGreaterThanOrEqual(control.frame.height, 20)
            for earlier in frames {
                XCTAssertFalse(earlier.insetBy(dx: 1, dy: 1).intersects(control.frame.insetBy(dx: 1, dy: 1)), "Top navigation segments overlap")
            }
            frames.append(control.frame)
            // The native segment above is already resolved and validated. Do
            // not repeat activation, title checks and descendant queries.
            target.action.click()
            try assertSelectedPage(page)
            try assertSettingsPageLayout(window, page: page, title: title)
            try assertPreviewIndicator(in: window, avoiding: [navigation])
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
        try required("settings-navigation")
        let reopened = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                    description: "Reopened native Settings window")
        _ = try settingsGeometry(after: reopening, description: "settings-\(language)-reopened-presentation")
        try assertSelectedPage("system")
        try assertSettingsPageLayout(reopened, page: "system", title: titles[2])
        if minimumSize {
            try verifySettingsResize(reopened, evidenceName: "settings-reopened")
            try assertSettingsPageLayout(reopened, page: "system", title: titles[2], minimumViewport: true)
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
        let contentMinimum: CGSize
        let frameMinimum: CGSize

        init?(_ state: [String: Any], after: Double) {
            guard let observedAt = state["observedAt"] as? Double, observedAt > after,
                  let window = state["settingsWindow"] as? [String: Any],
                  window["key"] as? Bool == true, window["visible"] as? Bool == true,
                  window["isResizable"] as? Bool == true, window["inLiveResize"] as? Bool == false,
                  let frame = Self.size(window["frame"]), frame.width > 0, frame.height > 0,
                  let contentRect = Self.size(window["contentRect"]), contentRect.width > 0, contentRect.height > 0,
                  let contentMinimum = Self.size(window["contentMinSize"]),
                  let frameMinimum = Self.size(window["minSize"]) else { return nil }
            self.frame = frame; self.contentRect = contentRect
            self.contentMinimum = contentMinimum; self.frameMinimum = frameMinimum
        }

        var minimumFrame: CGSize {
            // NSWindow's content minimum excludes native titlebar chrome. Its
            // frame minimum can impose an additional bound; honor both readings.
            CGSize(width: max(frameMinimum.width, contentMinimum.width + max(0, frame.width - contentRect.width)),
                   height: max(frameMinimum.height, contentMinimum.height + max(0, frame.height - contentRect.height)))
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
        XCTAssertEqual(initial.contentMinimum.width, 560, accuracy: 1)
        XCTAssertEqual(initial.contentMinimum.height, 480, accuracy: 1)
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
        // and compare both axes to the observed content/frame minima, not 480pt
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
        XCTAssertEqual(minimum.contentMinimum.width, 560, accuracy: 1)
        XCTAssertEqual(minimum.contentMinimum.height, 480, accuracy: 1)
        XCTAssertEqual(window.frame.width, 560, accuracy: 1,
                       "A drag must resize Settings to its real minimum; an unchanged default window is not sufficient")
        XCTAssertEqual(window.frame.width, minimum.frame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, minimum.frame.height, accuracy: 1)
        evidence("\(evidenceName)-minimum-height")
    }

    private func assertSettingsPageLayout(_ window: XCUIElement, page: String, title: String,
                                          minimumViewport: Bool = false) throws {
        let navigation = try required("settings-navigation")
        let heading = try required("settings-page-heading")
        XCTAssertTrue([heading.label, heading.title, heading.value as? String ?? ""].contains(title),
                      "The fixed heading must identify the selected page in the current language")
        XCTAssertTrue(heading.isHittable, "The fixed heading must remain visible after native presentation")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(heading.frame),
                      "The fixed page heading must fit inside Settings")
        let body = try required("settings-page-\(page)")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(body.frame),
                      "The entire reading viewport must fit inside Settings")
        XCTAssertGreaterThanOrEqual(heading.frame.minY, navigation.frame.maxY - 1,
                                   "The page heading must remain below the fixed top navigation")
        XCTAssertGreaterThanOrEqual(body.frame.minY, navigation.frame.maxY - 1,
                                   "The reading viewport must remain below the fixed top navigation")
        XCTAssertLessThanOrEqual(heading.frame.maxY, body.frame.minY + 1,
                                 "Scrollable content must not overlap the fixed page heading")
        let close = try required(window.buttons[XCUIIdentifierCloseWindow], description: "Settings close button")
        XCTAssertTrue(close.isEnabled && close.isHittable, "Native presentation must preserve an enabled, reachable close button")
        XCTAssertGreaterThanOrEqual(heading.frame.minY, close.frame.maxY - 1,
                                   "The fixed heading must remain below the native titlebar controls")
        if minimumViewport {
            XCTAssertLessThanOrEqual(body.frame.minY - heading.frame.maxY, 36,
                                     "The compact page must not leave an unused gap below its heading")
            XCTAssertGreaterThanOrEqual(body.frame.height, window.frame.maxY - body.frame.minY - 24,
                                       "The page must fill the remaining visible reading area")
        }
    }

    private struct SettingsNavigationTarget {
        let row: XCUIElement
        let action: XCUIElement
    }

    private func navigationControl(_ page: String, title: String) throws -> SettingsNavigationTarget {
        try activateSettingsWindow()
        let navigation = try required("settings-navigation")
        // Native Picker(.segmented) can expose its AppKit host as a segmented
        // control or a radio group. A generic group/label is not sufficient.
        let nativeNavigation: XCUIElement
        let navigationTypes: [XCUIElement.ElementType] = [.segmentedControl, .radioGroup]
        if navigationTypes.contains(navigation.elementType) {
            nativeNavigation = navigation
        } else {
            let hosts = navigationTypes.flatMap {
                navigation.descendants(matching: $0).allElementsBoundByIndex
            }
            nativeNavigation = try XCTUnwrap(hosts.count == 1 ? hosts.first : nil,
                "Settings navigation must contain one native segmented/radio control")
        }
        let identifier = "settings-tab-\(page)"
        let titlePredicate = NSPredicate(format: "label == %@ OR title == %@ OR value == %@",
                                         title, title, title)
        let identified = nativeNavigation.descendants(matching: .any)[identifier].firstMatch
        let segmentTypes: [XCUIElement.ElementType] = [.radioButton, .button]
        let row: XCUIElement
        if identified.exists && segmentTypes.contains(identified.elementType) {
            row = try required(identified, description: "Native Settings segment \(title)")
        } else {
            // A child's identifier may be retained on StaticText. Resolve its
            // unique native segment, never treat the text itself as the button.
            var segment: XCUIElement?
            for type in segmentTypes {
                let matches = nativeNavigation.descendants(matching: type).allElementsBoundByIndex.filter { candidate in
                    candidate.identifier == identifier
                        || candidate.descendants(matching: .any)[identifier].firstMatch.exists
                        || [candidate.label, candidate.title, candidate.value as? String ?? ""].contains(title)
                        || candidate.descendants(matching: .staticText).matching(titlePredicate).firstMatch.exists
                }
                if matches.isEmpty { continue }
                segment = try XCTUnwrap(matches.count == 1 ? matches.first : nil,
                    "The compact navigation must contain one native \(type) for \(title)")
                break
            }
            row = try required(try XCTUnwrap(segment,
                "No identified or fully named native Settings segment exists for \(title)"),
                description: "Native Settings segment \(title)")
        }
        let fullTitle = row.descendants(matching: .staticText).matching(titlePredicate)
        if ![row.label, row.title, row.value as? String ?? ""].contains(title) {
            XCTAssertEqual(fullTitle.count, 1,
                           "The native segment must expose the full localized accessibility name \(title)")
            try required(fullTitle.firstMatch, description: "Full localized segment name \(title)")
        }
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Settings window containing native segment \(title)")
        XCTAssertTrue(nativeNavigation.frame.insetBy(dx: -1, dy: -1).contains(row.frame),
                      "The semantic segment must fit inside its native control")
        XCTAssertTrue(navigation.frame.insetBy(dx: -1, dy: -1).contains(row.frame),
                      "The semantic segment must fit inside the top navigation")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(row.frame),
                      "The semantic segment must fit inside Settings")
        let visibleTitle = testLanguage == "en" && page == "general" ? "Work" : title
        let visibleText = row.descendants(matching: .staticText).matching(NSPredicate(
            format: "label == %@ OR title == %@ OR value == %@", visibleTitle, visibleTitle, visibleTitle))
        if visibleText.firstMatch.exists {
            XCTAssertEqual(visibleText.count, 1, "The native segment must expose one complete visible title")
            let text = visibleText.firstMatch
            let textWidth = (visibleTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            XCTAssertGreaterThanOrEqual(text.frame.width + 1, textWidth,
                                       "The visible segment must allocate room for \(visibleTitle)")
            XCTAssertTrue(row.frame.insetBy(dx: -1, dy: -1).contains(text.frame),
                          "The visible title must remain inside its semantic segment")
        }
        waitForHittable(row, description: "Native Settings segment \(title)")
        XCTAssertTrue(row.isEnabled, "The native segment must be an enabled input target for \(title)")
        return SettingsNavigationTarget(row: row, action: row)
    }

    @discardableResult
    private func activateSettingsWindow() throws -> XCUIElement {
        // Activate and raise this window, rather than whichever fixture window was
        // last key. A real title-bar click also makes foreground interference visible.
        activateFixture()
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Native Settings window to activate")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12)).click()
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
        for other in ["general", "safety", "system"] where other != page {
            XCTAssertFalse(app.descendants(matching: .any)["settings-page-\(other)"].exists,
                           "Selecting \(page) must change the real page")
        }
    }

    private func openSettings() throws {
        try required("ui-fixture-open-settings").click()
        try required("settings-navigation")
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
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch,
                                 description: "Menu panel containing current work details")
        try expandMenuDisclosure("panel-active-work-details")
        let summary = try required(panel.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@", expected, expected, expected)).firstMatch,
            description: "Expanded closed-lid unplug summary")
        let text = [summary.label, summary.title, summary.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(text.contains(expected),
                      "The current unplug summary must preserve OS delegation and valid battery-work conditions")
        XCTAssertTrue(summary.isHittable, "Expanded unplug guidance must be visible inside the actual menu panel")
        evidence(evidenceName)
        let triangle = try disclosureTriangle("panel-active-work-details")
        triangle.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: min(7, triangle.frame.height / 2))).click()
        try assertDisclosureCollapsed(triangle)
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

    private func settingsFocusAfterFreshObservation() throws -> (isWindow: Bool, className: String, identity: String) {
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
        return (isWindow, className, identity)
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

    private func isNativeSettingsNavigationResponder(_ target: (isWindow: Bool, className: String, identity: String)) -> Bool {
        // A Form control or generic hosting view reached by Tab is not the
        // segmented tab target for keyboard movement and activation.
        !target.isWindow && (target.className.contains("Segmented") || target.className.contains("RadioButton"))
    }

    private func openSettingsFromMenu() throws {
        try required("panel-open-settings").click()
        try required("settings-navigation")
    }

    private func setAutomatic(_ enabled: Bool) throws {
        if try state()["automatic"] as? Bool != enabled { try required("panel-automatic").click() }
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

    private func disclosureTriangle(_ identifier: String) throws -> XCUIElement {
        // Expanded SwiftUI disclosures can propagate the same identifier to
        // their text children. Resolve the actual native input type first.
        let identifiedTriangles = app.descendants(matching: .disclosureTriangle).matching(identifier: identifier)
        let identifiedCount = identifiedTriangles.count
        let initial: XCUIElement
        if identifiedCount > 0 {
            XCTAssertEqual(identifiedCount, 1, "The disclosure identifier must resolve to one native triangle")
            initial = try required(identifiedTriangles.firstMatch, description: "Typed disclosure triangle \(identifier)")
        } else {
            let control = try required(identifier)
            initial = try required(control.elementType == .disclosureTriangle ? control
                : control.descendants(matching: .disclosureTriangle).firstMatch,
                description: "Native disclosure triangle \(identifier)")
        }
        // SwiftUI moves the identifier to a containing Group when expanded.
        // Keep the query on the native triangle, whose header remains unique,
        // instead of letting Any.firstMatch silently retarget that Group.
        let triangles = app.descendants(matching: .disclosureTriangle).matching(
            NSPredicate(format: "label == %@", initial.label))
        XCTAssertEqual(triangles.count, 1, "The identified disclosure must have one native header")
        return try required(triangles.firstMatch, description: "Typed disclosure triangle \(identifier)")
    }

    private func expandSettingsDisclosure(_ identifier: String) throws {
        let triangle = try disclosureTriangle(identifier)
        try assertDisclosureCollapsed(triangle)
        try revealSettingsControl(triangle)
        try clickSettingsDisclosure(triangle)
        try assertDisclosureExpanded(triangle)
    }

    private func clickSettingsDisclosure(_ triangle: XCUIElement) throws {
        if triangle.identifier == "settings-helper-details" {
            // This existing helper primitive is a separate native one-line
            // DisclosureGroup, not SettingsDisclosure's 35.5pt HStack header.
            // Its observed 15pt AX bounds are the title itself, with no child
            // StaticText. Validate that measured shape before using its arrow;
            // this is an explicit control path, never a missing-title fallback.
            XCTAssertFalse(triangle.label.isEmpty, "The native helper disclosure must expose its title")
            XCTAssertTrue(isLayoutFrame(triangle.frame))
            XCTAssertGreaterThanOrEqual(triangle.frame.height, 12)
            XCTAssertLessThanOrEqual(triangle.frame.height, 20,
                                     "Only the observed one-line helper title can use this measured arrow click")
            XCTAssertEqual(triangle.descendants(matching: .staticText).count, 0,
                           "A changed helper layout requires an explicit click-target review")
            let point = CGPoint(x: triangle.frame.minX + 26, y: triangle.frame.midY)
            let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
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
        let window = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                  description: "Settings containing the disclosure arrow")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(point),
                      "The measured native disclosure arrow must be inside Settings")
        triangle.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: titleFrame.midY - triangleFrame.minY)).click()
    }

    private func expandMenuDisclosure(_ identifier: String) throws {
        let triangle = try disclosureTriangle(identifier)
        try assertDisclosureCollapsed(triangle)
        let panel = try required(app.dialogs.containing(.any, identifier: "panel-automatic").firstMatch,
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
        try assertDisclosureExpanded(triangle)
        if identifier == "manual-next-session-details" {
            XCTAssertTrue(app.popUpButtons["manual-duration-picker"].waitForExistence(timeout: 3),
                          "The expanded disclosure must expose its next-session duration picker")
        }
    }

    @discardableResult
    private func revealSettingsControl(_ control: XCUIElement) throws -> XCUIElement {
        let settings = app.windows.containing(.any, identifier: "settings-navigation").firstMatch
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
        let settings = try required(app.windows.containing(.any, identifier: "settings-navigation").firstMatch,
                                    description: "Settings window containing the current page")
        let pages = ["general", "safety", "system"].map {
            settings.descendants(matching: .any)["settings-page-\($0)"].firstMatch
        }.filter { $0.exists }
        XCTAssertEqual(pages.count, 1, "Exactly one real Settings page must provide the reading viewport")
        let page = try XCTUnwrap(pages.first, "The current Settings page must exist")
        // Some native Forms put the page identifier on the ScrollView itself.
        // Otherwise query only this page, never an unrelated navigation scroll view.
        let scroll: XCUIElement
        if page.elementType == .scrollView {
            scroll = page
        } else {
            scroll = try required(page.descendants(matching: .scrollView).firstMatch,
                                  description: "Current Settings page scroll view")
        }
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
        let exists = element.waitForExistence(timeout: 5)
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

    private func headerScrollEvidence(_ name: String, window: XCUIElement, navigation: XCUIElement,
                                      heading: XCUIElement, scroll: XCUIElement, anchor: XCUIElement) {
        let startedAt = Date().timeIntervalSince1970
        let initialWindow = window.frame
        let observation: [String: Any] = ["schemaVersion": 1, "step": name,
            "testName": self.name, "fixtureBundleIdentifier": bundleID,
            "fixtureExecutablePath": expectedExecutablePath,
            "scope": "Current native Settings header and reading viewport; pixel bleed requires screenshot review",
            "windowFrame": layoutFrame(initialWindow), "navigationFrame": layoutFrame(navigation.frame),
            "headingFrame": layoutFrame(heading.frame), "readingViewportFrame": layoutFrame(scroll.frame),
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
        let settingsWindow = app.windows.containing(.any, identifier: "settings-navigation").firstMatch
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
