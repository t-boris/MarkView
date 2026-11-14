import AppKit
import UserNotifications

extension Notification.Name {
    /// A Cockpit notification was clicked. userInfo: "cockpitRoot" (the project path) and "cockpitRunID".
    static let cockpitNoticeOpened = Notification.Name("MarkViewCockpitNoticeOpened")
}

/// Tells the person, with a macOS notification, what a long run needs from them. What is said and when is decided by
/// `CockpitNotice` (a pure value with its own checks); this only delivers it, once per moment.
@MainActor
final class CockpitNotifier {
    private var sent: Set<String> = []
    private var authorizationRequested = false

    /// Asked when a run starts, so the person is not surprised by the prompt later in the middle of other work.
    func requestAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(_ notice: CockpitNotice, root: URL, runID: UUID) {
        guard sent.insert(notice.key).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = root.lastPathComponent
        content.body = notice.body
        content.userInfo = ["cockpitRoot": root.path, "cockpitRunID": runID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cockpit-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
