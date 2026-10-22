import SwiftUI

/// Resolve native fallback colors for the appearance requested by the dynamic provider.
private func nativeDesignColor(_ color: NSColor, appearance: NSAppearance) -> NSColor {
    var resolved = color
    appearance.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
}

/// Product typography for the compact menu and settings. All faces remain system fonts.
enum TetherTypography {
    static let bodySize: CGFloat = 12
    static let secondarySize: CGFloat = 11
    static let sectionSize: CGFloat = 13
    static let statusSize: CGFloat = 15
    static let pageSize: CGFloat = 15
    static let countdownSize: CGFloat = 26

    static let body = Font.system(size: bodySize)
    static let secondary = Font.system(size: secondarySize)
    static let section = Font.system(size: sectionSize, weight: .semibold)
    static let status = Font.system(size: statusSize, weight: .semibold)
    static let page = Font.system(size: pageSize, weight: .semibold)
    static let countdown = Font.system(size: countdownSize, weight: .semibold)
}

extension Color {
    /// The text-reading layer is opaque; sidebar and native control glass remain separate.
    static let tetherBackground = Color(nsColor: NSColor(name: "TetherBackground") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
            return nativeDesignColor(.windowBackgroundColor, appearance: appearance)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 36 / 255.0, green: 41 / 255.0, blue: 49 / 255.0, alpha: 1)
                : NSColor(srgbRed: 252 / 255.0, green: 253 / 255.0, blue: 1, alpha: 1)
        }
    })

    static let tetherControlSurface = Color(nsColor: NSColor(name: "TetherControlSurface") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
            return nativeDesignColor(.controlBackgroundColor, appearance: appearance)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 53 / 255.0, green: 64 / 255.0, blue: 78 / 255.0, alpha: 1)
                : NSColor(srgbRed: 229 / 255.0, green: 236 / 255.0, blue: 245 / 255.0, alpha: 1)
        }
    })

    static let tetherPrimary = Color(nsColor: NSColor(name: "TetherPrimary") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
            return nativeDesignColor(.labelColor, appearance: appearance)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 242 / 255.0, green: 244 / 255.0, blue: 248 / 255.0, alpha: 1)
                : NSColor(srgbRed: 32 / 255.0, green: 37 / 255.0, blue: 47 / 255.0, alpha: 1)
        }
    })

    /// A chrome fallback for surfaces that do not receive the system sidebar material.
    static let tetherChrome = Color(nsColor: NSColor(name: "TetherChrome") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
            return nativeDesignColor(.windowBackgroundColor, appearance: appearance)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 43 / 255.0, green: 50 / 255.0, blue: 60 / 255.0, alpha: 1)
                : NSColor(srgbRed: 252 / 255.0, green: 253 / 255.0, blue: 1, alpha: 1)
        }
    })

    /// Only essential custom control boundaries use this stronger edge, never keyboard focus.
    static let tetherControlBorder = Color(nsColor: NSColor(name: "TetherControlBorder") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 0.78, green: 0.82, blue: 0.89, alpha: 1)
        case .accessibilityHighContrastAqua:
            return NSColor(srgbRed: 0.20, green: 0.23, blue: 0.28, alpha: 1)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 120 / 255.0, green: 131 / 255.0, blue: 147 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0.40, green: 0.44, blue: 0.50, alpha: 1)
        }
    })

    /// Decorative section separation does not identify a control or communicate a state.
    static let tetherDivider = Color(nsColor: NSColor(name: "TetherDivider") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
            return nativeDesignColor(.separatorColor, appearance: appearance)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 68 / 255.0, green: 70 / 255.0, blue: 78 / 255.0, alpha: 1)
                : nativeDesignColor(.separatorColor, appearance: appearance)
        }
    })

    static let tetherError = Color(nsColor: NSColor(name: "TetherError") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 1, green: 0.69, blue: 0.65, alpha: 1)
        case .accessibilityHighContrastAqua:
            return NSColor(srgbRed: 0.60, green: 0.08, blue: 0.06, alpha: 1)
        default:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 242 / 255.0, green: 139 / 255.0, blue: 130 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0.70, green: 0.12, blue: 0.10, alpha: 1)
        }
    })
}
