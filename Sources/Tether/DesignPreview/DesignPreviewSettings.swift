import SwiftUI

struct DesignPreviewSettings: View {
    enum Page: String, CaseIterable, Identifiable {
        case sessions, protection, app
        var id: Self { self }
        var settingsPage: SettingsPage {
            switch self { case .sessions: .general; case .protection: .safety; case .app: .system }
        }
    }
    @ObservedObject var state: DesignPreviewState
    var snapshot = false

    init(state: DesignPreviewState, page: Page = .sessions, showPreviewControls: Bool = false, snapshot: Bool = false) {
        self.state = state
        self.snapshot = snapshot
        state.model.settingsPage = page.settingsPage
    }
    var body: some View {
        SettingsView(model: state.model, screenshot: snapshot)
            .frame(minWidth: 560, minHeight: 448)
    }
}
