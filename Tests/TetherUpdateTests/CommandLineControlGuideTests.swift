import Foundation
import XCTest
import TetherCore
@testable import Tether

/// Pure display-data checks: no app model, socket, CLI process or power backend.
final class CommandLineControlGuideTests: XCTestCase {
    func testSessionExamplesUseSupportedCommandsAndMatchingURLsInBothLanguages() async throws {
        try await MainActor.run {
            let original = Localization.current
            defer { Localization.current = original }
            let expected: [String: TetherCommand] = [
                "status": .status,
                "manual-start": .manual(minutes: 30),
                "manual-extend": .extendManual(minutes: 15),
                "manual-end": .endManual
            ]
            for language in [Language.korean, .english] {
                Localization.current = language
                let examples = CommandLineControlGuide.examples
                XCTAssertEqual(Set(examples.map(\.id)), Set(expected.keys))
                for example in examples {
                    XCTAssertEqual(TetherCommand.parse(example.words), expected[example.id], example.id)
                    let url = try XCTUnwrap(URL(string: example.urlString))
                    XCTAssertEqual(TetherCommand.parse(url: url), expected[example.id], example.id)
                    XCTAssertFalse(example.title.isEmpty)
                    XCTAssertFalse(example.detail.isEmpty)
                    XCTAssertFalse(example.words.contains("--pid"))
                    XCTAssertNotEqual(example.words.first, "run")
                }
            }
        }
    }

    func testCopiedCommandUsesMatchingBundleCLIAndQuotesSpacesAndApostrophes() async throws {
        try await MainActor.run {
            let bundle = URL(fileURLWithPath: "/tmp/Owner's Mac/Tether.app", isDirectory: true)
            let executable = CommandLineControlGuide.executable(in: bundle)
            XCTAssertEqual(executable.path, "/tmp/Owner's Mac/Tether.app/Contents/Helpers/tether")
            let start = try XCTUnwrap(CommandLineControlGuide.examples.first { $0.id == "manual-start" })
            XCTAssertEqual(start.commandLine(executable: executable),
                           "'/tmp/Owner'\\''s Mac/Tether.app/Contents/Helpers/tether' manual 30m")
        }
    }
}
