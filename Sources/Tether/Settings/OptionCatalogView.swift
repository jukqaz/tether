import SwiftUI
import TetherCore

struct OptionCatalogView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var destination: OptionDestination?
    private var entries: [OptionCatalogEntry] {
        OptionCatalog.entries.filter { $0.readiness != .notImplemented && $0.matches(query) }
    }
    private var plannedEntries: [OptionCatalogEntry] {
        OptionCatalog.entries.filter { $0.readiness == .notImplemented && $0.matches(query) }
    }

    var body: some View {
        V4FeatureSheet(title: L("Additional options", "추가 옵션")) {
            TextField(L("Find a feature or setting", "기능·설정 찾기"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("option-catalog-search")
            if entries.isEmpty && plannedEntries.isEmpty { Text(L("No matching options", "일치하는 옵션이 없어요")) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(TetherTypography.section)
                    Text(entry.summary).font(TetherTypography.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let target = entry.destination {
                        Button { open(target) } label: {
                            Text(target.actionTitle).foregroundStyle(Color.tetherAccent)
                        }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("option-catalog-open-\(entry.id)")
                    }
                    if entry.id == "O25", model.showsLidOptions {
                        Button(L("Closed-lid helper…", "덮개 유지 도우미…")) {
                            model.settingsPage = .safety
                            dismiss()
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("option-catalog-open-O25-helper")
                    }
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("option-catalog-\(entry.id)")
                Divider()
            }
            let supportEntries = entries.filter { $0.supportDetail != nil }
            if !supportEntries.isEmpty {
                DisclosureGroup(L("Support details", "지원 범위 자세히")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(supportEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(TetherTypography.section)
                                Text(entry.supportDetail ?? "").font(TetherTypography.body).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8)
                }.accessibilityIdentifier("option-catalog-support-details")
            }
            if !plannedEntries.isEmpty {
                DisclosureGroup(L("Unavailable or under review", "미지원·검토 중")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plannedEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(TetherTypography.section)
                                Text(entry.summary).font(TetherTypography.body).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
        } actions: {
            Spacer()
            Button(L("Done", "완료")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
        }
        .sheet(item: $destination) { target in
            switch target {
            case .duration: ManualStartOptionsView(model: model)
            case .manualDefaults: ManualDefaultsOptionsView(model: model)
            case .rules: V4AutomaticRulesView(model: model)
            case .notifications:
                V4FeatureSheet(title: L("Notifications", "알림")) {
                    NotificationSettingsView(model: model, monitor: model.notificationSettings)
                } actions: {
                    Spacer()
                    Button(L("Done", "완료")) { destination = nil }.actionButton().keyboardShortcut(.cancelAction)
                }
            case .lifecycle: LifecycleOptionsView(model: model)
            case .currentWork:
                CurrentWorkOptionsView(model: model) { page in
                    model.settingsPage = page
                    destination = nil
                    dismiss()
                }
            case .keep, .power, .protection, .app: EmptyView()
            }
        }
    }
    private func open(_ target: OptionDestination) {
        switch target {
        case .keep: model.settingsPage = .safety; dismiss()
        case .power: model.settingsPage = .safety; dismiss()
        case .protection: model.settingsPage = .protection; dismiss()
        case .app: model.settingsPage = .system; dismiss()
        default: destination = target
        }
    }
}

/// Reuses the shipping menu controls and their policy checks. The sheet has its
/// own height budget and a single scrolling body, independent of menu-bar placement.
struct CurrentWorkOptionsView: View {
    @ObservedObject var model: AppModel
    var navigateToSettings: (SettingsPage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Menu controls", "메뉴 조작")).font(TetherTypography.section)
                Spacer()
                Button(L("Close", "닫기")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            TetherPanel(model: model, maximumHeight: 360, settingsNavigationAction: navigateToSettings)
        }
        .frame(width: WorkSessionMetrics.panelWidth)
        .background(Color.tetherBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("option-current-work-controls")
    }
}
