import SwiftUI

/// Compact desktop typography; controls still use their native intrinsic sizes.
enum TetherTypography {
    static let bodySize: CGFloat = 12
    static let secondarySize: CGFloat = 11
    static let sectionSize: CGFloat = 13
    static let statusSize: CGFloat = 14
    static let pageSize: CGFloat = 15
    static let countdownSize: CGFloat = 24

    static let body = Font.system(size: bodySize)
    static let secondary = Font.system(size: secondarySize)
    static let section = Font.system(size: sectionSize, weight: .semibold)
    static let status = Font.system(size: statusSize, weight: .semibold)
    static let page = Font.system(size: pageSize, weight: .semibold)
    static let countdown = Font.system(size: countdownSize, weight: .medium)
}

/// macOS owns appearance, vibrancy, contrast and the user's accent color.
/// Content does not paint over system navigation or popover glass.
extension Color {
    static let tetherBackground = Color(nsColor: .windowBackgroundColor)
    static let tetherControlSurface = Color(nsColor: .controlBackgroundColor)
    static let tetherPrimary = Color.primary
    static let tetherSecondary = Color(nsColor: .secondaryLabelColor)
    static let tetherChrome = Color(nsColor: .windowBackgroundColor)
    static let tetherControlBorder = Color(nsColor: .secondaryLabelColor)
    static let tetherDivider = Color(nsColor: .separatorColor)
    static let tetherError = Color(nsColor: .systemRed)
    static let tetherAction = Color(nsColor: .controlAccentColor)
    static let tetherAccent = Color(nsColor: .controlAccentColor)
    static let tetherControl = Color(nsColor: .systemGray)

    /// Warning text needs darker ink on light cards than the system orange.
    static let tetherWarning = Color(nsColor: NSColor(name: "TetherWarning") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 202 / 255.0, blue: 88 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.25, blue: 0.03, alpha: 1)
    })

    /// Confirmed checks have a separate semantic color from ongoing work and controls.
    static let tetherSuccess = Color(nsColor: NSColor(name: "TetherSuccess") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua:
            NSColor(srgbRed: 161 / 255.0, green: 228 / 255.0, blue: 179 / 255.0, alpha: 1)
        case .accessibilityHighContrastAqua:
            NSColor(srgbRed: 21 / 255.0, green: 81 / 255.0, blue: 40 / 255.0, alpha: 1)
        default:
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 130 / 255.0, green: 217 / 255.0, blue: 154 / 255.0, alpha: 1)
                : NSColor(srgbRed: 33 / 255.0, green: 110 / 255.0, blue: 57 / 255.0, alpha: 1)
        }
    })
}
