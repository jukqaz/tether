import XCTest
import TetherCore
@testable import Tether

final class PowerSettingsPresentationTests: XCTestCase {
    func testUnplugExplanationMatchesTheSelectedEndAction() async throws {
        try await MainActor.run {
            let original = Localization.current; defer { Localization.current = original }
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            for language in [Language.korean, .english] {
                Localization.current = language
                model.setDisconnectAction(.sleepIfClosed)
                let sleep = SafetyPage(model: model).disconnectExplanation
                XCTAssertTrue(sleep.contains(L("requests sleep", "잠자기를 요청")))
                model.setDisconnectAction(.followOS)
                let follow = SafetyPage(model: model).disconnectExplanation
                XCTAssertNotEqual(follow, sleep)
                XCTAssertTrue(follow.contains(L("lets macOS decide", "macOS에 맡깁니다")))
                XCTAssertFalse(follow.contains(L("requests sleep", "잠자기를 요청")))
                XCTAssertFalse(model.manualSessionActive)
            }
        }
    }
}
