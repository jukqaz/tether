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

    /// A shared sampling group for nearby native glass controls; it adds no fill.
    func workSessionGlassControls() -> some View {
        modifier(WorkSessionGlassControls())
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
        // Reading content follows the system window palette; the native toolbar
        // and popover chrome keep their own Liquid Glass treatment.
        content.background(Color.tetherBackground)
    }
}

/// MenuBarExtra supplies the popup's native material. Adding another full-panel
/// glass layer darkens it and makes every reading row look like a floating control.
/// Only offscreen/accessibility fallbacks need an explicit opaque popup surface.
private struct WorkSessionMenuSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.tetherReduceTransparencyOverride) private var transparencyOverride

    @ViewBuilder func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: transparencyOverride ?? reduceTransparency)
        if !preferences.usesOpaqueControls, #available(macOS 26.0, *), DesignKey.glassOn {
            content
        } else {
            content.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(preferences.usesOpaqueControls ? Color.tetherControlBorder : Color.tetherDivider,
                                      lineWidth: preferences.borderWidth)
                        .accessibilityHidden(true)
                }
        }
    }
}

private struct WorkSessionGlassControls: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), DesignKey.glassOn {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tetherContrastOverride) private var contrastOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.tetherReduceTransparencyOverride) private var transparencyOverride

    @ViewBuilder func body(content: Content) -> some View {
        let preferences = WorkSessionVisualPreferences(contrast: contrastOverride ?? contrast,
            reduceTransparency: transparencyOverride ?? reduceTransparency)
        if !preferences.usesOpaqueControls, #available(macOS 26.0, *), DesignKey.glassOn {
            if prominent {
                content.buttonStyle(.glassProminent).tint(.accentColor)
                    .font(TetherTypography.body.weight(.medium))
            } else {
                content.buttonStyle(.glass)
                    .font(TetherTypography.body)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(.accentColor)
                .font(TetherTypography.body.weight(.medium))
        } else {
            content.buttonStyle(.bordered).font(TetherTypography.body)
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
