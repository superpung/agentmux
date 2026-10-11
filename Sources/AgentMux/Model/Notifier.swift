import AgentMuxCore
import Foundation
import UserNotifications

/// Posts OS notifications when an agent needs the user: it finished a turn
/// (working → idle) or started waiting for input/approval, and the user is not
/// currently viewing it. Mirrors Claude Desktop's "a session finished and you
/// aren't viewing it" behaviour.
@MainActor
final class Notifier {
    private var authorized = false
    private var requested = false
    /// UNUserNotificationCenter needs a real app bundle; running the raw binary
    /// (dev smoke tests) has none, so skip rather than crash.
    private let available = Bundle.main.bundleIdentifier != nil

    /// Ask once, lazily, so the prompt appears the first time a notification
    /// would actually fire rather than at launch.
    func requestAuthorizationIfNeeded() {
        guard available, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    enum Reason {
        case finished
        case needsAttention

        var title: String {
            switch self {
            case .finished: return "Agent finished"
            case .needsAttention: return "Agent needs you"
            }
        }
    }

    func notify(_ reason: Reason, agent: String, detail: String) {
        guard available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = reason.title
        content.body = detail.isEmpty ? agent : "\(agent) · \(detail)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
