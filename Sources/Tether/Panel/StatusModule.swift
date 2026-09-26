import SwiftUI
import TetherCore

/// Power, lid and battery temperature, one row each.
struct StatusModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row(model.powerSymbol, model.powerValue, model.percentText)
            row("laptopcomputer", model.snapshot.lidClosed ? L("Closed", "닫힘") : L("Open", "열림"), model.lidDetail)
            row("thermometer.medium", model.temperatureValue, model.thermalShort, tint: model.thermalColor)
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(radius: Metrics.radius)
    }

    private func row(_ symbol: String, _ value: String, _ detail: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 2)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
