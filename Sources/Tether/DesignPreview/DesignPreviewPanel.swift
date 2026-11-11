import SwiftUI

/// The dedicated preview and the actual menu share one layout and command surface.
struct DesignPreviewPanel: View {
    @ObservedObject var state: DesignPreviewState
    var openSettings: () -> Void = {}
    var body: some View {
        TetherPanel(model: state.model, previewSettingsAction: openSettings)
    }
}
