import AppKit
import SwiftUI
import TetherCore

/// Tests may exercise the shipping Scenes only in a separate, explicitly marked bundle.
/// An environment variable alone can never select this path in an installed Tether app.
enum NativeUIAutomation {
    static let bundleID = "io.github.jukqaz.tether.ui-tests"
    static func isPrivateBundleID(_ value: String?) -> Bool {
        guard let value else { return false }
        if value == bundleID { return true }
        let prefix = bundleID + "."
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        return suffix.count == 32 && suffix.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func isRequested(bundleID: String?, fixture: Bool?, environment: [String: String]) -> Bool {
        isPrivateBundleID(bundleID) && fixture == true && environment["TETHER_UI_TESTING"] == "1"
    }
    static var currentBundleIsFixture: Bool {
        isRequested(bundleID: Bundle.main.bundleIdentifier,
            fixture: Bundle.main.object(forInfoDictionaryKey: "TetherUIAutomationFixture") as? Bool,
            environment: ProcessInfo.processInfo.environment)
    }

    static func allowsInMemoryRecording(bundleID: String?, fixture: Bool?, environment: [String: String],
                                        hasFixtureSession: Bool) -> Bool {
        hasFixtureSession && bundleID != self.bundleID
            && isRequested(bundleID: bundleID, fixture: fixture, environment: environment)
    }

    /// Only this fixture's exact memory-only controller receives the recording
    /// exception. A render-only preview with any other controller stays blocked.
    @MainActor
    static func isInMemoryRecordingSession(_ controller: UserSessionController?) -> Bool {
        guard currentBundleIsFixture, let controller else { return false }
        return allowsInMemoryRecording(bundleID: Bundle.main.bundleIdentifier,
            fixture: Bundle.main.object(forInfoDictionaryKey: "TetherUIAutomationFixture") as? Bool,
            environment: ProcessInfo.processInfo.environment,
            hasFixtureSession: controller === NativeUITestFixture.shared.controller)
    }
}

/// Refreshes only supplied fixture facts. One common-mode timer remains active
/// while a native menu is tracking; no system observer or assertion is created.
@MainActor
final class NativeUITestObservationPump {
    static let interval: TimeInterval = 1
    private weak var controller: UserSessionController?
    private let power: PowerSource
    private let thermal: Int
    private let batteryPercent: Int?
    private let clock: () -> Double
    private var timer: Timer?
    private(set) var lastObservedAt: Double?

    init(controller: UserSessionController, power: PowerSource, thermal: Int,
         batteryPercent: Int?, clock: @escaping () -> Double = { ContinuousTime.now }) {
        self.controller = controller
        self.power = power
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.clock = clock
    }

    func refresh() {
        let now = clock()
        guard let controller, now.isFinite, now >= 0,
              lastObservedAt.map({ now >= $0 }) ?? true else { return }
        controller.update(power: power, thermal: thermal, fullWake: true,
            controllingUser: true, now: now, batteryPercent: batteryPercent)
        lastObservedAt = now
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refresh()
            }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct NativeUIAutomationApp: App {
    @NSApplicationDelegateAdaptor(NativeUITestDelegate.self) private var delegate
    @StateObject private var model = NativeUITestFixture.shared.model

    var body: some Scene {
        WindowGroup("Tether UI Test", id: "ui-fixture") {
            NativeUITestLanding(model: model)
        }
        .defaultSize(width: 480, height: 180)
        .defaultLaunchBehavior(.presented)
        .commands {
            // AX inspection eagerly populates other apps' Services/Data Detectors.
            // Keep that unrelated OS integration outside this isolated UI fixture.
            // The shipping app retains its normal Services menu.
            CommandGroup(replacing: .systemServices) {}
        }
        TetherScenes(model: model)
    }
}

/// No preference files, native assertions, root transport or real observation is started.
@MainActor
private final class NativeUITestFixture {
    static let shared = NativeUITestFixture()
    let model: AppModel
    let controller: UserSessionController
    let observationPump: NativeUITestObservationPump

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["TETHER_UI_TEST_SCENARIO"] ?? "ac"
        let portable = scenario != "desktop" && scenario != "desktopBatteryCondition"
        let power: PowerSource = scenario == "battery" ? .battery : .ac
        let defaults = NativeUITestDefaults()
        if scenario == "desktopBatteryCondition" {
            var settings = IdleSessionSettings()
            settings.version = 6
            settings.automaticEnabled = true
            settings.powerCondition = .battery
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: UserSessionController.preferenceKey)
            }
        }
        controller = UserSessionController(defaults: defaults, backend: NativeUITestAssertion(),
            displayBackend: NativeUITestAssertion(),
            guiProbe: nil, environmentProbe: nil, boot: "native-ui-fixture")
        let pump = NativeUITestObservationPump(controller: controller, power: power,
            thermal: scenario == "protection" ? 2 : 0, batteryPercent: portable ? 80 : nil)
        observationPump = pump
        pump.refresh()
        model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: portable, lid: portable),
            previewSession: controller, previewDefaults: defaults)
        model.language = environment["TETHER_UI_TEST_LANGUAGE"] == "en" ? .english : .korean
        if scenario != "desktopBatteryCondition" { model.setAutomaticEnabled(true) }
        model.selectManualDuration(1800)
        if scenario == "lidSetup" { model.setAllowClosedLid(true) }
        if scenario == "longError" {
            model.errorText = L("The simulated connection could not be confirmed. Review the connection and try again without changing another application's requests.",
                "모의 연결 상태를 확인하지 못했습니다. 연결 상태를 확인한 후 다시 시도하세요. 다른 앱의 작업 유지 요청은 변경하지 않습니다.")
        }
        if scenario == "overflowError" {
            model.errorText = L(
                "The connection could not be confirmed. Keep the existing power settings while reviewing the helper response. The diagnostic details describe an unavailable connection, not a reason to change another application's requests. " +
                "Review the connection in App settings, then try again. No other application's requests were changed. Recovery step: review the helper before restarting work.",
                "연결 상태를 확인하지 못했습니다. 도우미 응답을 확인하는 동안 기존 전원 설정을 유지하세요. 이 진단은 연결 응답이 없는 상태를 설명하며 다른 앱의 작업 유지 요청을 바꿀 이유가 아닙니다. " +
                "앱 설정에서 연결 상태를 확인한 뒤 다시 시도하세요. 다른 앱의 요청은 변경하지 않았습니다. 복구 순서: 도우미 상태를 확인한 뒤 작업을 다시 시작하세요.")
        }
        pump.start()
    }
}

private struct NativeUITestLanding: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native UI automation · simulated power only").font(.headline)
            Button("Open settings") { NSApp.activate(); openSettings() }
                .accessibilityIdentifier("ui-fixture-open-settings")
            Button("Open welcome") { WelcomeWindow.show(model: model) }
                .accessibilityIdentifier("ui-fixture-open-welcome")
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                // Window geometry changes independently of the simulated power model.
                // Refresh only this fixture's observation; never resize or raise a window.
                Text(state).font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(state)
                    .accessibilityIdentifier("ui-fixture-state")
            }
        }
        .padding(20)
    }

    private var state: String {
        let value: [String: Any] = ["automatic": model.v3Settings.automaticEnabled,
            "automaticActive": model.automaticWorkReasonActive,
            "automaticPauseActive": model.automaticPauseActive,
            "menuBarDetails": model.menuBarDetails,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "executablePath": Bundle.main.executableURL?.path ?? "unknown",
            "manual": model.manualSessionActive, "holding": model.workSessionHolding,
            "manualRequestID": model.userSessionStatus?.manualRequestID.map { $0.uuidString as Any } ?? NSNull(),
            "manualContinuousDeadline": model.userSessionStatus?.manualContinuousDeadline.map { $0 as Any } ?? NSNull(),
            "keepDisplayAwake": model.v3Settings.keepDisplayAwake,
            "displayHolding": model.userSessionStatus?.displayHolding ?? false,
            "paused": model.workPaused, "power": model.snapshot.power.rawValue,
            "powerCondition": model.v3Settings.condition.rawValue,
            "selectedManualMinutes": model.selectedManualMinutes,
            "controllerBound": model.usesUserSession,
            "canStartManual": model.canStartManualSession,
            "manualApprovalPending": model.v4ManualApprovalPending,
            "error": model.errorText.map { $0 as Any } ?? NSNull(),
            "sessionError": (model.userSessionStatus?.error).map { $0 as Any } ?? NSNull(),
            "blockReason": (model.userSessionStatus?.blockReason).map { $0 as Any } ?? NSNull(),
            "fixtureObservedAt": NativeUITestFixture.shared.observationPump.lastObservedAt.map { $0 as Any } ?? NSNull(),
            "recordingActive": model.diagnosticRecordingActive,
            "recordingUntil": model.diagnosticRecordingUntil.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "thermal": model.userSessionStatus?.thermal ?? 0,
            "observedAt": Date().timeIntervalSince1970,
            "application": NativeUITestWindowObservation.application,
            "settingsWindow": NativeUITestWindowObservation.settingsWindow,
            "activityReviewSheet": NativeUITestWindowObservation.activityReviewSheet,
            "welcomeWindow": NativeUITestWindowObservation.welcomeWindow]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }
}

/// Read-only native geometry for the isolated fixture. The Settings identifier selects
/// the actual shared Scene window instead of the fixture's separate landing window.
@MainActor
private enum NativeUITestWindowObservation {
    static var application: [String: Any] {
        ["active": NSApp.isActive,
         "effectiveAppearance": NSApp.effectiveAppearance.name.rawValue,
         "keyWindowNumber": NSApp.keyWindow.map { $0.windowNumber as Any } ?? NSNull(),
         "mainWindowNumber": NSApp.mainWindow.map { $0.windowNumber as Any } ?? NSNull()]
    }

    static var settingsWindow: Any {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }) else { return NSNull() }
        return metadata(window)
    }

    static var activityReviewSheet: Any {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }), let sheet = window.attachedSheet else { return NSNull() }
        return metadata(sheet)
    }

    static var welcomeWindow: Any {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "tether-welcome-window"
        }) else { return NSNull() }
        return metadata(window)
    }

    private static func metadata(_ window: NSWindow) -> [String: Any] {
        return ["windowNumber": window.windowNumber,
                "identifier": window.identifier?.rawValue ?? "",
                "class": String(describing: type(of: window)),
                "title": window.title,
                "visible": window.isVisible,
                "key": window.isKeyWindow,
                "main": window.isMainWindow,
                "firstResponderIsWindow": window.firstResponder === window,
                "firstResponderClass": window.firstResponder.map {
                    String(describing: type(of: $0))
                } ?? "none",
                "firstResponderIdentity": window.firstResponder.map {
                    String(describing: ObjectIdentifier($0))
                } ?? "none",
                "miniaturized": window.isMiniaturized,
                "inLiveResize": window.inLiveResize,
                "frame": rect(window.frame),
                "contentRect": rect(window.contentRect(forFrameRect: window.frame)),
                "contentLayoutRect": rect(window.contentLayoutRect),
                "contentViewBounds": window.contentView.map { rect($0.bounds) as Any } ?? NSNull(),
                "minSize": size(window.minSize),
                "contentMinSize": size(window.contentMinSize),
                "maxSize": size(window.maxSize),
                "contentMaxSize": size(window.contentMaxSize),
                "resizeIncrements": size(window.resizeIncrements),
                "contentResizeIncrements": size(window.contentResizeIncrements),
                "aspectRatio": size(window.aspectRatio),
                "contentAspectRatio": size(window.contentAspectRatio),
                "styleMask": window.styleMask.rawValue,
                "isResizable": window.styleMask.contains(.resizable)] as [String: Any]
    }

    private static func rect(_ value: NSRect) -> [String: Double] {
        ["x": Double(value.origin.x), "y": Double(value.origin.y),
         "width": Double(value.size.width), "height": Double(value.size.height)]
    }

    private static func size(_ value: NSSize) -> [String: Double] {
        ["width": Double(value.width), "height": Double(value.height)]
    }
}

private final class NativeUITestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        switch ProcessInfo.processInfo.environment["TETHER_UI_TEST_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            let fixture = NativeUITestFixture.shared
            fixture.observationPump.stop()
            _ = fixture.controller.end()
        }
    }
}

private final class NativeUITestAssertion: IdleAssertionBackend {
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { (0, 31) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { 0 }
}

private final class NativeUITestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
    override func removePersistentDomain(forName name: String) { values.removeAll() }
}
