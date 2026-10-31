import AgentMuxCore
import AppKit
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
        content.sound = NotificationSound.forKind(item.kind)
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

/// The two notification sounds, set in Settings: one for an agent that needs
/// you (it also stopped on an error or a limit), one for a finished turn.
/// The choices are the Mac's alert sounds, copied into the app's bundle.
enum NotificationSound {
    static let needsYouKey = "needsYouSound"
    static let doneKey = "doneSound"
    static let needsYouDefault = "Ping"
    static let doneDefault = "Glass"

    /// The bundled sounds by name, sorted.
    static var names: [String] {
        (Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// The chosen sound's name for `kind`; "" is none.
    static func name(for kind: InboxItem.Kind) -> String {
        let finished = kind == .finished
        let key = finished ? doneKey : needsYouKey
        return UserDefaults.standard.string(forKey: key) ?? (finished ? doneDefault : needsYouDefault)
    }

    static func forKind(_ kind: InboxItem.Kind) -> UNNotificationSound? {
        let name = name(for: kind)
        if name.isEmpty { return nil }
        guard Bundle.main.url(forResource: name, withExtension: "caf") != nil else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName("\(name).caf"))
    }

    /// Plays `name` once, as when it is picked in Settings.
    @MainActor static func preview(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }
}
