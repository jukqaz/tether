import Foundation
import TetherCore

/// Public documentation links. AppUpdater owns all update checks.
enum UpdateChecker {
    static let repository = "jukqaz/tether"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let projectURL = URL(string: "https://github.com/\(repository)")!

    /// The README in the app's language.
    static var readmeURL: URL {
        Localization.current == .korean ? projectURL.appendingPathComponent("blob/main/README.ko.md") : projectURL
    }

}
