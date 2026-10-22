import SwiftUI
import TetherCore

struct ProblemBanner: View {
    let problem: AppModel.Problem
    @ObservedObject var model: AppModel
    let compact: Bool
    var embeddedInForm = false

    var body: some View {
        Group {
            if embeddedInForm { content }
            else {
                content
                    .padding(compact ? Metrics.compactPadding : Metrics.padding)
                    .workSessionCardSurface()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                message
                Spacer(minLength: 0)
                action.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                message
                action.padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body).foregroundStyle(problem.color).frame(width: 16)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.title).font((compact ? Font.callout : .body).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(problem.message).font(.callout).foregroundStyle(.secondary)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var action: some View {
        if case .lid = problem {
            Button(L("Review setup…", "도우미 상태 보기…")) { model.settingsPage = .system }
                .actionButton()
        } else if let title = problem.action {
            Button(title) { model.installHelper() }
                .actionButton(prominent: true)
                .disabled(model.helperInstallInFlight)
        } else if case .error = problem {
            Button(L("Dismiss", "닫기")) { model.errorText = nil }.actionButton()
        }
    }
}
