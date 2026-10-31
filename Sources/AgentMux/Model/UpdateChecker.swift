import AgentMuxCore
import Foundation

/// Looks for a newer AgentMux in the release feed, a little after launch and
/// then once a day, and says so in a notification, once per version. Never
/// a window: clicking the notification opens the release page.
@MainActor
final class UpdateChecker {
    static let enabledKey = "checkForUpdates"
    static let notifiedKey = "updateNotifiedVersion"

    private let notifier: Notifier
    private var task: Task<Void, Never>?

    init(notifier: Notifier) {
        self.notifier = notifier
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// This build's version; nil when run outside an app bundle.
    static var current: ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(ReleaseVersion.init)
    }

    func start() {
        guard task == nil, Self.current != nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if Self.enabled { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// From the menu (`manual`), being up to date or failing to check is
    /// said too, and a version already announced is announced again.
    func check(manual: Bool) async {
        guard let current = Self.current else { return }
        let latest: ReleaseEntry?
        do {
            latest = try await Self.fetch(current)
        } catch {
            if manual { notifier.notifyAbout(title: "Couldn't check for updates", body: error.localizedDescription) }
            return
        }
        guard let latest, latest.version > current else {
            if manual { notifier.notifyAbout(title: "AgentMux is up to date", body: "Version \(current)") }
            return
        }
        guard manual || UserDefaults.standard.string(forKey: Self.notifiedKey) != latest.version.description else { return }
        UserDefaults.standard.set(latest.version.description, forKey: Self.notifiedKey)
        notifier.notifyUpdate(latest)
    }

    private static func fetch(_ current: ReleaseVersion) async throws -> ReleaseEntry? {
        var request = URLRequest(url: ReleaseFeed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("AgentMux/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return ReleaseFeed.latest(in: data)
    }
}
