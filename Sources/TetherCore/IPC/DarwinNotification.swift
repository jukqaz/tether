import Foundation

/// System-wide Darwin notifications, so a root daemon and a user app can nudge each other.
public final class DarwinNotification {
    private let handler: () -> Void

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    public init(observing name: String, handler: @escaping () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinNotification>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handler() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }
}
