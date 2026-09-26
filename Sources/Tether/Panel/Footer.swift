import SwiftUI
import TetherCore

struct Footer: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            if let event = model.lastEventText {
                Text(event)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event)
            }
            Spacer(minLength: 4)
            FooterButtons(model: model, openSettings: { openSettings() }, dismiss: { dismiss() })
        }
        .padding(.horizontal, 4)
    }
}

/// Size toggle, settings, and the overflow menu.
struct FooterButtons: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.panelCompact.toggle()
            } label: {
                Image(systemName: model.panelCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(model.panelCompact ? L("Show more", "자세히 보기") : L("Compact", "컴팩트하게 보기"))
            Button {
                // An accessory app has to come forward itself, or the window opens behind others.
                NSApp.activate()
                openSettings()
                dismiss()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help(L("Settings (⌘,)", "설정 (⌘,)"))
            Menu {
                Text("Tether \(AppModel.appVersion)")
                if let update = model.availableUpdate {
                    Button(L("Download Tether \(update)…", "Tether \(update) 받기…")) { model.openReleases() }
                }
                Divider()
                Button(L("Create Diagnostic Report", "진단 보고서 만들기")) { model.createDiagnosticReport() }
                    .disabled(model.diagnosticsBusy)
                Divider()
                Button(L("Quit Tether", "Tether 종료")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: model.availableUpdate == nil ? "ellipsis.circle" : "arrow.down.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }
}
