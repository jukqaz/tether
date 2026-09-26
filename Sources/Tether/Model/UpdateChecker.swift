import Foundation

/// The latest release on GitHub. Only the release is asked for; nothing about this Mac is sent.
enum UpdateChecker {
    static let repository = "jukqaz/tether"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let projectURL = URL(string: "https://github.com/\(repository)")!

    /// The newest release's version, e.g. "2.0.1", or nil when it can't be read.
    static func latestVersion() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
