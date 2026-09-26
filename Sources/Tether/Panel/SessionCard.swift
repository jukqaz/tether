import SwiftUI
import TetherCore

/// What happened while the lid was closed, shown for an hour after it opens.
struct SessionCard: View {
    let session: LidSession
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("While the lid was closed", "덮개를 닫아 둔 동안"), systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.tetherMint)
                Spacer()
                Button {
                    model.dismissSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(L("Dismiss", "닫기"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                stat(Texts.duration(session.duration), L("time", "시간"))
                stat(session.maxTemperature.map { String(format: "%.1f°", $0) } ?? "–", L("peak", "최고 온도"))
                stat(battery, L("battery", "배터리"))
            }
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Metrics.padding)
        .surface(tint: .tetherMint, strength: 0.16, radius: Metrics.radius)
    }

    private var battery: String {
        guard let a = session.batteryStart, let b = session.batteryEnd else { return "–" }
        return a == b ? "\(a)%" : "\(a)→\(b)%"
    }

    private var footnote: String {
        let start = Date(timeIntervalSince1970: session.start).formatted(date: .omitted, time: .shortened)
        let end = Date(timeIntervalSince1970: session.end ?? session.lastSeen).formatted(date: .omitted, time: .shortened)
        var parts = ["\(start) – \(end)", L("peak heat \(Texts.thermal(session.maxThermal))", "발열 최고 \(Texts.thermal(session.maxThermal))")]
        if session.lowPower { parts.append(L("Low Power Mode used", "저전력 모드 사용")) }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
