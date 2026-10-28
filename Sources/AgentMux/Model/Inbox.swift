import AgentMuxCore
import AppKit
import Foundation
import Observation

/// One thing that happened to an agent: it finished, needs the user, hit a
/// usage limit, or stopped on an error.
struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case finished
        case needsInput
        case usageLimit
        case error
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var ref: PaneRef
    /// The agent's name and container at the time.
    var agent: String
    var place: String
    var detail: String?
    var isRead = false
}

/// Every notification, newest first, kept across launches (capped) with the
/// usual read state. The Dock icon carries the unread count.
@MainActor
@Observable
final class Inbox {
    static let capacity = 500

    private(set) var items: [InboxItem] = []
    @ObservationIgnored private let url: URL?

    var unreadCount: Int { items.lazy.filter { !$0.isRead }.count }

    /// inbox.json next to settings.json (so AGENTMUX_SETTINGS also moves it);
    /// nil keeps it in memory only.
    init(url: URL? = AppSettings.defaultURL().deletingLastPathComponent().appendingPathComponent("inbox.json")) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([InboxItem].self, from: data)) ?? []
        }
        refreshBadge()
    }

    func add(_ item: InboxItem) {
        items.insert(item, at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        changed()
    }

    func item(_ id: UUID) -> InboxItem? {
        items.first { $0.id == id }
    }

    func setRead(_ id: UUID, _ read: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isRead != read else { return }
        items[index].isRead = read
        changed()
    }

    func markAllRead() {
        guard items.contains(where: { !$0.isRead }) else { return }
        for index in items.indices { items[index].isRead = true }
        changed()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        changed()
    }

    func clearRead() {
        items.removeAll(where: \.isRead)
        changed()
    }

    func clearAll() {
        items.removeAll()
        changed()
    }

    private func changed() {
        save()
        refreshBadge()
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Also called once the app has finished launching: the model, and so
    /// this inbox, is created before NSApp exists.
    func refreshBadge() {
        let unread = unreadCount
        NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }
}
