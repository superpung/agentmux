import AgentMuxCore
import Foundation
import UserNotifications

/// Posts the OS banner for an inbox item (the inbox keeps every item; a
/// banner is only for ones the user is not already looking at). Clicking the
/// banner opens the agent: the request carries the item's id.
@MainActor
final class Notifier {
    nonisolated static let inboxIDKey = "inboxID"

    private var requested = false
    /// UNUserNotificationCenter needs a real app bundle; running the raw binary
    /// (dev smoke tests) has none, so skip rather than crash.
    private let available = Bundle.main.bundleIdentifier != nil

    /// Ask once, lazily, so the prompt appears the first time a notification
    /// would actually fire rather than at launch.
    func requestAuthorizationIfNeeded() {
        guard available, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ item: InboxItem) {
        guard available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = item.kind.bannerTitle
        content.body = [item.agent, item.detail, item.place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.sound = .default
        content.userInfo = [Self.inboxIDKey: item.id.uuidString]
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Takes the banners of items that were read or deleted in the app out of
    /// Notification Center.
    func withdraw(_ ids: [UUID]) {
        guard available, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map(\.uuidString))
    }
}

extension InboxItem.Kind {
    var bannerTitle: String {
        switch self {
        case .finished: "Agent finished"
        case .needsInput: "Agent needs you"
        case .usageLimit: "Usage limit reached"
        case .error: "Agent stopped on an error"
        case .autoContinued: "Agent continued after an error"
        case .gaveUp: "Auto-continue stopped"
        }
    }
}
