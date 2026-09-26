import SwiftUI
import TetherCore

struct ProblemBanner: View {
    let problem: AppModel.Problem
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(compact ? .callout : .title3)
                .foregroundStyle(problem.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.title).font((compact ? Font.caption : .subheadline).weight(.semibold))
                if !compact {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = problem.action {
                    Button(action) { model.installHelper() }
                        .actionButton(prominent: true)
                        .tint(problem.color)
                        .controlSize(.small)
                } else if case .error = problem {
                    Button(L("Dismiss", "닫기")) { model.errorText = nil }
                        .actionButton()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? Metrics.compactPadding : Metrics.padding)
        .surface(tint: problem.color, strength: 0.30, radius: compact ? Metrics.compactRadius : Metrics.radius)
    }
}
