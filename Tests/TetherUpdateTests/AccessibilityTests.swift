import AppKit
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

final class AccessibilityTests: XCTestCase {
    @MainActor
    func testDurationPresetLabelsUseLocalizedUnitsWithoutTheOverflowCeiling() {
        let previous = Localization.current; defer { Localization.current = previous }
        let numericCeiling = Int(ManualSessionPolicy.maximumTimedDuration / 60)
        for language in [Language.english, .korean] {
            Localization.current = language
            let labels = SessionDuration.choices(maximum: numericCeiling).map { Texts.duration(Double($0) * 60) }
            XCTAssertEqual(labels, language == .english
                ? ["5 min", "10 min", "15 min", "30 min", "1 h", "2 h"] : ["5분", "10분", "15분", "30분", "1시간", "2시간"])
            XCTAssertFalse(labels.contains { $0.contains(String(numericCeiling)) })
        }
    }

    func testIncreasedContrastAndTransparencyReductionIndependentlyRequireOpaqueControls() {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            for reduced in [false, true] {
                let preferences = WorkSessionVisualPreferences(contrast: contrast, reduceTransparency: reduced)
                XCTAssertEqual(preferences.usesOpaqueControls, contrast == .increased || reduced)
                if contrast == .increased {
                    XCTAssertGreaterThan(preferences.borderOpacity, 0.07)
                    XCTAssertGreaterThanOrEqual(preferences.borderWidth, 1)
                }
            }
        }
    }

    /// Rendering injections verify the shipping modifier consumes its input. They do not
    /// replace the separate keyboard or actual macOS preference checks.
    @MainActor
    func testReadingCardStrengthensContrastWithoutAddingABorderForReducedTransparency() throws {
        let standard = try renderCard(contrast: .standard, reduceTransparency: false)
        let increased = try renderCard(contrast: .increased, reduceTransparency: false)
        let opaque = try renderCard(contrast: .standard, reduceTransparency: true)
        XCTAssertNotEqual(standard, increased, "The increased-contrast input must affect actual drawing")
        XCTAssertEqual(standard, opaque, "Reading cards are already opaque; reducing transparency must not add a high-contrast border")
    }

    @MainActor
    func testShippingControlSurfaceDrawsAnOpaqueFallbackWhenTransparencyIsReduced() throws {
        let standard = try renderCard(contrast: .standard, reduceTransparency: false, controlSurface: true)
        let opaque = try renderCard(contrast: .standard, reduceTransparency: true, controlSurface: true)
        XCTAssertNotEqual(standard, opaque, "Interactive glass must still honor reduced transparency")
    }

    @MainActor
    private func renderCard(contrast: ColorSchemeContrast, reduceTransparency: Bool, controlSurface: Bool = false) throws -> Data {
        _ = NSApplication.shared
        let size = CGSize(width: 360, height: 150)
        let surface: AnyView
        if controlSurface {
            surface = AnyView(HStack {
                Text("Keep awake")
                Button("Start") {}
            }.padding(12).surface(radius: 12))
        } else {
            surface = AnyView(SettingsCard(title: "Protection", symbol: "shield") {
                WorkSessionNote(title: "Stopped for protection", detail: "Resume after cooling.")
            })
        }
        let view = surface.padding(16).frame(width: size.width, height: size.height)
        .environment(\.tetherContrastOverride, contrast)
        .environment(\.tetherReduceTransparencyOverride, reduceTransparency)
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        let controller = NSHostingController(rootView: view)
        window.contentViewController = controller
        let content = controller.view
        content.frame = CGRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
