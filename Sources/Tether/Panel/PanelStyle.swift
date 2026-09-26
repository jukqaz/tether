import SwiftUI
import TetherCore

/// One set of spacings and radii, so every module lines up.
enum Metrics {
    static let spacing: CGFloat = 10
    static let compactSpacing: CGFloat = 8
    static let padding: CGFloat = 12
    static let compactPadding: CGFloat = 10
    static let radius: CGFloat = 20
    static let compactRadius: CGFloat = 16
}

enum DesignKey {
    /// Liquid Glass surfaces and buttons. Glass already follows the system's Reduce Transparency
    /// setting, so there is no switch for it; `-liquidGlass NO` on the command line falls back to
    /// tinted fills and bordered capsules, because glass doesn't draw in offscreen screenshots.
    static let glassOn: Bool = {
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["liquidGlass"]
        return !["NO", "no", "0", "false"].contains(value as? String ?? "")
    }()
}

extension View {
    /// A module surface: Liquid Glass, or a tinted fill when glass is off.
    @ViewBuilder
    func surface(tint: Color? = nil, strength: Double = 0.3, radius: CGFloat) -> some View {
        if DesignKey.glassOn {
            glassEffect(.regular.tint(tint.map { $0.opacity(strength) }), in: .rect(cornerRadius: radius))
        } else {
            background((tint ?? .primary).opacity(tint == nil ? 0.06 : strength * 0.4), in: .rect(cornerRadius: radius))
        }
    }

    @ViewBuilder
    func actionButton(prominent: Bool = false) -> some View {
        if DesignKey.glassOn {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}

/// A presentation icon: the Tether mark or an SF Symbol.
struct StateIcon: View {
    let icon: AppModel.Icon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .mark(let style):
            TetherMark(style: style, size: size * 1.3)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// A round control: tinted glass when on, quiet when off.
struct Orb: ViewModifier {
    let color: Color
    var active = true

    func body(content: Content) -> some View {
        let fill = active ? color : Color.secondary.opacity(0.35)
        if DesignKey.glassOn {
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
        if DesignKey.glassOn {
            content.glassEffect(.regular.tint(color.opacity(0.18)).interactive(), in: .capsule)
        } else {
            content.background(color.opacity(0.14), in: .capsule)
        }
    }
}
