import AppKit
import XCTest
import TetherCore
@testable import Tether

final class MenuBarIconTests: XCTestCase {
    @MainActor
    func testStateTemplatesKeepSameSizeAndClearEdgesAtBothScales() throws {
        for scale in [1, 2] {
            for icon in icons + [.mark(.disabled), .symbol("unknown.future.state")] {
                let image = MenuBarIcon.image(.init(icon: icon))
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(image.size, NSSize(width: 18, height: 20))
                let bitmap = try raster(image, scale: scale)
                let edgeAlpha = (0..<bitmap.pixelsWide).flatMap { x in
                    [alpha(bitmap, x, 0), alpha(bitmap, x, bitmap.pixelsHigh - 1)]
                } + (0..<bitmap.pixelsHigh).flatMap { y in
                    [alpha(bitmap, 0, y), alpha(bitmap, bitmap.pixelsWide - 1, y)]
                }
                XCTAssertEqual(edgeAlpha.max(), 0)
                XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in alpha(bitmap, x, y) > 0 }
                })
            }
        }
    }

    @MainActor
    func testKeyWorkStatesHaveDistinctShapes() throws {
        for scale in [1, 2] {
            let shapes = try icons.map { icon in
                try pixels(MenuBarIcon.image(.init(icon: icon)), scale: scale).map { $0 > 0.5 }
            }
            for first in shapes.indices {
                for second in shapes.indices where second > first {
                    let differences = zip(shapes[first], shapes[second]).filter { $0 != $1 }.count
                    XCTAssertGreaterThanOrEqual(differences, 4 * scale * scale,
                        "Work states must differ by shape, not only colour: \(icons[first]) / \(icons[second])")
                }
            }
        }
    }

    @MainActor
    func testActiveStatesRetainTheTetherMarkAboveTheirIndicators() throws {
        for scale in [1, 2] {
            let reference = try raster(MenuBarIcon.image(.init(icon: .mark(.on))), scale: scale)
            for icon in icons where icon != .mark(.off) {
                let candidate = try raster(MenuBarIcon.image(.init(icon: icon)), scale: scale)
                for y in 0..<(8 * scale) {
                    for x in 0..<reference.pixelsWide {
                        XCTAssertEqual(alpha(candidate, x, y), alpha(reference, x, y),
                            "A state indicator must retain Tether's own mark: \(icon)")
                    }
                }
            }
        }
    }

    @MainActor
    func testRetiredDetailsNeverChangeStateImage() throws {
        for scale in [1, 2] {
            for icon in icons {
                let reference = try pixels(MenuBarIcon.image(.init(icon: icon)), scale: scale)
                for item in [
                    AppModel.MenuBarItem(icon: icon, text: "Remote connection · 100°", ring: 0.5,
                        countdown: MenuBarCountdown(remaining: 7200)),
                    .init(icon: icon, text: String(repeating: "Long", count: 100), ring: .nan,
                        countdown: MenuBarCountdown(remaining: .nan))
                ] {
                    let image = MenuBarIcon.image(item)
                    XCTAssertEqual(image.size, NSSize(width: 18, height: 20))
                    XCTAssertEqual(try pixels(image, scale: scale), reference)
                }
            }
        }
    }

    @MainActor
    func testUnsupportedSymbolsUseBoundedReviewMark() throws {
        for scale in [1, 2] {
            let unexpected = MenuBarIcon.image(.init(icon: .symbol("unknown.future.state")))
            let warning = MenuBarIcon.image(.init(icon: .symbol("exclamationmark.triangle")))
            XCTAssertEqual(try pixels(unexpected, scale: scale), try pixels(warning, scale: scale))
        }
    }

    private var icons: [AppModel.Icon] {
        [.mark(.on), .mark(.off), .mark(.held), .symbol("shield.lefthalf.filled"),
         .symbol("exclamationmark.triangle"), .symbol("hourglass"), .symbol("display")]
    }

    @MainActor
    private func pixels(_ image: NSImage, scale: Int) throws -> [CGFloat] {
        let bitmap = try raster(image, scale: scale)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in alpha(bitmap, x, y) }
        }
    }

    @MainActor
    private func raster(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = image.size
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return bitmap
    }

    private func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}
