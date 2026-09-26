import Foundation

/// What Tether is doing right now, as the panel and the menu bar report it: problems first, then
/// the switch, then the power situation.
public enum TetherState: Equatable, Sendable {
    /// Not a laptop: Tether changes nothing.
    case unsupported
    case helperMissing
    case helperDown
    /// Clamshell mode switched off: macOS's usual lid sleep.
    case off
    /// A battery hold keeps a closed Mac awake on battery.
    case holdingOnBattery
    /// On power with the lid closed and running hot: Low Power Mode is cooling it.
    case heatGuard(critical: Bool)
    /// On power: closing the lid neither sleeps nor locks.
    case clamshellOn
    /// On battery without a hold: closing the lid sleeps.
    case clamshellOff

    public static func resolve(supportedMac: Bool, helperInstalled: Bool, helperResponding: Bool,
                               enabled: Bool, holdingOnBattery: Bool, heatGuard: Bool, thermal: Int,
                               sleepDisabled: Bool) -> TetherState {
        guard supportedMac else { return .unsupported }
        guard helperInstalled else { return .helperMissing }
        guard helperResponding else { return .helperDown }
        guard enabled else { return .off }
        if holdingOnBattery { return .holdingOnBattery }
        if sleepDisabled, heatGuard { return .heatGuard(critical: thermal >= 3) }
        return sleepDisabled ? .clamshellOn : .clamshellOff
    }
}
