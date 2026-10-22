import Foundation
import SwiftUI
import UserNotifications
import TetherCore

struct AppNotificationSettings: Equatable, Sendable {
    enum Access: Sendable { case notRequested, allowed, denied, unavailable }
    var access: Access
    var alerts: Bool
    var title: String {
        switch access {
        case .notRequested: L("Not yet allowed", "아직 허용하지 않음")
        case .allowed: alerts ? L("Allowed by macOS", "macOS에서 허용됨") : L("Alerts disabled in macOS", "macOS에서 알림 표시 꺼짐")
        case .denied: L("Disabled in macOS", "macOS에서 허용 안 됨")
        case .unavailable: L("Could not check", "확인할 수 없음")
        }
    }
    static func current() async -> Self {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let access: Access
        switch settings.authorizationStatus {
        case .notDetermined: access = .notRequested
        case .authorized, .provisional: access = .allowed
        case .denied: access = .denied
        default: access = .unavailable
        }
        return Self(access: access, alerts: settings.alertSetting == .enabled)
    }
}

/// Querying is read-only. Only the explicit Allow button asks macOS for permission.
@MainActor
final class NotificationSettingsMonitor: ObservableObject {
    @Published private(set) var value = AppNotificationSettings(access: .unavailable, alerts: false)
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let simulated: Bool
    private let query: () async -> AppNotificationSettings
    private let authorize: () async throws -> Void

    init(simulated: Bool = false, query: @escaping () async -> AppNotificationSettings = { await .current() },
         authorize: @escaping () async throws -> Void = {
             _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
         }) {
        self.simulated = simulated; self.query = query; self.authorize = authorize
        if simulated { value = AppNotificationSettings(access: .notRequested, alerts: false) }
    }
    func refresh() async {
        guard !simulated, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        value = await query()
    }
    func requestPermission() async {
        guard !simulated, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        // Always query again: System Settings may have changed since the last render.
        value = await query()
        guard value.access == .notRequested else { return }
        do { try await authorize() }
        catch { self.error = L("macOS could not complete the permission request. Check Notification settings.",
                               "macOS 알림 허용 요청을 완료하지 못했습니다. 알림 설정을 확인하세요.") }
        value = await query()
    }
    /// Event delivery does not request permission and never queues old events for later permission.
    static func deliver(title: String, body: String) {
        Task {
            let settings = await AppNotificationSettings.current()
            guard settings.access == .allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
