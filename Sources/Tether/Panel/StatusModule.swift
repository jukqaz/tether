import SwiftUI
import TetherCore

/// Power, lid and battery temperature, one row each.
struct StatusModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row(model.powerSymbol, model.powerValue, model.percentText,
                help: L("Power and battery charge. Clamshell mode is on while power is connected.",
                        "전원과 배터리 잔량. 전원이 연결돼 있으면 클램쉘 모드가 켜져요."))
            row("laptopcomputer", model.snapshot.lidClosed ? L("Closed", "닫힘") : L("Open", "열림"), model.lidDetail,
                help: L("The lid, and the built-in screen: on, dimmed or off.", "덮개와 내장 화면 상태: 켜짐, 어둡게, 꺼짐."))
            row("thermometer.medium", model.temperatureValue, model.thermalShort, tint: model.thermalColor,
                help: L("Battery temperature and heat (normal, fair, serious, critical). A battery hold ends early when it gets hot.",
                        "배터리 온도와 발열 단계(정상, 주의, 심각, 위험). 뜨거워지면 배터리 유지가 먼저 끝나요."))
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(radius: Metrics.radius)
    }

    private func row(_ symbol: String, _ value: String, _ detail: String, tint: Color = .secondary, help: String) -> some View {
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
        .contentShape(.rect)
        .help(help)
    }
}
