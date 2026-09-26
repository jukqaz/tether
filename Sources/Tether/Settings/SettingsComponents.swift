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

struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CommandRows: View {
    let rows: [(command: String, meaning: String)]

    var body: some View {
        ForEach(rows, id: \.command) { row in
            LabeledContent {
                Text(row.meaning).foregroundStyle(.secondary)
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
