import AppKit
import SwiftUI
import TetherCore

/// How Tether works and the words it uses, with the way to more help.
struct HelpPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                ForEach(Glossary.overview) { HelpItemRow(item: $0) }
            } header: {
                Text(L("How Tether Works", "Tether 동작 방식"))
            }
            Section {
                ForEach(Glossary.terms) { HelpItemRow(item: $0) }
            } header: {
                Text(L("Terms", "용어"))
            } footer: {
                Note(L("Every other page has a ? button at the bottom that explains each of its settings.",
                       "다른 페이지 맨 아래의 ? 버튼을 누르면 그 페이지의 설정을 하나씩 설명해 줘요."))
            }
            Section {
                HStack(spacing: 8) {
                    Button(L("Read the README…", "README 보기…")) { NSWorkspace.shared.open(SettingsPage.help.readmeURL) }
                    Button(L("Report a Problem…", "문제 알리기…")) {
                        NSWorkspace.shared.open(UpdateChecker.projectURL.appendingPathComponent("issues/new"))
                    }
                    Spacer()
                }
            } header: {
                Text(L("More Help", "더 알아보기"))
            } footer: {
                Note(L("When reporting a problem, attach a diagnostic report from System › Diagnostics: it has what's needed to find the cause, with your names masked.",
                       "문제를 알릴 때는 시스템 › 진단에서 만든 진단 보고서를 붙여 주세요. 원인을 찾는 데 필요한 내용이 담기고 이름은 가려져요."))
            }
        }
    }
}

/// A name in bold with its meaning under it.
struct HelpItemRow: View {
    let item: HelpItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.callout.weight(.semibold))
            Text(item.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

/// The standard round "?" at the bottom right of a settings page, as in System Settings. It opens
/// the page's guide. Only inside `SettingsView`, which provides the model.
struct GuideButton: View {
    let page: SettingsPage
    @State private var shown = false
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HelpLink { shown.toggle() }
            .help(L("What each setting on this page does", "이 페이지의 설정 설명"))
            .popover(isPresented: $shown, arrowEdge: .top) {
                GuideView(page: page) {
                    shown = false
                    model.settingsPage = .help
                }
            }
    }
}

struct GuideView: View {
    let page: SettingsPage
    let showTerms: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.headline)
                Text(page.guideSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(page.guide) { HelpItemRow(item: $0) }
            Divider()
            HStack {
                Button(L("All Terms", "용어 모두 보기")) { showTerms() }
                Spacer()
                Link(L("More in the README", "README에서 더 보기"), destination: page.readmeURL)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 380)
    }
}
