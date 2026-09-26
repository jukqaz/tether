import Charts
import SwiftUI
import TetherCore

/// The settings window, laid out like System Settings: a sidebar of coloured icons, a grouped
/// form on the right. Measurements sit next to the settings they inform; the full record is in
/// "History".
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page: SettingsPage?

    init(model: AppModel, initialPage: SettingsPage = .general) {
        self.model = model
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label {
                    Text(page.title)
                } icon: {
                    SidebarIcon(symbol: page.symbol, color: page.color)
                }
                .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let current = page ?? .general
            current.page(model: model)
                .navigationTitle(current.title)
        }
        .frame(width: 800, height: 620)
        .background(SettingsWindowBridge())
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, lid, safety, history, notifications, control, system

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L("General", "일반")
        case .lid: L("Lid & Screen", "덮개와 화면")
        case .safety: L("Safety", "배터리와 발열")
        case .history: L("History", "기록")
        case .notifications: L("Notifications", "알림")
        case .control: L("Automation", "단축키·자동화")
        case .system: L("System", "시스템")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .lid: "laptopcomputer"
        case .safety: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .notifications: "bell.badge.fill"
        case .control: "keyboard.fill"
        case .system: "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .lid: .blue
        case .safety: .orange
        case .history: .tetherMint
        case .notifications: .red
        case .control: .purple
        case .system: Color(white: 0.45)
        }
    }

    @MainActor @ViewBuilder
    func page(model: AppModel) -> some View {
        switch self {
        case .general: GeneralPage(model: model)
        case .lid: LidPage(model: model)
        case .safety: SafetyPage(model: model)
        case .history: HistoryPage(model: model)
        case .notifications: NotificationsPage(model: model)
        case .control: ControlPage(model: model)
        case .system: SystemPage(model: model)
        }
    }
}

/// Keeps the settings window reachable. Tether has no Dock icon, and the window of such an
/// accessory app was taken off screen as soon as another app came forward (a System Settings
/// link, say), with no ⌘-Tab entry to get back. While the window is open Tether is a regular
/// app instead: Dock icon, ⌘-Tab, window stays put. Closing it returns Tether to the menu bar.
struct SettingsWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowWatcher: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.hidesOnDeactivate = false
            let center = NotificationCenter.default
            // SwiftUI may reuse the window after it closes, so opening again is seen as "became key".
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { _ in
                MainActor.assumeIsolated { Self.showInDock(true) }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                queue: .main) { _ in
                MainActor.assumeIsolated { Self.showInDock(false) }
            })
            Self.showInDock(true)
        }

        static func showInDock(_ on: Bool) {
            let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
            guard NSApp.activationPolicy() != policy else { return }
            NSApp.setActivationPolicy(policy)
            if on { NSApp.activate() }
        }
    }
}

// MARK: Building blocks

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

private struct Page<Content: View>: View {
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

private struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct CommandRows: View {
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
private func choice(_ text: String, isDefault: Bool, isRecommended: Bool) -> String {
    switch (isDefault, isRecommended) {
    case (true, true): L("\(text) (default · recommended)", "\(text) (기본·추천)")
    case (true, false): L("\(text) (default)", "\(text) (기본)")
    case (false, true): L("\(text) (recommended)", "\(text) (추천)")
    case (false, false): text
    }
}

private func temperatureSummary(_ stats: TempStats) -> String {
    guard let usual = stats.percentile(0.5), let peak = stats.max else { return L("no data yet", "아직 기록 없음") }
    return L(String(format: "usually %.0f°C · peak %.1f°C", usual, peak), String(format: "보통 %.0f°C · 최고 %.1f°C", usual, peak))
}

// MARK: General

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    @AppStorage(DesignKey.liquidGlass) private var glass = true

    var body: some View {
        Page {
            Section {
                Toggle(L("Open at login", "로그인하면 자동으로 열기"),
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } footer: {
                Note(L("Keeping the screen unlocked, dimming with the lid closed and turning the screen off need this app running. The power rules themselves are kept by the helper even when the app is closed.",
                       "화면이 잠기지 않게 붙잡는 일, 덮개를 닫았을 때 어둡게 하기, 화면 끄기는 이 앱이 켜져 있어야 해요. 전원 규칙 자체는 앱이 꺼져 있어도 도우미가 지켜요."))
            }

            Section {
                Picker(L("Panel", "패널"), selection: $model.panelCompact) {
                    Text(L("Full", "자세히")).tag(false)
                    Text(L("Compact", "컴팩트")).tag(true)
                }
                .pickerStyle(.segmented)
                Toggle(L("Liquid Glass", "리퀴드 글래스"), isOn: $glass)
            } header: {
                Text(L("Appearance", "모양"))
            } footer: {
                Note(L("Compact shows the state and one row of round buttons; the button at the bottom of the panel switches too. Without Liquid Glass, cards and buttons are opaque.",
                       "컴팩트는 상태와 동그란 버튼 한 줄만 보여 줘요. 패널 아래 버튼으로도 바꿀 수 있어요. 리퀴드 글래스를 끄면 불투명한 카드와 버튼을 써요."))
            }

            Section {
                Toggle(L("Show the hold countdown and heat temperature", "배터리 유지 남은 시간과 발열 온도 표시"), isOn: $model.menuBarDetails)
            } header: {
                Text(L("Menu Bar", "메뉴바"))
            } footer: {
                Note(L("During a battery hold the time left, and with the lid closed and running hot the battery temperature, appear next to the icon.",
                       "배터리 유지 중에는 남은 시간을, 덮개를 닫고 뜨거울 때는 배터리 온도를 아이콘 옆에 보여 줘요."))
            }
        }
    }
}

// MARK: Lid and screen

private struct LidPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Picker(L("When the lid closes", "덮개를 닫으면"), selection: $model.lidCloseLocks) {
                    Text(L("Stay unlocked, dim the screen", "잠그지 않고 화면만 어둡게")).tag(false)
                    Text(L("Lock the screen", "화면 잠그기")).tag(true)
                }
                .disabled(!ScreenLock.available && !model.lidCloseLocks)
                LabeledContent(L("Built-in screen and keyboard light", "내장 화면과 키보드 조명")) {
                    Text(L("dimmed to 0 · restored when the lid opens", "0으로 내림 · 덮개를 열면 복원"))
                }
                LabeledContent(L("With an external display", "외장 모니터가 있을 때")) {
                    Text(L("left to macOS · never locked", "macOS에 맡김 · 잠그지 않음"))
                }
            } header: {
                Text(L("Lid Closed", "덮개를 닫았을 때"))
            } footer: {
                Note(model.lidCloseLocks
                     ? L("It locks the moment the lid closes. Opening the lid or connecting remotely asks for your password or Touch ID, and display sleep and locking follow your macOS settings.",
                         "덮개를 닫는 순간 잠겨요. 덮개를 열거나 원격으로 접속하면 암호나 Touch ID가 필요하고, 화면 끄기와 잠금은 macOS 설정을 그대로 따라요.")
                     : L("Nothing locks, so remote sessions and reopening the lid carry on right away. The screen under the lid is dimmed so it doesn't heat up.",
                         "잠그지 않으니 원격 접속이나 덮개를 열 때 바로 이어서 쓸 수 있어요. 덮개 아래에서 화면이 켜진 채 열이 나지 않도록 어둡게 해요."))
            }

            Section {
                Picker(L("Turn the screen off when idle", "입력이 없으면 화면 끄기"), selection: $model.idleBlankMinutes) {
                    ForEach(AppModel.idleChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? L("Never", "사용 안 함") : L("After \(minutes) min", "\(minutes)분 뒤")).tag(minutes)
                    }
                }
                LabeledContent(L("Now", "지금 끄기")) {
                    Button(L("Screen Off", "화면 끄기") + " (\(model.combo(for: .blank).display))") { model.blankScreen() }
                        .disabled(!model.canBlank)
                }
            } header: {
                Text(L("Screen Off Without Locking", "잠금 없이 화면 끄기"))
            } footer: {
                Note(model.lidCloseLocks
                     ? L("With “Lock the screen”, macOS's own display sleep and lock apply, so this isn't used.",
                         "'화면 잠그기'를 고르면 macOS의 화면 끄기·잠금 설정을 따르므로 쓰지 않아요.")
                     : L("In clamshell mode macOS's display sleep is held off so nothing locks. Instead, when idle, Tether turns the screen black; any input brings it straight back. It waits while another app keeps the screen on, like a video or a call.",
                         "클램쉘 모드에서는 화면이 잠기지 않도록 macOS의 화면 끄기를 막아요. 대신 입력이 없으면 Tether가 화면을 검게 만들고, 마우스나 키보드를 쓰면 바로 돌아와요. 동영상이나 화상 회의처럼 다른 앱이 화면을 켜 두는 동안에는 끄지 않아요."))
            }
            .disabled(model.lidCloseLocks)
        }
    }
}

// MARK: Battery and heat

private struct SafetyPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let summary = model.summary
        let advice = model.recommendations
        Page {
            Section {
                LabeledContent(L("Battery, lid closed", "덮개 닫힘 배터리 온도")) { Text(temperatureSummary(summary.closed)) }
                LabeledContent(L("Battery, lid open", "덮개 열림 배터리 온도")) { Text(temperatureSummary(summary.open)) }
                LabeledContent(L("Used during battery holds", "배터리 유지 중 사용량")) {
                    Text(summary.drainPerHour.map { L(String(format: "%.0f%% an hour", $0), String(format: "시간당 %.0f%%", $0)) }
                         ?? L("no data yet", "아직 기록 없음"))
                }
                LabeledContent(L("Used while asleep", "잠자는 동안 사용량")) {
                    Text(model.sleepLog.averageDrain.map {
                        L(String(format: "%.1f%% an hour · %@", $0, Texts.drainLevel($0)), String(format: "시간당 %.1f%% · %@", $0, Texts.drainLevel($0)))
                    } ?? L("no data yet", "아직 기록 없음"))
                }
                LabeledContent(L("Heat guard", "발열 보호")) {
                    Text(summary.heatGuards == 0 ? L("never needed", "켜진 적 없음")
                         : L("\(summary.heatGuards)× · peak heat with the lid closed: \(Texts.thermal(summary.closedMaxThermal))",
                             "\(summary.heatGuards)회 · 덮개 닫힘 최고 발열 \(Texts.thermal(summary.closedMaxThermal))"))
                }
                if !advice.isEmpty, model.recommendationsDiffer {
                    LabeledContent {
                        Button(L("Apply", "추천값 적용")) { model.applyRecommendations() }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    } label: {
                        Label(adviceSummary(advice), systemImage: "wand.and.stars")
                    }
                }
            } header: {
                Text(L("Measured on This Mac · Last 7 Days", "이 Mac에서 잰 값 · 최근 7일"))
            } footer: {
                Note(adviceNote(advice))
            }

            Section {
                Picker(L("End at this much battery", "배터리가 이만큼 남으면 끝내기"),
                       selection: limit(\.batteryFloor, SafetyPolicy.floor(model.limits), default: SafetyPolicy.batteryFloor)) {
                    ForEach(SafetyPolicy.floorChoices, id: \.self) { value in
                        Text(choice("\(value)%", isDefault: value == SafetyPolicy.batteryFloor, isRecommended: false)).tag(value)
                    }
                }
                Picker(L("Lid closed · end at once at", "덮개 닫힘 · 이 온도면 바로 끝내기"),
                       selection: limit(\.closedLidMaxTemperature, model.safetyLimits(lidClosed: true).hardTemperature,
                                        default: SafetyPolicy.closedLid.hardTemperature)) {
                    ForEach(SafetyPolicy.closedLidChoices, id: \.self) { value in
                        Text(choice("\(Int(value))°C", isDefault: value == SafetyPolicy.closedLid.hardTemperature,
                                    isRecommended: value == advice.closedLid?.value)).tag(value)
                    }
                }
                Picker(L("Lid open · end at once at", "덮개 열림 · 이 온도면 바로 끝내기"),
                       selection: limit(\.openLidMaxTemperature, model.safetyLimits(lidClosed: false).hardTemperature,
                                        default: SafetyPolicy.openLid.hardTemperature)) {
                    ForEach(SafetyPolicy.openLidChoices, id: \.self) { value in
                        Text(choice("\(Int(value))°C", isDefault: value == SafetyPolicy.openLid.hardTemperature,
                                    isRecommended: value == advice.openLid?.value)).tag(value)
                    }
                }
                Picker(L("Longest hold", "한 번에 최대"), selection: limit(\.maxHoldHours, SafetyPolicy.maxHold(model.limits) / 3600,
                                                                   default: SafetyPolicy.maxHold / 3600)) {
                    ForEach(SafetyPolicy.maxHoldChoices, id: \.self) { hours in
                        Text(choice(L("\(Int(hours)) h", "\(Int(hours))시간"), isDefault: hours == SafetyPolicy.maxHold / 3600,
                                    isRecommended: hours == advice.maxHold?.value)).tag(hours)
                    }
                }
            } header: {
                Text(L("Battery Hold", "배터리에서도 유지"))
            } footer: {
                Note(L("Limits can't be looser than the defaults. With the lid closed it also ends after a minute at 3°C below the limit, or at “serious” heat. If the battery temperature can't be read, it ends at once.",
                       "기본값보다 느슨하게는 바꿀 수 없어요. 덮개가 닫혀 있으면 이 온도보다 3°C 낮은 상태가 1분 이어지거나 발열이 '심각'이 돼도 끝내요. 배터리 온도를 읽지 못하면 바로 끝내요."))
            }

            Section {
                Toggle(L("Heat guard", "발열 보호"), isOn: Binding(get: { model.heatGuard.enabled }, set: { on in
                    var settings = model.heatGuard
                    settings.enabled = on
                    model.setHeatGuard(settings)
                }))
                Picker(L("Turn Low Power Mode on from", "저전력 모드를 켜는 단계"), selection: Binding(get: { model.heatGuard.threshold }, set: { level in
                    var settings = model.heatGuard
                    settings.level = level
                    model.setHeatGuard(settings)
                })) {
                    Text(choice(L("“fair” heat", "발열 '보통'부터"), isDefault: false, isRecommended: advice.heatLevel?.value == 1)).tag(1)
                    Text(choice(L("“serious” heat", "발열 '심각'부터"), isDefault: true, isRecommended: advice.heatLevel?.value == 2)).tag(2)
                }
                .disabled(!model.heatGuard.enabled)
            } header: {
                Text(L("Heat Guard · On Power, Lid Closed", "발열 보호 · 전원 연결, 덮개 닫힘"))
            } footer: {
                Note(L("When it runs hot, Low Power Mode cools it; after \(Int(ACThermalPolicy.coolDown / 60)) cool minutes the setting is restored. It never sleeps the Mac, so remote work keeps going.",
                       "뜨거워지면 저전력 모드로 식히고, \(Int(ACThermalPolicy.coolDown / 60))분 동안 식으면 원래대로 돌려요. 원격 작업이 끊기지 않도록 잠재우지는 않아요."))
            }

            Section {
                HStack {
                    if model.helperOutdated {
                        Label(L("Update the helper to apply these", "도우미를 업데이트해야 적용돼요"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(L("Restore Defaults", "기본값으로 되돌리기")) { model.resetSafety() }
                        .disabled(model.limits.isDefault && model.heatGuard == .standard)
                }
            }
        }
    }

    private func adviceSummary(_ a: AppModel.Recommendations) -> String {
        var parts: [String] = []
        if let v = a.closedLid?.value { parts.append(L("lid closed \(Int(v))°C", "덮개 닫힘 \(Int(v))°C")) }
        if let v = a.openLid?.value { parts.append(L("lid open \(Int(v))°C", "덮개 열림 \(Int(v))°C")) }
        if let v = a.maxHold?.value { parts.append(L("up to \(Int(v)) h", "최대 \(Int(v))시간")) }
        if let v = a.heatLevel?.value { parts.append(L("heat guard from “\(Texts.thermal(v))”", "발열 '\(Texts.thermal(v))'부터")) }
        return L("Recommended: ", "추천: ") + parts.joined(separator: " · ")
    }

    private func adviceNote(_ a: AppModel.Recommendations) -> String {
        let reasons = [a.closedLid?.reason, a.openLid?.reason, a.maxHold?.reason, a.heatLevel?.reason].compactMap { $0 }
        guard !reasons.isEmpty else {
            return L("The helper records battery temperature and heat every 30 seconds. After about 30 minutes with the lid closed, recommendations for this Mac appear here.",
                     "도우미가 30초마다 배터리 온도와 발열을 기록해요. 덮개를 닫고 30분쯤 쓰면 이 Mac에 맞는 추천값을 보여 줘요.")
        }
        return reasons.joined(separator: " · ")
            + L(". Recommendations sit 4°C above the usual peak: ordinary use never trips them, a bag soon does.",
                ". 추천은 평소 최고 온도보다 4°C 위로 잡아서, 평소에는 멈추지 않고 가방 안처럼 뜨거워지면 일찍 멈추게 해요.")
    }

    /// A picker binding for one user limit: shows the value in force, stores nil for the default.
    private func limit<V: Equatable>(_ key: WritableKeyPath<UserLimits, V?>, _ current: V, default standard: V) -> Binding<V> {
        Binding(get: { current }, set: { value in
            var limits = model.limits
            limits[keyPath: key] = value == standard ? nil : value
            model.setLimits(limits)
        })
    }
}

// MARK: History

private struct HistoryPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let week = model.week
        let hasTemperatures = week.contains { $0.closedTemps != nil || $0.openTemps != nil }
        let sleeps = Array(model.sleepLog.recent.suffix(6).reversed())
        let sessions = Array((model.usage?.recentSessions ?? []).suffix(5).reversed())
        Page {
            Section {
                if hasTemperatures {
                    TemperatureChart(week: week, closedLimit: model.safetyLimits(lidClosed: true).hardTemperature,
                                     openLimit: model.safetyLimits(lidClosed: false).hardTemperature)
                        .padding(.vertical, 6)
                } else {
                    Text(L("Nothing yet. The helper records the battery temperature every 30 seconds.",
                           "아직 기록이 없어요. 도우미가 30초마다 배터리 온도를 기록해요."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Daily Peak Battery Temperature · Last 7 Days", "하루 최고 배터리 온도 · 최근 7일"))
            } footer: {
                Note(L("Dashed lines are your battery-hold limits. The further below them, the more headroom.",
                       "점선은 지금 설정한 배터리 유지 한계예요. 선이 한계에서 멀수록 여유가 있어요."))
            }

            Section {
                if sleeps.isEmpty {
                    Text(L("Nothing yet. Sleeps appear here after the Mac wakes.", "아직 기록이 없어요. 잠들었다 깨면 여기에 남아요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sleeps, id: \.sleptAt) { SleepRow(record: $0) }
                }
            } header: {
                HStack {
                    Text(L("Recent Sleeps", "최근 잠자기"))
                    Spacer()
                    if let average = model.sleepLog.averageDrain {
                        Text(L(String(format: "avg %.1f%%/h · %@", average, Texts.drainLevel(average)),
                               String(format: "평균 시간당 %.1f%% · %@", average, Texts.drainLevel(average))))
                            .foregroundStyle(average >= SleepLog.highDrain ? .red : .secondary)
                    }
                }
            } footer: {
                Note(L("Charge per hour is worked out for sleeps of 30 minutes or more on battery. 1–2% an hour is typical; over 3% means something keeps waking it.",
                       "배터리로 30분 넘게 잠든 경우만 시간당 사용량을 계산해요. 보통 시간당 1~2%이고, 3%를 넘으면 무언가 자꾸 깨우는 거예요."))
            }

            Section {
                if sessions.isEmpty {
                    Text(L("Nothing yet. Keeping the lid closed for 5 minutes or more records a session.",
                           "아직 기록이 없어요. 덮개를 5분 넘게 닫아 두면 여기에 남아요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.start) { SessionRow(session: $0) }
                }
            } header: {
                Text(L("Recent Lid Sessions", "최근 덮개 세션"))
            }

            Section {
                let total = week.reduce(0) { $0 + $1.lidClosedSeconds }
                LabeledContent(L("Awake with the lid closed", "덮개 닫고 깨어 있던 시간")) { Text(Texts.total(total)) }
                LabeledContent(L("Put to sleep by Tether", "Tether가 재운 횟수")) {
                    Text(L("\(week.reduce(0) { $0 + $1.forcedSleeps })×", "\(week.reduce(0) { $0 + $1.forcedSleeps })회"))
                }
                LabeledContent(L("Battery holds", "배터리 유지")) {
                    Text(L("\(week.reduce(0) { $0 + $1.batteryHolds })×", "\(week.reduce(0) { $0 + $1.batteryHolds })회"))
                }
                LabeledContent(L("Heat guard", "발열 보호")) {
                    Text(L("\(week.reduce(0) { $0 + $1.heatGuards })×", "\(week.reduce(0) { $0 + $1.heatGuards })회"))
                }
            } header: {
                Text(L("Last 7 Days", "최근 7일"))
            } footer: {
                Note(L("Records stay on this Mac: stats for 7 days, the last 20 sleeps, the last 10 lid sessions.",
                       "기록은 이 Mac에만 저장돼요. 통계는 7일, 잠자기는 최근 20번, 덮개 세션은 최근 10개까지 보관해요."))
            }
        }
    }
}

private struct TemperatureChart: View {
    let week: [DayStats]
    let closedLimit: Double
    let openLimit: Double

    private struct Point: Identifiable {
        let id: String
        let day: String
        let state: String
        let value: Double
    }

    var body: some View {
        let closedName = L("lid closed", "덮개 닫힘"), openName = L("lid open", "덮개 열림")
        let labels = week.indices.map { $0 == week.count - 1 ? L("Today", "오늘") : Self.weekday(week[$0].day) }
        let points: [Point] = week.indices.flatMap { i -> [Point] in
            var out: [Point] = []
            if let peak = week[i].closedTemps?.max { out.append(Point(id: "\(i)c", day: labels[i], state: closedName, value: peak)) }
            if let peak = week[i].openTemps?.max { out.append(Point(id: "\(i)o", day: labels[i], state: openName, value: peak)) }
            return out
        }
        Chart {
            ForEach(points) { p in
                LineMark(x: .value(L("Day", "날짜"), p.day), y: .value(L("Peak", "최고 온도"), p.value), series: .value(L("State", "상태"), p.state))
                    .foregroundStyle(by: .value(L("State", "상태"), p.state))
                    .interpolationMethod(.monotone)
                PointMark(x: .value(L("Day", "날짜"), p.day), y: .value(L("Peak", "최고 온도"), p.value))
                    .foregroundStyle(by: .value(L("State", "상태"), p.state))
                    .symbolSize(26)
            }
            RuleMark(y: .value(L("Lid-closed limit", "덮개 닫힘 한계"), closedLimit))
                .foregroundStyle(Color.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .trailing) {
                    Text(L("lid-closed limit \(Int(closedLimit))°", "덮개 닫힘 한계 \(Int(closedLimit))°")).font(.caption2).foregroundStyle(.orange)
                }
            RuleMark(y: .value(L("Lid-open limit", "덮개 열림 한계"), openLimit))
                .foregroundStyle(Color.blue.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text(L("lid-open limit \(Int(openLimit))°", "덮개 열림 한계 \(Int(openLimit))°")).font(.caption2).foregroundStyle(.blue)
                }
        }
        .chartForegroundStyleScale([closedName: Color.orange, openName: Color.blue])
        .chartXScale(domain: labels)
        .chartYScale(domain: 25...48)
        .chartYAxis {
            AxisMarks(position: .leading, values: [30, 35, 40, 45]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))°") }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 180)
    }

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Localization.current == .korean ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US")
        f.dateFormat = "E"
        return f
    }()

    static func weekday(_ key: String) -> String {
        keyFormat.date(from: key).map { weekdayFormat.string(from: $0) } ?? key
    }
}

private struct SleepRow: View {
    let record: SleepRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.byTether ? "moon.zzz.fill" : "moon.fill")
                .foregroundStyle(.indigo)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.when(record.sleptAt)) · \(Texts.duration(record.duration ?? 0))")
                    .font(.callout.weight(.medium))
                Text(causes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(battery)
                    .font(.callout)
                    .monospacedDigit()
                if let drain = record.drainPerHour {
                    Text(L(String(format: "%.1f%%/h", drain), String(format: "시간당 %.1f%%", drain)))
                        .font(.caption)
                        .foregroundStyle(drain >= SleepLog.highDrain ? .red : (drain >= 1.5 ? .orange : .secondary))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var causes: String {
        var text = "\(Texts.sleepCause(record)) → \(Texts.wakeCause(record))"
        if record.darkWakes > 0 { text += L(" · woke \(record.darkWakes)× in between", " · 중간에 \(record.darkWakes)번 깸") }
        return text
    }

    private var battery: String {
        guard record.onBatteryBefore, record.onBatteryAfter == true else { return L("on power", "전원 연결") }
        guard let a = record.percentBefore, let b = record.percentAfter else { return "–" }
        return "\(a)→\(b)%"
    }

    static func when(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

private struct SessionRow: View {
    let session: LidSession

    var body: some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Texts.duration(session.duration))
                    .monospacedDigit()
                Text(SleepRow.when(session.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let t = session.maxTemperature { parts.append(L(String(format: "peak %.1f°C", t), String(format: "최고 %.1f°C", t))) }
        if let a = session.batteryStart, let b = session.batteryEnd, a != b { parts.append("\(a)→\(b)%") }
        if session.lowPower { parts.append(L("Low Power Mode", "저전력 모드")) }
        if session.onBattery { parts.append(L("battery", "배터리")) }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }
}

// MARK: Notifications

private struct NotificationsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle(L("A summary when the lid opens", "덮개를 열 때 세션 요약"), isOn: $model.sessionNotifications)
                Toggle(L("Sleep used a lot of battery", "잠자는 동안 배터리를 많이 썼을 때"), isOn: $model.notifySleepDrain)
                Toggle(L("A battery hold ended", "배터리 유지가 끝났을 때"), isOn: $model.notifyHoldEnd)
                Toggle(L("Critical heat for 3 minutes", "발열 위험이 3분 이어질 때"), isOn: $model.notifyHeat)
                Toggle(L("Turned on or off by a shortcut or URL", "단축키·URL로 켜고 끌 때"), isOn: $model.notifyToggle)
            } footer: {
                Note(L("Sleep use is reported above \(Int(SleepLog.highDrain))% an hour. A stopped helper is always reported.",
                       "잠자는 동안 사용량은 시간당 \(Int(SleepLog.highDrain))%를 넘으면 알려요. 도우미가 멈췄을 때는 항상 알려요."))
            }
            Section {
                LabeledContent(L("macOS notification settings", "macOS 알림 설정")) {
                    Button(L("Open…", "열기…")) { model.open(.notifications) }
                }
            }
        }
    }
}

// MARK: Shortcuts and automation

private struct ControlPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle(L("Global shortcuts", "전역 단축키 사용"), isOn: $model.hotkeysEnabled)
                ForEach(HotKeys.Action.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutField(action: action, model: model)
                    }
                    .disabled(!model.hotkeysEnabled)
                }
                HStack {
                    Spacer()
                    Button(L("Restore Default Shortcuts", "기본 단축키로 되돌리기")) { model.resetCombos() }
                        .disabled(model.hotkeyCombos.isEmpty)
                }
            } header: {
                Text(L("Shortcuts", "단축키"))
            } footer: {
                Note(L("Click “Change” and press the new combination; it needs ⌘, ⌥ or ⌃, and esc cancels. They work in any app and need no Accessibility permission.",
                       "'변경'을 누르고 새 조합을 누르세요. ⌘, ⌥, ⌃ 중 하나는 들어가야 하고, esc를 누르면 취소돼요. 어느 앱에서든 동작하며 손쉬운 사용 권한이 필요 없어요."))
            }

            Section {
                Toggle(L("Install the tether command", "터미널 명령 설치"),
                       isOn: Binding(get: { model.cliInstalled }, set: { model.setCLIInstalled($0) }))
                if let location = model.cliLocation {
                    LabeledContent(L("Location", "위치")) {
                        Text(location.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                CommandRows(rows: [
                    ("tether status", L("current state · --json", "지금 상태 · --json")),
                    ("tether on | off | toggle", L("turn on · off · flip", "켜기 · 끄기 · 전환")),
                    ("tether sleep", L("sleep now", "지금 잠자기")),
                    ("tether hold 1h30m", L("stay awake on battery · hold off", "배터리에서도 유지 · hold off")),
                    ("tether run -- <cmd>", L("stay awake until the command finishes", "명령이 끝날 때까지 유지")),
                    ("tether blank", L("screen off without locking", "잠금 없이 화면 끄기")),
                ])
            } header: {
                Text(L("Terminal", "터미널"))
            } footer: {
                Note(L("It links into ~/.local/bin when that folder exists, otherwise /usr/local/bin (asks for your password). Scripts and agents can use it too; it waits up to 3 seconds for the helper to apply a change.",
                       "~/.local/bin이 있으면 그곳에, 없으면 /usr/local/bin에 연결해요(관리자 암호 필요). 스크립트나 에이전트에서도 쓸 수 있고, 도우미가 적용할 때까지 최대 3초 기다려요."))
            }

            Section {
                CommandRows(rows: [
                    ("tether://sleep", L("sleep now", "지금 잠자기")),
                    ("tether://blank", L("screen off", "화면 끄기")),
                    ("tether://toggle", L("flip on/off (also on, off)", "켜기 · 끄기 전환 (on, off)")),
                    ("tether://hold/90m", L("battery hold · hold/off", "배터리 유지 · hold/off")),
                ])
            } header: {
                Text(L("URLs · Shortcuts App", "URL · 단축어"))
            } footer: {
                Note(L("Use them with the Shortcuts app's “Open URL” action. Opening one from a browser asks first.",
                       "단축어 앱의 'URL 열기' 동작에 넣으면 돼요. 브라우저에서 이런 링크를 열면 macOS가 먼저 물어봐요."))
            }
        }
    }
}

/// Shows a shortcut; "Change" records the next key combination pressed in this window.
private struct ShortcutField: View {
    let action: HotKeys.Action
    @ObservedObject var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                Text(problem ?? L("Press the new shortcut", "새 단축키를 누르세요"))
                    .font(.callout)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            } else {
                if model.hotkeysEnabled, model.hotkeysUnavailable.contains(action) {
                    Text(L("in use by another app", "다른 앱이 사용 중"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                KeyCap(model.combo(for: action).display)
            }
            Button(recording ? L("Cancel", "취소") : L("Change", "변경")) { recording ? stop() : start() }
                .controlSize(.small)
        }
        .onDisappear { stop() }
    }

    private func start() {
        problem = nil
        recording = true
        model.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 0x35 {  // esc
            stop()
            return
        }
        let combo = KeyCombo(event: event)
        guard combo.isValid else {
            problem = L("Include ⌘, ⌥ or ⌃", "⌘, ⌥, ⌃ 중 하나와 함께 눌러 주세요")
            NSSound.beep()
            return
        }
        guard model.setCombo(combo, for: action) else {
            problem = L("Another action uses it", "다른 동작이 이미 쓰고 있어요")
            NSSound.beep()
            return
        }
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        model.suspendHotkeys(false)
    }
}

// MARK: System

private struct SystemPage: View {
    @ObservedObject var model: AppModel
    @State private var lowPower: (battery: Int?, ac: Int?) = (nil, nil)
    @State private var blockers: [SleepBlocker] = []
    @State private var confirmingRemoval = false

    var body: some View {
        Page {
            Section {
                LabeledContent(L("Status", "상태")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.helperStatus.color)
                            .frame(width: 8, height: 8)
                        Text(model.helperStatus.text)
                    }
                }
                HStack {
                    if model.helperInstalled {
                        Button(L("Reinstall…", "다시 설치…")) { model.installHelper() }
                        Button(L("Remove…", "제거…"), role: .destructive) { model.uninstallHelper() }
                    } else {
                        Button(L("Install…", "설치…")) { model.installHelper() }
                    }
                    Spacer()
                    Button(L("Show Log", "기록 보기")) { model.openLog() }
                }
            } header: {
                Text(L("Helper", "도우미"))
            } footer: {
                Note(L("The helper runs with administrator rights and keeps the power rules even while the app is closed. Remove it here so “prevent sleep” is turned back off.",
                       "도우미는 관리자 권한으로 돌며, 앱이 꺼져 있어도 전원 규칙을 지켜요. 지울 때는 여기서 제거해야 잠자기 금지가 풀려요."))
            }

            Section {
                LabeledContent(L("Prevent sleep", "잠자기 금지")) {
                    Text(model.snapshot.sleepDisabled ? L("on", "켜짐") : L("off", "꺼짐"))
                }
                LabeledContent(L("Low Power Mode", "저전력 모드")) {
                    HStack(spacing: 8) {
                        Text(lowPowerText)
                        Button(L("Battery Settings…", "배터리 설정…")) { model.open(.battery) }
                    }
                }
                LabeledContent(L("Keep-screen-on request", "화면 켜 둠 요청")) {
                    Text(model.holdsDisplayAwake ? L("active", "사용 중") : L("inactive", "사용 안 함"))
                }
                LabeledContent(L("Background items (2)", "백그라운드 항목 2개")) {
                    Button(L("Open Login Items…", "로그인 항목 열기…")) { model.open(.loginItems) }
                }
            } header: {
                Text(L("What Tether Changes", "Tether가 바꾸는 시스템 설정"))
            } footer: {
                Note(L("“Prevent sleep” is a hidden setting, on only while power is connected, and not shown in System Settings. Low Power Mode is switched on only during the heat guard or a battery hold, then restored. The keep-screen-on request shows in Activity Monitor › Energy. Sleep and display timers, the lock password, the screen saver and input sources are never changed.",
                       "잠자기 금지는 전원이 연결돼 있을 때만 켜는 숨은 값이라 설정 앱에는 없어요. 저전력 모드는 발열 보호나 배터리 유지 중에만 잠깐 켜고 원래 값으로 돌려요. 화면 켜 둠 요청은 활동 모니터 › 에너지에 보여요. 잠자기·화면 끄기 타이머, 잠금 암호, 화면 보호기, 입력 소스는 바꾸지 않아요."))
            }

            Section {
                if blockers.isEmpty {
                    Text(L("No other app is keeping the Mac awake.", "지금 잠을 막는 다른 앱이 없어요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blockers.enumerated()), id: \.offset) { _, b in
                        LabeledContent {
                            Text(b.reason.isEmpty ? Texts.blockerKind(b.kind) : "\(b.reason) · \(Texts.blockerKind(b.kind))")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(b.process)
                        }
                    }
                }
            } header: {
                Text(L("Apps Keeping the Mac Awake", "잠을 막는 앱"))
            } footer: {
                Note(L("Apps can hold off idle sleep, on battery too; that's what an AI app's “prevent sleep” setting does. Closing the lid and Tether's own sleep still win, but with the lid open on battery the Mac stays awake and drains.",
                       "앱은 배터리일 때도 '입력이 없어 잠드는 것'을 막을 수 있어요. AI 앱의 '절전 방지' 설정이 이런 방식이에요. 덮개를 닫거나 Tether가 재우는 것은 막지 못하지만, 배터리로 덮개를 열어 둔 채 두면 Mac이 깨어 있어 배터리가 닳아요."))
            }

            Section {
                LabeledContent(L("Version", "버전")) {
                    Text("v\(AppModel.appVersion)")
                }
                Toggle(L("Check for updates automatically", "업데이트 자동 확인"), isOn: $model.checkUpdates)
                HStack {
                    if let update = model.availableUpdate {
                        Label(L("Tether \(update) is available", "Tether \(update)이(가) 나왔어요"), systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.tetherMint)
                        Spacer()
                        Button(L("Download…", "받기…")) { model.openReleases() }
                    } else {
                        Button(L("Check Now", "지금 확인")) { model.checkForUpdates(force: true) }
                        Spacer()
                        Button(L("GitHub…", "GitHub…")) { NSWorkspace.shared.open(AppModel.projectURL) }
                    }
                }
            } header: {
                Text(L("Updates", "업데이트"))
            } footer: {
                Note(L("Once a day Tether asks GitHub for the latest release; nothing else is sent.",
                       "하루에 한 번 GitHub에 최신 릴리스만 물어봐요. 다른 정보는 보내지 않아요."))
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("Uninstall Tether…", "Tether 완전히 제거…"), role: .destructive) { confirmingRemoval = true }
                }
            } footer: {
                Note(L("Removes the helper (turning “prevent sleep” back off), its files and logs, the login item, the tether command and preferences, then moves the app to the Trash.",
                       "도우미(잠자기 금지 해제 포함), 설정·기록 파일, 로그인 항목, tether 명령, 환경설정을 지우고 앱을 휴지통으로 옮겨요."))
            }
        }
        .confirmationDialog(L("Uninstall Tether completely?", "Tether를 완전히 제거할까요?"), isPresented: $confirmingRemoval) {
            Button(L("Uninstall", "제거"), role: .destructive) { model.uninstallEverything() }
            Button(L("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(L("Your administrator password is needed once. Your Mac goes back to normal sleep.",
                   "관리자 암호를 한 번 입력해야 해요. Mac은 원래의 잠자기 동작으로 돌아가요."))
        }
        .task {
            // Only while this page is visible.
            while !Task.isCancelled {
                lowPower = SystemProbe.lowPowerModes()
                blockers = model.sleepBlockers()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var lowPowerText: String {
        func text(_ value: Int?) -> String { value.map { $0 == 1 ? L("on", "켜짐") : L("off", "꺼짐") } ?? "–" }
        var line = L("battery \(text(lowPower.battery)) · power \(text(lowPower.ac))", "배터리 \(text(lowPower.battery)) · 전원 \(text(lowPower.ac))")
        if model.heatGuardActive {
            line += L(" (heat guard)", " (발열 보호)")
        } else if model.holdingOnBattery {
            line += L(" (battery hold)", " (배터리 유지)")
        }
        return line
    }
}
