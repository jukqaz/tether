import SwiftUI
import TetherCore

/// One set of spacings and radii, so every module lines up.
enum Metrics {
    static let spacing: CGFloat = 10
    static let compactSpacing: CGFloat = 8
    static let padding: CGFloat = 14
    static let compactPadding: CGFloat = 14
    static let radius: CGFloat = 12
    static let compactRadius: CGFloat = 12
}

extension View {
    /// An opaque accessory surface shared by menus and editors.
    func surface(tint: Color? = nil, strength: Double = 0.3, radius: CGFloat) -> some View {
        modifier(WorkSessionControlSurface(tint: tint, strength: strength, radius: radius))
    }

    @ViewBuilder
    func actionButton(prominent: Bool = false) -> some View {
        modifier(WorkSessionActionStyle(prominent: prominent))
    }

    func workSessionCardSurface() -> some View { modifier(WorkSessionCardSurface()) }
    func workSessionWindowSurface() -> some View {
        modifier(WorkSessionWindowSurface())
    }
    func workSessionMenuSurface() -> some View {
        modifier(WorkSessionMenuSurface())
    }


}

/// Adjacent accessory controls share one surface, including the readable fallback.
private struct WorkSessionControlSurface: ViewModifier {
    let tint: Color?
    let strength: Double
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.tetherReduceTransparencyOverride) private var transparencyOverride

    @ViewBuilder func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: transparencyOverride ?? reduceTransparency)
        content
            .background(Color.tetherControlSurface, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(preferences.borderColor, lineWidth: preferences.borderWidth)
                    .accessibilityHidden(true)
            }
    }
}

private struct WorkSessionWindowSurface: ViewModifier {
    func body(content: Content) -> some View {
        // Reading content follows the opaque system window palette.
        content.background(Color.tetherBackground)
    }
}

/// The complete panel stays opaque even when macOS draws translucent popup chrome.
private struct WorkSessionMenuSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride

    func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: true)
        content.background(Color.tetherBackground, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(preferences.borderColor, lineWidth: preferences.borderWidth)
                    .accessibilityHidden(true)
            }
    }
}

private struct WorkSessionCardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.tetherReduceTransparencyOverride) private var transparencyOverride

    func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: transparencyOverride ?? reduceTransparency)
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.tetherControlSurface))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(preferences.borderColor,
                                  lineWidth: preferences.borderWidth)
                    .accessibilityHidden(true)
            }
    }
}

private struct WorkSessionActionStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(.tetherAction)
                .controlSize(.regular).font(TetherTypography.body.weight(.medium))
        } else {
            content.buttonStyle(.bordered)
                .controlSize(.regular).font(TetherTypography.body)
        }
    }
}

/// A presentation icon: the Tether mark or an SF Symbol.
struct StateIcon: View {
    let icon: AppModel.Icon
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch icon {
        case .mark(let style):
            TetherMark(style: style, size: size * 1.3)
        case .symbol(let name):
            if reduceMotion {
                Image(systemName: name).font(.system(size: size, weight: .semibold))
            } else {
                Image(systemName: name)
                    .font(.system(size: size, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}

/// A solid presentation accent; no blur or glass sampling is used.
struct Orb: ViewModifier {
    let color: Color
    var active = true
    func body(content: Content) -> some View {
        content.background(active ? color : Color.secondary, in: .circle)
    }
}
