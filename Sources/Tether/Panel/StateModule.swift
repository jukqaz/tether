import SwiftUI
import TetherCore

/// The main module: what Tether is doing, and the switch for clamshell mode. On by default, so
/// connecting power turns clamshell mode on by itself; off gives the lid back to macOS until power
/// is connected again.
struct StateModule: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        let p = model.presentation
        HStack(spacing: compact ? 10 : 12) {
            StateIcon(icon: p.icon, size: compact ? 14 : 17)
                .foregroundStyle(.white)
                .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                .modifier(Orb(color: p.color, active: model.enabled && model.helperInstalled))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(.system(compact ? .subheadline : .headline, design: .rounded).weight(.semibold))
                Text(p.subtitle)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle(L("Clamshell mode", "클램쉘 모드"),
                   isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(compact ? .mini : .small)
                .tint(Color.tetherMint)
                .disabled(!model.helperInstalled)
                .help(L("On power, closing the lid doesn't sleep the Mac. Off: the lid sleeps it as usual until power is connected again.",
                        "전원이 연결되면 덮개를 닫아도 잠들지 않아요. 끄면 전원을 다시 연결할 때까지 평소처럼 덮개를 닫으면 잠들어요."))
        }
        .padding(compact ? Metrics.compactPadding : Metrics.padding)
        .surface(radius: compact ? Metrics.compactRadius : Metrics.radius)
        .animation(.snappy, value: p.title)
    }
}
