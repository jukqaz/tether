import SwiftUI
import TetherCore

/// A System Settings style icon: a white symbol on a coloured rounded square.
struct SidebarIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// One content column for headings and scroll content, including wide windows.
enum SettingsMetrics {
    static let contentWidth: CGFloat = 520
    static let gutter: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let cardInset: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6
    static let controlWidth: CGFloat = 136
    static let conditionWidth: CGFloat = 190

    /// Keep the scroll viewport as wide as its toolbar. Only the readable
    /// column narrows; constraining the Form itself truncates its edge effect.
    static func scrollContentInset(in viewportWidth: CGFloat) -> CGFloat {
        max(gutter, (viewportWidth - contentWidth) / 2)
    }
}

/// One native grouped Form owns scrolling; nested settings groups do not add
/// their own backgrounds or scroll containers over the system reading surface.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.tetherSettingsScrollToEnd) private var scrollToEnd

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .font(TetherTypography.body)
            .toggleStyle(.switch)
            .controlSize(.small)
            .defaultScrollAnchor(scrollToEnd ? .bottom : .top)
            .frame(maxWidth: SettingsMetrics.contentWidth + SettingsMetrics.gutter * 2,
                   maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsScroll<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: title, subtitle: subtitle)
                .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.gutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            Divider()
            if #available(macOS 26.0, *) {
                scrollContent.scrollEdgeEffectHidden(true, for: .top)
            } else {
                scrollContent
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) { content }
                .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.gutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TetherTypography.page)
                .foregroundStyle(Color.tetherPrimary)
            if !compact {
                Text(subtitle).font(TetherTypography.secondary).lineSpacing(2).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        Section {
            content
        } header: {
            SettingsSectionHeading(title: title, symbol: symbol)
        } footer: {
            if let footer {
                Text(footer).font(TetherTypography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Native sections supply the macOS preference grouping and row separators.
struct SettingsContentGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title).font(TetherTypography.section)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    var summary: String? = nil
    @Binding var isExpanded: Bool
    var groupsSection = true
    @ViewBuilder var content: Content

    @ViewBuilder var body: some View {
        if groupsSection {
            Section { disclosure }
        } else {
            disclosure
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content.padding(.top, 6).padding(.bottom, 2)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(TetherTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let summary {
                    Text(summary).font(TetherTypography.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsSectionHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(TetherTypography.section)
        .foregroundStyle(Color.tetherPrimary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }
}

/// Auxiliary diagnostics still use cards outside a Form; settings pages use native sections.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeading(title: title, symbol: symbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, SettingsMetrics.cardInset)
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) { content }
                .padding(SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .workSessionCardSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    var showsAccessibleTitle = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                // Grouped Form can stack LabeledContent even when both sides
                // fit. Measure a real horizontal row so only overflow falls
                // through, while the switches and pickers stay native.
                HStack(alignment: .center, spacing: 10) {
                    Text(title).font(TetherTypography.body).fixedSize()
                        .accessibilityHidden(!showsAccessibleTitle)
                    Spacer(minLength: 0)
                    content.fixedSize(horizontal: true, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(TetherTypography.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(!showsAccessibleTitle)
                    content.fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            if let detail { Note(detail) }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}


struct StatusBadge: View {
    let text: String
    var color: Color = .tetherSecondary
    var symbol: String = "circle.fill"
    var body: some View {
        Label(text, systemImage: symbol)
            .font(TetherTypography.secondary.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.10), in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    var hint: String? = nil
    @Binding var isOn: Bool
    var identifier: String? = nil
    var body: some View {
        SettingRow(title: title, detail: detail, showsAccessibleTitle: false) {
            identifiedToggle
        }
    }

    @ViewBuilder private var identifiedToggle: some View {
        if let identifier {
            nativeToggle.accessibilityIdentifier(identifier)
        } else {
            nativeToggle
        }
    }

    private var nativeToggle: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            .tint(.tetherAction)
            .accessibilityLabel(title)
            .accessibilityHint(hint ?? detail ?? "")
    }
}

struct Reading: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(title).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
            }.font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            Text(value).font(TetherTypography.countdown)
                .monospacedDigit().foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Noninteractive identity for the isolated build, not a toolbar action.
struct PreviewIndicator: View {
    var body: some View {
        Label(L("Preview", "미리보기"), systemImage: "eye")
            // Window toolbars default labels to icon-only. This is an identity
            // warning, so its text must remain visible in every host.
            .labelStyle(.titleAndIcon)
            .font(TetherTypography.secondary.weight(.medium))
            .foregroundStyle(Color.tetherSecondary)
            .fixedSize()
            .help(L("Simulated sensors and sleep requests; no system power changes.",
                    "기기 상태와 절전 요청은 모의값이며 실제 전원 설정은 바꾸지 않습니다."))
            .accessibilityLabel(L("Preview, simulated sensors and sleep requests",
                                  "미리보기, 기기 상태와 절전 요청은 모의값입니다"))
            .accessibilityIdentifier("preview-indicator")
    }
}

struct PreviewNotice: View {
    // Store the translated value so a language change also invalidates this leaf.
    private let text = L("Preview · simulated sensors and sleep requests", "미리보기 · 기기 상태와 절전 요청은 모의값입니다")
    var body: some View {
        Label(text, systemImage: "testtube.2")
            .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An ⓘ right after a setting whose meaning isn't clear from its name; it opens a short
/// explanation (`SettingsInfo`).
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.tetherSecondary)
        }
        .buttonStyle(.borderless)
        .help(L("What this means", "설명 보기"))
        .accessibilityLabel(L("About this setting", "이 설정 설명"))
        .accessibilityHint(L("Open an explanation", "설명 창을 엽니다"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(text).font(TetherTypography.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("Close", "닫기")) { shown = false }.keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: 320, alignment: .leading).padding(14)
            .workSessionWindowSurface()
            .onExitCommand { shown = false }
        }
    }
}

/// A setting's name followed by its ⓘ.
struct InfoLabel: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(info).accessibilityLabel(L("About \(title)", "\(title) 설명"))
        }
    }
}

struct Note: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .tetherSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(TetherTypography.secondary)
            .lineSpacing(1)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A screen limitation stays visible beside the work session, without ending it.
struct DisplaySleepNotice: View {
    @ObservedObject var model: AppModel
    var showsReview = true

    var body: some View {
        if let status = model.displaySleepStatus {
            let needsReview = [.deferred, .stopped].contains(status.phase)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 10) {
                    Label(model.displaySleepSummary ?? status.summary, systemImage: needsReview ? "display.trianglebadge.exclamationmark" : "display")
                        .font(TetherTypography.secondary)
                        .foregroundStyle(needsReview ? Color.tetherWarning : Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(L("This is a macOS observation or a request status, not a measurement of panel power.",
                                "macOS 관측값과 요청 상태입니다. 패널 소비 전력을 측정한 값은 아닙니다."))
                    Spacer(minLength: 0)
                    if showsReview && needsReview {
                        Button(L("Review…", "점검하기…")) { model.presentActivityReview() }
                            .buttonStyle(.borderless).font(TetherTypography.secondary.weight(.medium)).fixedSize()
                            .accessibilityLabel(L("Review display sleep status", "디스플레이 절전 상태 점검"))
                    }
                }
                if model.displaySleepDetail != nil || status.phase == .deferred || status.phase == .unavailable {
                    Text(model.displaySleepDetail ?? L("Work and session time limits continue.", "작업 유지와 세션 시간 한도는 계속 적용됩니다."))
                        .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct CommandRows: View {
    let rows: [(command: String, meaning: String)]

    var body: some View {
        ForEach(rows, id: \.command) { row in
            LabeledContent {
                Text(row.meaning).foregroundStyle(Color.tetherSecondary)
            } label: {
                Text(row.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

/// "43°C", "43°C (default)", "40°C (recommended)", "43°C (default · recommended)".
func choice(_ text: String, isDefault: Bool, isRecommended: Bool) -> String {
    switch (isDefault, isRecommended) {
    case (true, true): L("\(text) (default · recommended)", "\(text) (기본·추천)")
    case (true, false): L("\(text) (default)", "\(text) (기본)")
    case (false, true): L("\(text) (recommended)", "\(text) (추천)")
    case (false, false): text
    }
}

func temperatureSummary(_ stats: TempStats) -> String {
    guard let usual = stats.percentile(0.5), let peak = stats.max else { return L("no data yet", "아직 기록 없음") }
    return L(String(format: "usually %.0f°C · peak %.1f°C", usual, peak), String(format: "보통 %.0f°C · 최고 %.1f°C", usual, peak))
}

/// A fixed behavior contract remains readable above secondary explanations.
struct PolicyNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TetherSettingsScrollToEndKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var tetherSettingsScrollToEnd: Bool {
        get { self[TetherSettingsScrollToEndKey.self] }
        set { self[TetherSettingsScrollToEndKey.self] = newValue }
    }
}
