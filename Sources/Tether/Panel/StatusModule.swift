import SwiftUI
import TetherCore

struct StatusModule: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                metric(L("Power", "전원"), model.powerValue, model.powerSymbol)
                if model.hasInternalBattery { metric(L("Battery", "배터리"), model.percentText, "battery.75percent") }
                metric(model.usesUserSession ? L("Thermal pressure", "시스템 발열") : L("Temperature", "온도"), model.temperatureValue, "thermometer.medium")
            }
            Divider()
            Label(model.lidDetail, systemImage: model.deviceStatusSymbol)
                .font(.caption).foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.padding).padding(.vertical, 10)
    }
    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 12)).foregroundStyle(Color.tetherSecondary)
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
