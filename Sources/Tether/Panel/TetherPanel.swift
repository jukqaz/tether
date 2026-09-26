import SwiftUI
import TetherCore

/// The menu bar panel, built like macOS Control Center: glass modules on one spacing grid. Full
/// shows the state with the clamshell switch, status, the battery hold and today's records;
/// compact keeps the state module and one row of controls.
struct TetherPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if DesignKey.glassOn {
                GlassEffectContainer(spacing: Metrics.spacing) { content }
            } else {
                content
            }
        }
        .padding(model.panelCompact ? Metrics.compactPadding : Metrics.padding)
        .frame(width: model.panelCompact ? 300 : 340)
        .animation(.snappy, value: model.batteryHoldUntil)
    }

    @ViewBuilder
    private var content: some View {
        if model.panelCompact {
            VStack(spacing: Metrics.compactSpacing) {
                if let problem = model.problem {
                    ProblemBanner(problem: problem, model: model, compact: true)
                }
                StateModule(model: model, compact: true)
                CompactControls(model: model)
            }
        } else {
            VStack(spacing: Metrics.spacing) {
                if let problem = model.problem {
                    ProblemBanner(problem: problem, model: model, compact: false)
                }
                StateModule(model: model, compact: false)
                HStack(alignment: .top, spacing: Metrics.spacing) {
                    StatusModule(model: model)
                    if model.helperInstalled, model.helperResponding {
                        HoldModule(model: model, clock: model.clock)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if model.usage != nil {
                    TodayModule(model: model)
                }
                Footer(model: model)
            }
        }
    }
}
