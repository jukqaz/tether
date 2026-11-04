import Foundation
import UserNotifications
import TetherCore

/// No permission prompt or replay. Tokens are checked against current policy again
/// when an old OS notification action is delivered.
@MainActor
final class V4NotificationDelivery: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private var permittedSubmissions: Set<String> = []
    private var action: ((V4ExpiryNoticeToken, V4ExpiryNoticeAction) -> Void)?
    var submitOverride: ((V4ExpiryNoticeToken, Bool) -> Void)?
    var removeOverride: (([String]) -> Void)?
    func activate(action: @escaping (V4ExpiryNoticeToken, V4ExpiryNoticeAction) -> Void) {
        self.action = action
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let check = UNNotificationAction(identifier: "check", title: L("Check deadline", "기한 확인"), options: [.foreground])
        let extend = UNNotificationAction(identifier: "extend15", title: "+15 " + L("min", "분"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "tether-expiry", actions: [check], intentIdentifiers: []),
            UNNotificationCategory(identifier: "tether-expiry-extend", actions: [extend, check], intentIdentifiers: [])
        ])
    }
    func submit(_ token: V4ExpiryNoticeToken, automaticContinues: Bool, sound: Bool = false) {
        let id = identifier(token)
        permittedSubmissions.insert(id)
        if let submitOverride { submitOverride(token, automaticContinues); return }
        let content = UNMutableNotificationContent()
        let minutes = token.warningMinutes ?? 5
        content.title = L("Manual keep-awake ends in \(minutes) minutes", "수동 유지가 \(minutes)분 뒤 끝납니다")
        if sound { content.sound = .default }
        content.body = automaticContinues ? L("AC automatic keep-awake remains active. Check the current deadline before extending.", "AC 자동 유지는 계속됩니다. 연장 전에 현재 기한을 확인하세요.") : L("Check the current deadline or explicitly extend the session.", "현재 기한을 확인하거나 직접 연장할 수 있습니다.")
        content.categoryIdentifier = token.mayExtend15 ? "tether-expiry-extend" : "tether-expiry"
        guard let data = try? JSONEncoder().encode(token), let value = String(data: data, encoding: .utf8) else { return }
        content.userInfo = ["tetherToken": value]
        Task {
            guard await AppNotificationSettings.current().access == .allowed,
                  permittedSubmissions.contains(id), ContinuousTime.now < token.deadline else { return }
            do {
                let center = UNUserNotificationCenter.current()
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                if !permittedSubmissions.contains(id) {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                }
            }
            catch { appLog.error("Expiry notification submission failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
    func remove(_ tokens: [V4ExpiryNoticeToken]) {
        let ids = tokens.map(identifier)
        for id in ids { permittedSubmissions.remove(id) }
        guard !ids.isEmpty else { return }
        if let removeOverride { removeOverride(ids); return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    private func identifier(_ token: V4ExpiryNoticeToken) -> String { "tether-expiry-\(token.requestID)-\(token.revisionID)" }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["tetherToken"] as? String,
              value.utf8.count < 8192, let data = value.data(using: .utf8),
              let token = try? JSONDecoder().decode(V4ExpiryNoticeToken.self, from: data) else { return }
        action?(token, response.actionIdentifier == "extend15" ? .extend15 : .checkDeadline)
    }
}
