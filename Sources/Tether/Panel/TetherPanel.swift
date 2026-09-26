import SwiftUI
import TetherCore

/// The menu bar panel, built like macOS Control Center: glass modules, the state circle doubling
/// as the on/off control. Full shows status, the battery hold, the last lid session and today's
/// numbers; compact keeps the state module and one row of controls.
struct TetherPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage(DesignKey.liquidGlass) private var glass = true

    var body: some View {
        Group {
            if glass && DesignKey.glassOn {
                GlassEffectContainer(spacing: Metrics.spacing) { content }
            } else {
                content
            }
        }
        .padding(model.panelCompact ? Metrics.compactPadding : Metrics.padding)
        .frame(width: model.panelCompact ? 300 : 340)
        .animation(.snappy, value: model.batteryHoldUntil)
        .animation(.snappy, value: model.visibleSession)
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
                if let session = model.visibleSession {
                    SessionCard(session: session, model: model)
                }
                if model.usage != nil {
                    TodayModule(model: model)
                }
                Footer(model: model)
            }
        }
    }
}
