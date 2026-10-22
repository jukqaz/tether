import SwiftUI
import TetherCore

struct Footer: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Work & protection", "작업 유지 · 기기 보호"))
                .font(.system(size: 11)).foregroundStyle(Color.tetherSecondary)
            Spacer(minLength: 4)
            FooterButtons(model: model, openSettings: {
                if model.developmentService { model.settingsPage = .general } else { openSettings() }
            }, dismiss: { dismiss() })
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
        HStack(spacing: 6) {
            Button {
                model.panelCompact.toggle()
            } label: {
                Text(model.panelCompact ? L("Details", "자세히") : L("Compact", "간단히")).font(.system(size: 11))
                    .frame(minHeight: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.panelCompact ? L("Show more", "자세히 보기") : L("Compact view", "간단히 보기"))
            .help(model.panelCompact ? L("Show more", "자세히 보기") : L("Compact", "간단히 보기"))
            Button {
                // An accessory app has to come forward itself, or the window opens behind others.
                NSApp.activate()
                openSettings()
                dismiss()
            } label: {
                Image(systemName: "gearshape").frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Settings", "설정"))
            .keyboardShortcut(",", modifiers: .command)
            .help(L("Settings (⌘,)", "설정 (⌘,)"))
            Menu {
                Text("Tether \(AppModel.appDisplayVersion)")
                if let update = model.availableUpdate {
                    Button(L("Update Tether \(update)…", "Tether \(update) 업데이트…")) { model.checkForUpdates(force: true) }
                }
                Divider()
                Button(L("Create Diagnostic Report", "진단 보고서 만들기")) { model.createDiagnosticReport() }
                    .disabled(model.diagnosticsBusy)
                Divider()
                Button(L("Stop & Quit Tether", "Tether 종료")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: model.availableUpdate == nil ? "ellipsis" : "arrow.down.circle.fill").frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("More", "더 보기"))
            .help(L("More: a diagnostic report, quit", "더 보기: 진단 보고서, 종료"))
        }
        .foregroundStyle(Color.tetherSecondary)
    }
}
