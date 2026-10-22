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

enum DesignKey {
    /// Liquid Glass surfaces and buttons. Glass already follows the system's Reduce Transparency
    /// setting, so there is no switch for it; `-liquidGlass NO` on the command line falls back to
    /// opaque control fills and native bordered buttons, because glass doesn't draw in offscreen screenshots.
    /// Liquid Glass is the default on the supported macOS 26+ runtime.
    static let glassOn: Bool = {
        guard #available(macOS 26.0, *) else { return false }
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["liquidGlass"]
        return !["NO", "no", "0", "false"].contains(value as? String ?? "")
    }()
}

extension View {
    /// A module surface: Liquid Glass, or a readable opaque control when glass is off.
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
        if preferences.usesOpaqueControls {
            content
                .background(Color.tetherControlSurface, in: .rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.tetherControlBorder, lineWidth: preferences.borderWidth)
                        .accessibilityHidden(true)
                }
        } else if #available(macOS 26.0, *), DesignKey.glassOn {
            content.glassEffect(.regular.tint(tint.map { $0.opacity(strength) }), in: .rect(cornerRadius: radius))
        } else {
            content.background(Color.tetherControlSurface, in: .rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.tetherControlBorder, lineWidth: 0.5)
                        .accessibilityHidden(true)
                }
        }
    }
}

private struct WorkSessionWindowSurface: ViewModifier {
    func body(content: Content) -> some View {
        // The menu's explanatory text must not pick up changing desktop colors.
        content.background(Color.tetherBackground).foregroundStyle(Color.tetherPrimary)
    }
}

/// The menu is one related control group, with one glass layer and native buttons.
/// Offscreen previews and accessibility preferences retain the opaque reading surface.
private struct WorkSessionMenuSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.tetherReduceTransparencyOverride) private var transparencyOverride

    @ViewBuilder func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: transparencyOverride ?? reduceTransparency)
        if !preferences.usesOpaqueControls, #available(macOS 26.0, *), DesignKey.glassOn {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content.background(Color.tetherBackground, in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(preferences.usesOpaqueControls ? Color.tetherControlBorder : Color.tetherDivider,
                                      lineWidth: preferences.borderWidth)
                        .accessibilityHidden(true)
                }
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
                    .strokeBorder(preferences.usesOpaqueControls ? Color.tetherControlBorder : Color.tetherDivider,
                                  lineWidth: preferences.borderWidth)
                    .accessibilityHidden(true)
            }
    }
}

private struct WorkSessionActionStyle: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            // Text-bearing primary actions use the measured opaque blue. Native button
            // styling still supplies hover, keyboard focus and disabled presentation.
            content.buttonStyle(.borderedProminent).tint(.tetherAction)
                .foregroundStyle(.white).font(TetherTypography.body.weight(.medium))
        } else {
            // A gray-tinted Glass button produced a bright fill behind white
            // 13pt labels in native captures. Keep text actions on the readable
            // native control surface; Glass remains in navigation and chrome.
            content.buttonStyle(.bordered)
                .foregroundStyle(Color.tetherPrimary)
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

/// A round control: tinted glass when on, quiet when off.
struct Orb: ViewModifier {
    let color: Color
    var active = true

    func body(content: Content) -> some View {
        let fill = active ? color : Color.secondary.opacity(0.35)
        if #available(macOS 26.0, *), DesignKey.glassOn {
            content.glassEffect(.regular.tint(fill).interactive(), in: .circle)
        } else {
            content
                .background(fill.gradient, in: .circle)
                .shadow(color: active ? color.opacity(0.35) : .clear, radius: 6, y: 2)
        }
    }
}

/// A quiet tinted capsule for a control that carries text.
struct Capsuled: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), DesignKey.glassOn {
            content.glassEffect(.regular.tint(color.opacity(0.18)).interactive(), in: .capsule)
        } else {
            content.background(color.opacity(0.14), in: .capsule)
        }
    }
}
