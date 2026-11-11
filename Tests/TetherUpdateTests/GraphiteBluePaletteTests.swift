import AppKit
import XCTest
@testable import Tether

/// Opaque reference checks only. Glass, vibrancy and live UI contrast still need
/// native visual verification; these ratios cannot prove rendered accessibility.
final class GraphiteBluePaletteTests: XCTestCase {
    @MainActor
    func testApprovedBluesResolveForBothAppearancesAndIncreasedContrast() throws {
        let cases: [(NSAppearance.Name, UInt32, UInt32)] = [
            (.aqua, 0x175CB0, 0x1762BD), (.darkAqua, 0x76ADFF, 0x1762BD),
            (.accessibilityHighContrastAqua, 0x175CB0, 0x1762BD),
            (.accessibilityHighContrastDarkAqua, 0x76ADFF, 0x1762BD)]
        for (name, ink, action) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(try components(TetherPalette.accent, in: appearance), ink, name.rawValue)
            XCTAssertEqual(try components(TetherPalette.action, in: appearance), action, name.rawValue)
        }
    }

    @MainActor
    func testReferenceInkAndWhiteButtonLabelsHaveReadableOpaqueContrast() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
            let ink = try components(TetherPalette.accent, in: appearance)
            for surface: UInt32 in dark ? [0x202126, 0x2B2D33] : [0xFFFFFF, 0xF2F2F2] {
                XCTAssertGreaterThanOrEqual(ratio(ink, surface), 4.5)
            }
            let fill = try components(TetherPalette.action, in: appearance)
            XCTAssertGreaterThanOrEqual(ratio(0xFFFFFF, fill), 4.5)
        }
    }

    @MainActor
    private func components(_ color: NSColor, in appearance: NSAppearance) throws -> UInt32 {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        let rgb = try XCTUnwrap(result)
        return UInt32((rgb.redComponent * 255).rounded()) << 16
            | UInt32((rgb.greenComponent * 255).rounded()) << 8
            | UInt32((rgb.blueComponent * 255).rounded())
    }
    private func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ color: UInt32) -> Double {
            let channels = [Double((color >> 16) & 0xff), Double((color >> 8) & 0xff), Double(color & 0xff)]
                .map { value -> Double in
                    let srgb = value / 255
                    return srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
                }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
