import SwiftUI
import TetherCore

/// All feature sheets keep their title and action outside the scrolling reading area.
struct V4FeatureSheet<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(TetherTypography.page)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxHeight: .infinity)
                .scrollEdgeEffectHidden(true, for: .top).clipped()
            Divider()
            HStack(spacing: 8) { actions }
                .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: 560, height: 448)
            .font(TetherTypography.body).controlSize(.small).tint(.tetherAccent)
            // Native buttons and links own their label styles. A blanket primary
            // foreground here overrides link blue and prominent-button contrast.
            .background(Color.tetherBackground)
            .accessibilityElement(children: .contain)
    }
}

