import AgentMuxCore
import Foundation

/// When each agent's activity last changed, kept across launches so a
/// restart does not lose how long an agent has been working.
struct SavedSince {
    struct Stamp: Codable, Equatable {
        var activity: String
        var at: Date
    }

    static let defaultsKey = "activitySince"

    private var stamps: [String: Stamp]

    static func load() -> SavedSince {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        return SavedSince(stamps: data.flatMap { try? JSONDecoder().decode([String: Stamp].self, from: $0) } ?? [:])
    }

    /// The saved stamp of `ref`, if it was saved while doing `activity`.
    func date(_ ref: PaneRef, _ activity: AgentActivity) -> Date? {
        stamps[Self.key(ref)].flatMap { $0.activity == activity.rawValue ? $0.at : nil }
    }

    /// Puts `new` in place of everything saved for `target`.
    mutating func replace(target: String, with new: [PaneRef: Stamp]) {
        var next = stamps.filter { !$0.key.hasPrefix(target + "\n") }
        for (ref, stamp) in new { next[Self.key(ref)] = stamp }
        guard next != stamps else { return }
        stamps = next
        if let data = try? JSONEncoder().encode(stamps) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func key(_ ref: PaneRef) -> String {
        "\(ref.targetID)\n\(ref.serverPID)\n\(ref.serverStart)\n\(ref.paneID)"
    }
}
