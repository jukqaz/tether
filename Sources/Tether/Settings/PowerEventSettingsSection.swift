import SwiftUI

/// A saved event result stays visible while current attention remains outside the fold.
struct PowerEventSettingsSection<Content: View, Status: View>: View {
    let title: String
    let outcome: String
    var outcomeIdentifier: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) { content }
                    .padding(.leading, 12).padding(.top, 8)
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        titleText.fixedSize()
                        Spacer(minLength: 12)
                        outcomeText.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) { titleText; outcomeText }
                }
                .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            status
            Divider().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(title).font(TetherTypography.settingsBody)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var outcomeText: some View {
        Text(outcome).font(TetherTypography.settingsSecondary)
            .foregroundStyle(Color.tetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(outcomeIdentifier ?? "settings-power-event-outcome")
    }
}
