import Foundation

public enum UpdateReleasePolicy {
    /// Sparkle's stable releases have no channel. Also check resumed downloads,
    /// which may have been selected before the app became stable-only.
    public static func accepts(candidateChannel: String?) -> Bool { candidateChannel == nil }
}

/// Unknown must never be mistaken for an open lid.
public enum UpdateInstallPolicy {
    public static func allowsInstallation(lidClosed: Bool?) -> Bool { lidClosed == false }
}

/// One automatic installation attempt per compatibility contract. Development
/// candidates may keep a build number while changing the coordinator contract.
public enum HelperUpgradeAttempt {
    public static let preferenceKey = "helperUpgradeAttemptedContract"
    public static var currentContractID: String {
        "\(TetherPaths.version):\(TetherPaths.build):protocol2:schema\(Control.currentSchema):coordinator\(WorkSessionLease.coordinatorVersion)"
    }
    @MainActor public static func claim(in defaults: UserDefaults) -> Bool {
        let contract = currentContractID
        guard defaults.string(forKey: preferenceKey) != contract else { return false }
        defaults.set(contract, forKey: preferenceKey)
        return true
    }
}

/// Holds Sparkle's relaunch callback until a fresh observation permits it and the user
/// explicitly continues. Opening the lid alone never triggers an installation.
@MainActor
public final class UpdateRelaunchGate {
    public private(set) var waiting = false
    public private(set) var installationRequested = false
    private var continuation: (() -> Void)?
    private let lidClosed: () -> Bool?
    public init(lidClosed: @escaping () -> Bool?) { self.lidClosed = lidClosed }
    public var canTerminateForUpdate: Bool {
        !installationRequested || UpdateInstallPolicy.allowsInstallation(lidClosed: lidClosed())
    }
    public func markInstallationRequested() { installationRequested = true }
    public func postpone(_ resume: @escaping () -> Void) -> Bool {
        installationRequested = true
        guard !UpdateInstallPolicy.allowsInstallation(lidClosed: lidClosed()) else { return false }
        continuation = resume; waiting = true
        return true
    }
    @discardableResult public func resume() -> Bool {
        guard let action = continuation,
              UpdateInstallPolicy.allowsInstallation(lidClosed: lidClosed()) else { return false }
        continuation = nil; waiting = false
        action()
        return true
    }
    public func finish() { continuation = nil; waiting = false; installationRequested = false }
}
