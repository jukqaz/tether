import SwiftUI
import TetherCore

/// The panel owns observation lifetime. This read-only view neither creates a
/// timer nor changes a work request when its disclosure is expanded.
struct PowerBatteryDetails: View {
    @ObservedObject var monitor: PowerBatteryMonitor
    @Binding var isExpanded: Bool

    var presentation: PowerBatteryPresentation {
        PowerBatteryPresentation(reading: monitor.reading, phase: monitor.phase,
                                 evaluatedAt: monitor.evaluatedAt)
    }

    var body: some View {
        let value = presentation
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let message = value.message {
                    note(message)
                        .accessibilityIdentifier("panel-power-freshness")
                } else {
                    group(title: value.batteryTitle, rows: value.batteryRows, note: value.batteryNote,
                          noteIdentifier: "panel-power-battery-note")
                    Divider()
                    group(title: value.chargerTitle, rows: value.chargerRows, note: value.chargerNote,
                          noteIdentifier: "panel-power-charger-note")
                    if !value.sensorRows.isEmpty {
                        Divider()
                        rows(value.sensorRows)
                            .padding(.leading, WorkSessionMetrics.hierarchyIndent)
                    }
                    if let observed = value.observedText {
                        note(observed)
                            .padding(.leading, WorkSessionMetrics.hierarchyIndent)
                            .accessibilityIdentifier("panel-power-observed-at")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, WorkSessionMetrics.disclosureContentInset)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel-power-detail-content")
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value.title).fixedSize()
                    if !isExpanded {
                        Spacer(minLength: 4)
                        summary(value.summary).fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.title).fixedSize(horizontal: false, vertical: true)
                    if !isExpanded { summary(value.summary) }
                }
            }
            .padding(.leading, WorkSessionMetrics.disclosureLabelInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(TetherTypography.body)
            .foregroundStyle(Color.tetherPrimary)
        }
        .accessibilityIdentifier("panel-power-details")
    }

    private func summary(_ value: String) -> some View {
        Text(value)
            .font(TetherTypography.secondary)
            .foregroundStyle(Color.tetherSecondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("panel-power-summary")
    }

    private func group(title: String, rows values: [PowerBatteryPresentation.Row], note detail: String?,
                       noteIdentifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            rows(values)
                .padding(.leading, WorkSessionMetrics.hierarchyIndent)
            if let detail {
                note(detail)
                    .padding(.leading, WorkSessionMetrics.hierarchyIndent)
                    .accessibilityIdentifier(noteIdentifier)
            }
        }
    }

    private func rows(_ values: [PowerBatteryPresentation.Row]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(values) { value in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(value.title).fixedSize()
                        Spacer(minLength: 0)
                        reading(value).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.title).fixedSize(horizontal: false, vertical: true)
                        reading(value)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(TetherTypography.body)
                .foregroundStyle(Color.tetherPrimary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("panel-power-\(value.id)")
            }
        }
    }

    private func reading(_ value: PowerBatteryPresentation.Row) -> some View {
        Text(value.value)
            .font(TetherTypography.body.weight(value.prominent ? .semibold : .regular))
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ value: String) -> some View {
        Text(value).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
