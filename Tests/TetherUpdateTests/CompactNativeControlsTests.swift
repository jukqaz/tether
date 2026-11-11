import AppKit
import SwiftUI
import XCTest
@testable import Tether

/// Test native callbacks across SwiftUI refreshes. These callbacks must use the
/// latest command/choice gates rather than stale closures from menu creation.
final class CompactNativeControlsTests: XCTestCase {
    func testPopupUsesLatestBindingAndRejectsUnavailableOrStaleSelection() async throws {
        try await MainActor.run {
            var first = 30
            var second = 60
            var oldWrites: [Int] = []
            var currentWrites: [Int] = []
            let host = Self.host(AnyView(CompactPopUp(title: "Duration", selection: .init(
                get: { first }, set: { first = $0; oldWrites.append($0) }),
                choices: [PopupChoice(30, "30m"), PopupChoice(60, "1h")]).disabled(false)))
            let button = try XCTUnwrap(Self.popup(in: host))

            host.rootView = AnyView(CompactPopUp(title: "Duration", selection: .init(
                get: { second }, set: { second = $0; currentWrites.append($0) }),
                choices: [PopupChoice(30, "30m"), PopupChoice(60, "1h", enabled: false)]).disabled(false))
            Self.settle(host)
            XCTAssertTrue(try XCTUnwrap(Self.popup(in: host)) === button,
                "A SwiftUI refresh must update the existing native control and coordinator")
            XCTAssertEqual(button.indexOfSelectedItem, 1)
            XCTAssertFalse(try XCTUnwrap(button.item(at: 1)).isEnabled)
            button.selectItem(at: 1)
            try Self.sendNativeAction(button)
            XCTAssertEqual(second, 60, "An unavailable item cannot issue a new selection")
            XCTAssertTrue(currentWrites.isEmpty)
            button.selectItem(at: 0)
            try Self.sendNativeAction(button)
            XCTAssertEqual(second, 30)
            XCTAssertEqual(first, 30, "Callbacks must not use the previous SwiftUI binding")
            XCTAssertTrue(oldWrites.isEmpty)
            XCTAssertEqual(currentWrites, [30])
            button.selectItem(at: -1)
            try Self.sendNativeAction(button)
            XCTAssertEqual(second, 30)
            XCTAssertEqual(currentWrites, [30], "A stale or missing native selection must be ignored")

            host.rootView = AnyView(CompactPopUp(title: "Duration", selection: .init(
                get: { second }, set: { second = $0; currentWrites.append($0) }),
                choices: [PopupChoice(30, "30m"), PopupChoice(60, "1h")]).disabled(true))
            Self.settle(host)
            XCTAssertTrue(try XCTUnwrap(Self.popup(in: host)) === button)
            XCTAssertFalse(button.isEnabled)
            button.selectItem(at: 1)
            try Self.sendNativeAction(button)
            XCTAssertEqual(second, 30)
            XCTAssertEqual(currentWrites, [30], "The latest disabled environment must gate even a queued native callback")
        }
    }

    func testActionMenuRechecksLatestAvailabilityAndClosureAtClick() async {
        await MainActor.run {
            var original = 0
            var current = 0
            let coordinator = CompactActionMenu.Coordinator()
            let item = NSMenuItem(title: "Sleep", action: nil, keyEquivalent: "")
            item.tag = 0
            coordinator.actions = [CompactMenuAction("Sleep") { original += 1 }]
            coordinator.actions = [CompactMenuAction("Sleep", enabled: false) { current += 1 }]
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 0)
            coordinator.actions = [CompactMenuAction("Sleep") { current += 1 }]
            coordinator.enabled = false
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 0)
            coordinator.enabled = true
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 1)
            XCTAssertEqual(original, 0)
            item.tag = 4
            coordinator.performMenuAction(item)
            XCTAssertEqual(current, 1)
        }
    }

    func testPushButtonUsesCurrentActionAfterRefresh() async throws {
        try await MainActor.run {
            var original = 0
            var current = 0
            let host = Self.host(AnyView(CompactPushButton("End", prominent: true) { original += 1 }.disabled(false)))
            let button = try XCTUnwrap(Self.pushButton(in: host))
            XCTAssertEqual(button.keyEquivalent, "\r")

            host.rootView = AnyView(CompactPushButton("End", prominent: true) { current += 1 }.disabled(false))
            Self.settle(host)
            XCTAssertTrue(try XCTUnwrap(Self.pushButton(in: host)) === button)
            try Self.sendNativeAction(button)
            XCTAssertEqual(original, 0)
            XCTAssertEqual(current, 1)

            host.rootView = AnyView(CompactPushButton("End", prominent: true) { current += 1 }.disabled(true))
            Self.settle(host)
            XCTAssertTrue(try XCTUnwrap(Self.pushButton(in: host)) === button)
            XCTAssertFalse(button.isEnabled)
            XCTAssertEqual(button.keyEquivalent, "", "A disabled button must relinquish the Return role")
            try Self.sendNativeAction(button)
            XCTAssertEqual(current, 1, "A queued native callback must obey the latest disabled environment")

            host.rootView = AnyView(CompactPushButton("End", prominent: false) { current += 1 }.disabled(false))
            Self.settle(host)
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.keyEquivalent, "", "An ordinary enabled button must not claim Return")
            host.rootView = AnyView(CompactPushButton("End", prominent: true) { current += 1 }.disabled(false))
            Self.settle(host)
            XCTAssertEqual(button.keyEquivalent, "\r")
            XCTAssertEqual(button.keyEquivalentModifierMask, [])
            try Self.sendNativeAction(button)
            XCTAssertEqual(current, 2)
        }
    }

    func testPopupReportsNativeMinimumForLongEnglishAndKoreanChoices() async throws {
        try await MainActor.run {
            for title in ["Request sleep · Recommended", "잠자기 요청 · 권장",
                          "Unlimited · protection stays on", "무제한 · 보호는 유지"] {
                for settingsStyle in [true, false] {
                    let host = NSHostingView(rootView: CompactPopUp(title: "Sleep policy", selection: .constant(0),
                        choices: [PopupChoice(0, title)])
                        .environment(\.tetherSettingsStyle, settingsStyle)
                        .frame(width: 80, height: 30))
                    host.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
                    host.layoutSubtreeIfNeeded()
                    let button = try XCTUnwrap(Self.popup(in: host))
                    XCTAssertEqual(button.selectedItem?.title, title)
                    XCTAssertEqual(button.font?.pointSize, 14)
                    XCTAssertEqual(button.bounds.height, button.intrinsicContentSize.height, accuracy: 0.5,
                        "Regular controls must retain their native height without an extra 30pt wrapper")
                    XCTAssertGreaterThan(button.intrinsicContentSize.width, 80)
                    XCTAssertGreaterThanOrEqual(button.bounds.width + 0.5, button.intrinsicContentSize.width,
                        "A popup must report its native minimum instead of accepting a truncating proposal: \(title)")
                }
            }
        }
    }

    func testPopupAndPushButtonExposeTheirNativeTextBaselineToSwiftUILayout() async throws {
        try await MainActor.run {
            for control in [AnyView(CompactPopUp(title: "Duration", selection: .constant(30),
                                choices: [PopupChoice(30, "30m")])),
                            AnyView(CompactPushButton("Apply") {})] {
                let measurement = NativeBaselineMeasurement()
                let host = Self.host(AnyView(NativeBaselineProbe(measurement: measurement) { control }))
                let button = try XCTUnwrap(Self.nativeButton(in: host))
                let nativeBaseline = button.alignmentRectInsets.top + button.firstBaselineOffsetFromTop
                XCTAssertTrue(nativeBaseline.isFinite)
                XCTAssertGreaterThan(nativeBaseline, 0)
                XCTAssertLessThan(nativeBaseline, button.bounds.height)
                XCTAssertEqual(try XCTUnwrap(measurement.baseline), nativeBaseline, accuracy: 0.5,
                    "A firstTextBaseline row must align with AppKit's rendered title, not the representable's frame edge")
            }
        }
    }

    @MainActor
    private static func host(_ rootView: AnyView) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        settle(host)
        return host
    }

    @MainActor
    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        // Native baseline publication is intentionally deferred past the
        // representable update. Drain that update before inspecting layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func sendNativeAction(_ control: NSControl) throws {
        let action = try XCTUnwrap(control.action)
        // Send target/action directly so the coordinator's gate is tested even
        // for a callback queued before the native control became disabled.
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: control.target, from: control))
    }

    func testSettingsRowExpandsLongChoicesAndStacksWhenTheRowIsNarrow() async throws {
        try await MainActor.run {
            for (label, choice) in [("If the lid is closed", "Request sleep · Recommended"),
                                    ("덮개가 닫혀 있다면", "잠자기 요청 · 권장"),
                                    ("Battery time limit", "Unlimited · protection stays on"),
                                    ("배터리 시간 한도", "무제한 · 보호는 유지")] {
                let wide = Self.settingsRow(label: label, choice: choice, width: 520)
                let wideButton = try XCTUnwrap(Self.popup(in: wide))
                let nativeWidth = wideButton.intrinsicContentSize.width
                XCTAssertGreaterThanOrEqual(wideButton.bounds.width + 0.5, nativeWidth,
                    "The value column must grow beyond its standard width when the selected text needs it")
                XCTAssertEqual(wide.fittingSize.height, SettingsMetrics.rowHeight, accuracy: 0.5)

                // A control must remain complete even after two dependency
                // levels reduce its available column at the minimum window.
                let narrowWidth = max(SettingsMetrics.controlWidth, nativeWidth) + 52
                for inset: CGFloat in [0, 20, 40] {
                    let narrow = Self.settingsRow(label: label, choice: choice, width: narrowWidth,
                        leadingInset: inset)
                    let narrowButton = try XCTUnwrap(Self.popup(in: narrow))
                    XCTAssertEqual(narrow.fittingSize.width, narrowWidth, accuracy: 0.5)
                    let labelHeight = ceil((label as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: TetherTypography.settingsBodySize)]).height)
                    XCTAssertGreaterThan(narrow.fittingSize.height, wide.fittingSize.height,
                        "A narrow settings row must stack instead of clipping its control (inset \(inset))")
                    XCTAssertGreaterThanOrEqual(narrow.fittingSize.height + 0.5,
                        labelHeight + narrowButton.bounds.height + 5,
                        "The stacked row must fit the complete label, control and vertical gap")
                    XCTAssertGreaterThanOrEqual(narrowButton.bounds.width + 0.5, nativeWidth)
                    let controlFrame = narrowButton.convert(narrowButton.bounds, to: narrow)
                    XCTAssertGreaterThanOrEqual(controlFrame.minX, inset - 0.5)
                    XCTAssertLessThanOrEqual(controlFrame.maxX, narrowWidth + 0.5)
                }
            }
        }
    }

    @MainActor
    private static func settingsRow(label: String, choice: String, width: CGFloat, leadingInset: CGFloat = 0) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(SettingRow(title: label) {
            CompactPopUp(title: "Sleep policy", selection: .constant(0), choices: [PopupChoice(0, choice)])
        }
        .environment(\.tetherSettingsStyle, true)
        .padding(.leading, leadingInset)
        .frame(width: width)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testSettingsValueColumnStaysInTheCenteredReadingColumnWhenTheWindowWidens() async throws {
        try await MainActor.run {
            for width: CGFloat in [512, 1000, 1240] {
                let host = NSHostingView(rootView: AnyView(SettingsForm {
                    SettingRow(title: "Choice") {
                        CompactPopUp(title: "Choice", selection: .constant(0), choices: [PopupChoice(0, "Selected")])
                    }
                }.environment(\.tetherSettingsStyle, true).frame(width: width, height: 320)))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
                Self.settle(host)
                let button = try XCTUnwrap(Self.popup(in: host))
                let frame = button.convert(button.bounds, to: host)
                let readingWidth = min(SettingsMetrics.contentWidth, width - SettingsMetrics.gutter * 2)
                XCTAssertEqual(frame.maxX, (width + readingWidth) / 2, accuracy: 1,
                    "The value column must stay with the centered page heading, not the viewport's left edge")
                XCTAssertGreaterThanOrEqual(frame.minX, SettingsMetrics.gutter)
            }
        }
    }

    @MainActor
    private static func popup(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        for subview in view.subviews {
            if let button = popup(in: subview) { return button }
        }
        return nil
    }

    @MainActor
    private static func nativeButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = nativeButton(in: subview) { return button }
        }
        return nil
    }

    @MainActor
    private static func pushButton(in view: NSView) -> NSButton? {
        guard let button = nativeButton(in: view), !(button is NSPopUpButton) else { return nil }
        return button
    }
}

private final class NativeBaselineMeasurement {
    var baseline: CGFloat?
}

/// Inspect the baseline SwiftUI actually receives from the production wrapper.
private struct NativeBaselineProbe: Layout {
    let measurement: NativeBaselineMeasurement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let dimensions = child.dimensions(in: proposal)
        return CGSize(width: dimensions.width, height: dimensions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        measurement.baseline = child.dimensions(in: proposal)[.firstTextBaseline]
        child.place(at: bounds.origin, proposal: proposal)
    }
}
