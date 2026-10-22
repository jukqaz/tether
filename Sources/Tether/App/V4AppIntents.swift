import AppIntents

/// App Intents route into the running app's owner and await the same bounded approval as the menu.
/// This executable declares no WidgetKit/Control extension or independent power executor.
enum V4IntentAction: String, AppEnum {
    case endManual, pauseAll, automaticOn, automaticOff, status
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tether action"
    static let caseDisplayRepresentations: [V4IntentAction: DisplayRepresentation] = [
        .endManual: "End manual only", .pauseAll: "Pause all", .automaticOn: "AC automatic on",
        .automaticOff: "AC automatic off", .status: "Check status"
    ]
    var action: V4AutomationAction {
        switch self {
        case .endManual: .endManual
        case .pauseAll: .pauseAll
        case .automaticOn: .automaticOn
        case .automaticOff: .automaticOff
        case .status: .status
        }
    }
}

enum V4IntentDuration: Int, AppEnum {
    case five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60, oneTwenty = 120, unlimited = 0
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Manual duration"
    static let caseDisplayRepresentations: [V4IntentDuration: DisplayRepresentation] = [
        .five: "5 minutes", .ten: "10 minutes", .fifteen: "15 minutes", .thirty: "30 minutes",
        .sixty: "60 minutes", .oneTwenty: "120 minutes", .unlimited: "Unlimited · AC only"
    ]
}

private struct V4IntentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TetherStartManualIntent: AppIntent {
    static let title: LocalizedStringResource = "Start manual work in Tether"
    static let description = IntentDescription("Starts a new manual request after current power, protection and helper checks. Does not replace existing work.")
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Duration", default: .thirty) var duration: V4IntentDuration

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await AppModel.shared.performV4Automation(.startManual,
            minutes: duration == .unlimited ? nil : duration.rawValue, useSavedDuration: false)
        guard reply.succeeded else { throw V4IntentFailure(message: reply.message) }
        return .result(value: reply.message, dialog: IntentDialog(stringLiteral: reply.message))
    }
}

struct TetherControlWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Tether work"
    static let description = IntentDescription("End manual work, pause all, change AC automatic or read status using Tether's current owner. Does not resume paused or ended work.")
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Action", default: .status) var action: V4IntentAction
    init() {}
    init(action: V4IntentAction) { self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await AppModel.shared.performV4Automation(action.action)
        guard reply.succeeded else { throw V4IntentFailure(message: reply.message) }
        return .result(value: reply.message, dialog: IntentDialog(stringLiteral: reply.message))
    }
}

struct TetherAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TetherStartManualIntent(), phrases: ["Start manual work in \(.applicationName)"],
                    shortTitle: "Start manual work", systemImageName: "timer")
        AppShortcut(intent: TetherControlWorkIntent(action: .endManual), phrases: ["End manual work in \(.applicationName)"],
                    shortTitle: "End manual only", systemImageName: "stop")
        AppShortcut(intent: TetherControlWorkIntent(action: .pauseAll), phrases: ["Pause all work in \(.applicationName)"],
                    shortTitle: "Pause all", systemImageName: "pause")
        AppShortcut(intent: TetherControlWorkIntent(action: .status), phrases: ["Check \(.applicationName) status"],
                    shortTitle: "Check status", systemImageName: "info.circle")
    }
}
