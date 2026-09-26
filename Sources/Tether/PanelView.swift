import Charts
import SwiftUI
import TetherCore

/// The menu bar panel, built like macOS Control Center: glass modules, the state circle doubling
/// as the on/off control. Full shows status, battery hold, actions, the last lid session and
/// today's numbers; compact keeps the state module and one row of round buttons.
struct TetherPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage(DesignKey.liquidGlass) private var glass = true

    var body: some View {
        Group {
            if glass && DesignKey.glassOn {
                GlassEffectContainer(spacing: 10) { content }
            } else {
                content
            }
        }
        .padding(model.panelCompact ? 10 : 12)
        .frame(width: model.panelCompact ? 290 : 340)
        .animation(.snappy, value: model.batteryHoldUntil)
        .animation(.snappy, value: model.visibleSession)
    }

    @ViewBuilder
    private var content: some View {
        if model.panelCompact {
            VStack(spacing: 8) {
                if let problem = model.problem {
                    ProblemBanner(problem: problem, model: model, compact: true)
                }
                StateModule(model: model, compact: true)
                CompactControls(model: model)
            }
        } else {
            VStack(spacing: 10) {
                if let problem = model.problem {
                    ProblemBanner(problem: problem, model: model, compact: false)
                }
                StateModule(model: model, compact: false)
                HStack(alignment: .top, spacing: 10) {
                    StatusModule(model: model)
                    if model.helperInstalled, model.helperResponding {
                        HoldModule(model: model)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ActionRow(model: model)
                if let session = model.visibleSession {
                    SessionCard(session: session, model: model)
                }
                if model.usage != nil {
                    TodayModule(model: model)
                }
                Footer(model: model)
            }
        }
    }
}

enum DesignKey {
    /// Liquid Glass surfaces and buttons; off falls back to tinted fills and bordered capsules.
    static let liquidGlass = "liquidGlass"

    /// On by default; `bool(forKey:)` also accepts "NO"/"0" passed as a launch argument.
    static var glassOn: Bool {
        UserDefaults.standard.object(forKey: liquidGlass) == nil ? true : UserDefaults.standard.bool(forKey: liquidGlass)
    }
}

extension View {
    /// A module surface: Liquid Glass, or a tinted fill when glass is off.
    @ViewBuilder
    func surface(tint: Color? = nil, strength: Double = 0.3, radius: CGFloat) -> some View {
        if DesignKey.glassOn {
            glassEffect(.regular.tint(tint.map { $0.opacity(strength) }), in: .rect(cornerRadius: radius))
        } else {
            background((tint ?? .primary).opacity(tint == nil ? 0.06 : strength * 0.4), in: .rect(cornerRadius: radius))
        }
    }

    @ViewBuilder
    func actionButton(prominent: Bool = false) -> some View {
        if DesignKey.glassOn {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}

/// A presentation icon: the Tether mark or an SF Symbol.
private struct StateIcon: View {
    let icon: AppModel.Icon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .mark(let style):
            TetherMark(style: style, size: size * 1.3)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// A round control: tinted glass when on, quiet when off.
private struct Orb: ViewModifier {
    let color: Color
    var active = true
    @AppStorage(DesignKey.liquidGlass) private var glass = true

    func body(content: Content) -> some View {
        let fill = active ? color : Color.secondary.opacity(0.35)
        if glass && DesignKey.glassOn {
            content.glassEffect(.regular.tint(fill).interactive(), in: .circle)
        } else {
            content
                .background(fill.gradient, in: .circle)
                .shadow(color: active ? color.opacity(0.35) : .clear, radius: 6, y: 2)
        }
    }
}

// MARK: State

/// The main module: the circle turns Tether on and off, like a Control Center toggle.
private struct StateModule: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        let p = model.presentation
        HStack(spacing: compact ? 10 : 12) {
            Button {
                model.setEnabled(!model.enabled)
            } label: {
                StateIcon(icon: p.icon, size: compact ? 14 : 17)
                    .foregroundStyle(.white)
                    .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                    .modifier(Orb(color: p.color, active: model.enabled && model.helperInstalled))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!model.helperInstalled)
            .help(model.enabled ? L("Turn Tether off", "Tether 끄기") : L("Turn Tether on", "Tether 켜기"))
            .accessibilityLabel(model.enabled ? L("Turn Tether off", "Tether 끄기") : L("Turn Tether on", "Tether 켜기"))

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(p.title)
                    .font(.system(compact ? .subheadline : .headline, design: .rounded).weight(.semibold))
                Text(p.subtitle)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: !compact)
            }
            Spacer(minLength: 4)
            if compact {
                Label(model.temperatureValue, systemImage: "thermometer.medium")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.thermalColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(model.thermalColor.opacity(0.14), in: .capsule)
                    .help(model.thermalLabel)
            }
        }
        .padding(compact ? 10 : 12)
        .surface(radius: compact ? 16 : 20)
        .animation(.snappy, value: p.title)
    }
}

// MARK: Problem

private struct ProblemBanner: View {
    let problem: AppModel.Problem
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(compact ? .callout : .title3)
                .foregroundStyle(problem.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.title).font((compact ? Font.caption : .subheadline).weight(.semibold))
                if !compact {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = problem.action {
                    Button(action) { model.installHelper() }
                        .actionButton(prominent: true)
                        .tint(problem.color)
                        .controlSize(.small)
                } else {
                    Button(L("Dismiss", "닫기")) { model.errorText = nil }
                        .actionButton()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 12)
        .surface(tint: problem.color, strength: 0.30, radius: compact ? 14 : 18)
    }
}

// MARK: Status

/// Power, lid and battery temperature, one row each.
private struct StatusModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row(model.powerSymbol, model.powerValue, model.percentText)
            row("laptopcomputer", model.snapshot.lidClosed ? L("Closed", "닫힘") : L("Open", "열림"), model.lidDetail)
            row("thermometer.medium", model.temperatureValue, model.thermalShort, tint: model.thermalColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(radius: 20)
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

// MARK: Battery hold

/// Keep clamshell on battery for a while: durations in a menu, then a countdown.
private struct HoldModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let until = model.batteryHoldUntil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            ProgressRing(fraction: model.holdRemainingFraction(at: context.date))
                            Text(model.holdingOnBattery ? L("On battery", "배터리로 유지") : L("Armed", "유지 예약됨"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Text(Texts.countdown(until.timeIntervalSince(context.date)))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(limitLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button(L("End", "끄기")) { model.cancelBatteryHold() }
                    .actionButton()
                    .controlSize(.small)
            } else {
                Label(L("Battery hold", "배터리 유지"), systemImage: "bag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(L("Safe in a bag", "가방에 넣어도 돼요"))
                    .font(.callout.weight(.semibold))
                Text(L("\(model.batteryFloor)% · sleeps if hot", "\(model.batteryFloor)% · 뜨거우면 잠들어요"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Menu(L("Start", "켜기")) {
                    ForEach(model.holdChoices, id: \.self) { minutes in
                        Button(Texts.duration(TimeInterval(minutes * 60))) {
                            model.startBatteryHold(minutes: minutes)
                        }
                    }
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(!model.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(tint: .orange, strength: model.batteryHoldUntil == nil ? 0.12 : 0.30, radius: 20)
        .help(L("Stays awake on battery with the lid closed, even in a bag. Sleeps first if a safety limit is reached.",
                "덮개를 닫고 가방에 넣어도 배터리로 깨어 있어요. 안전 기준에 걸리면 먼저 잠들어요."))
    }

    private var limitLine: String {
        let limits = model.safetyLimits(lidClosed: model.snapshot.lidClosed)
        return L("sleeps at \(Int(limits.hardTemperature))°C · \(model.batteryFloor)%",
                 "\(Int(limits.hardTemperature))°C · \(model.batteryFloor)%에서 잠듦")
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "bag.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.orange)
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: Actions

/// Screen off and sleep now, as two small Control Center modules.
private struct ActionRow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            ActionTile(title: L("Screen Off", "화면 끄기"), symbol: "lock.open.display", enabled: model.canBlank,
                       help: L("Turns the screen off without locking (\(model.combo(for: .blank).display))",
                               "잠그지 않고 화면만 꺼요 (\(model.combo(for: .blank).display))")) {
                dismiss()
                model.blankScreen()
            }
            ActionTile(title: L("Sleep Now", "지금 잠자기"), symbol: "moon.zzz.fill",
                       enabled: model.helperInstalled && model.helperResponding,
                       help: L("Sleeps right away, even on power (\(model.combo(for: .sleepNow).display))",
                               "전원이 연결돼 있어도 바로 잠재워요 (\(model.combo(for: .sleepNow).display))")) {
                dismiss()
                model.sleepNow()
            }
        }
    }
}

private struct ActionTile: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.08), in: .circle)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .surface(radius: 18)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
    }
}

/// The compact panel's controls: round buttons, then settings and more.
private struct CompactControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            round("lock.open.display", help: L("Screen off", "화면 끄기") + " (\(model.combo(for: .blank).display))",
                  enabled: model.canBlank) {
                dismiss()
                model.blankScreen()
            }
            round("moon.zzz.fill", help: L("Sleep now", "지금 잠자기") + " (\(model.combo(for: .sleepNow).display))",
                  enabled: model.helperInstalled && model.helperResponding) {
                dismiss()
                model.sleepNow()
            }
            holdControl
            Spacer(minLength: 0)
            FooterButtons(model: model, openSettings: { openSettings() }, dismiss: { dismiss() })
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var holdControl: some View {
        if let until = model.batteryHoldUntil {
            Button { model.cancelBatteryHold() } label: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ProgressRing(fraction: model.holdRemainingFraction(at: context.date))
                        .frame(width: 34, height: 34)
                        .help(L("Battery hold: \(Texts.countdown(until.timeIntervalSince(context.date))) left · click to end",
                                "배터리 유지 \(Texts.countdown(until.timeIntervalSince(context.date))) 남음 · 누르면 끄기"))
                }
            }
            .buttonStyle(.plain)
        } else if model.helperInstalled, model.helperResponding {
            Menu {
                ForEach(model.holdChoices, id: \.self) { minutes in
                    Button(L("Battery hold ", "배터리 유지 ") + Texts.duration(TimeInterval(minutes * 60))) {
                        model.startBatteryHold(minutes: minutes)
                    }
                }
            } label: {
                Image(systemName: "bag")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .modifier(Orb(color: .orange, active: false))
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.enabled)
            .opacity(model.enabled ? 1 : 0.45)
            .help(L("Battery hold", "배터리에서도 유지"))
        }
    }

    private func round(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .modifier(Orb(color: .gray, active: false))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
    }
}

// MARK: Lid session

/// What happened while the lid was closed, shown for an hour after it opens.
private struct SessionCard: View {
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
        .padding(12)
        .surface(tint: .tetherMint, strength: 0.16, radius: 20)
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

// MARK: Today

/// Today's lid-closed time with a bar per day, and the one number worth a glance: how the last
/// sleep went, or how warm the lid-closed battery ran.
private struct TodayModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let today = model.today
        let week = model.week
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(L("Today", "오늘"), systemImage: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L("Lid closed \(Texts.total(today.lidClosedSeconds))", "덮개 닫고 \(Texts.total(today.lidClosedSeconds))"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let line = detail(today) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Chart(Array(week.enumerated()), id: \.offset) { index, day in
                BarMark(x: .value(L("Day", "날짜"), index), y: .value(L("Hours", "시간"), day.lidClosedSeconds / 3600), width: 6)
                    .foregroundStyle(index == week.count - 1 ? Color.tetherMint : Color.tetherMint.opacity(0.45))
                    .clipShape(.capsule)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, (week.map(\.lidClosedSeconds).max() ?? 0) / 3600))
            .frame(width: 76, height: 32)
            .help(L("Last 7 days, today on the right", "최근 7일, 오른쪽이 오늘"))
        }
        .padding(12)
        .surface(radius: 20)
    }

    private func detail(_ day: DayStats) -> String? {
        if let last = model.lastSleep, let drain = last.drainPerHour {
            return L(String(format: "Last sleep %@ · %.1f%%/h (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain)),
                     String(format: "지난 잠 %@ · 시간당 %.1f%% (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain)))
        }
        if let stats = day.closedTemps, let average = stats.average, let peak = stats.max {
            return L(String(format: "Lid closed: battery avg %.0f°C · peak %.1f°C", average, peak),
                     String(format: "덮개 닫힘 배터리 평균 %.0f°C · 최고 %.1f°C", average, peak))
        }
        if day.forcedSleeps > 0 { return L("put to sleep \(day.forcedSleeps)×", "잠재움 \(day.forcedSleeps)회") }
        return nil
    }
}

// MARK: Footer

private struct Footer: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Text("v\(AppModel.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let event = model.lastEventText {
                Text(event)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event)
            }
            Spacer(minLength: 4)
            FooterButtons(model: model, openSettings: { openSettings() }, dismiss: { dismiss() })
        }
        .padding(.horizontal, 4)
    }
}

/// Size toggle, settings, and the overflow menu.
private struct FooterButtons: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.panelCompact.toggle()
            } label: {
                Image(systemName: model.panelCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(model.panelCompact ? L("Show more", "자세히 보기") : L("Compact", "컴팩트하게 보기"))
            Button {
                // An accessory app has to come forward itself, or the window opens behind others.
                NSApp.activate()
                openSettings()
                dismiss()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help(L("Settings (⌘,)", "설정 (⌘,)"))
            Menu {
                if let update = model.availableUpdate {
                    Button(L("Download Tether \(update)…", "Tether \(update) 받기…")) { model.openReleases() }
                    Divider()
                }
                Button(L("Show Log", "기록 보기")) { model.openLog() }
                Divider()
                Button(L("Quit Tether", "Tether 종료")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: model.availableUpdate == nil ? "ellipsis.circle" : "arrow.down.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }
}
