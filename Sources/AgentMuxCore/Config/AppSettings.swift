import Foundation

/// Everything the app needs to run, managed entirely in the Settings window and
/// written by the app itself — there is no hand-edited config file. Holds the
/// ssh hosts and which discovered containers to monitor; containers found on a
/// host are listed live by `docker ps` rather than stored here.
public struct AppSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var hosts: [HostConfig]
    /// Monitored containers as "<hostId>/<container>" keys.
    public var monitoredContainers: [String]

    public static let currentSchema = 2

    public init(hosts: [HostConfig] = [], monitoredContainers: [String] = []) {
        schemaVersion = Self.currentSchema
        self.hosts = hosts
        self.monitoredContainers = monitoredContainers
    }

    /// Splits a monitored key "<hostId>/<container>" into its parts. The host id
    /// has no slash; the container is the remainder.
    public static func splitKey(_ key: String) -> (hostID: String, container: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let container = String(key[key.index(after: slash)...])
        guard !container.isEmpty else { return nil }
        return (String(key[..<slash]), container)
    }

    /// AGENTMUX_SETTINGS, else ~/Library/Application Support/AgentMux/settings.json.
    public static func defaultURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["AGENTMUX_SETTINGS"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMux/settings.json")
    }

    /// Legacy hand-edited file, imported once if `settings.json` is absent.
    public static func legacyConfigURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["AGENTMUX_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMux/targets.json5")
    }

    public static func load(from url: URL) throws -> AppSettings {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        var settings = try decoder.decode(AppSettings.self, from: Data(contentsOf: url))
        settings.normalize()
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Loads `settings.json`; if it is missing, imports the legacy config once
    /// (so an existing setup carries over) and returns that. A missing legacy
    /// file yields empty settings. Never throws on absence.
    public static func loadOrImport(
        url: URL = AppSettings.defaultURL(),
        legacy: URL = AppSettings.legacyConfigURL()
    ) -> AppSettings {
        if let settings = try? load(from: url) { return settings }
        if let imported = try? importLegacy(from: legacy) {
            try? imported.save(to: url)
            return imported
        }
        return AppSettings()
    }

    /// Builds settings from a legacy `TargetsConfig`: its hosts, and its docker
    /// targets as monitored containers.
    public static func importLegacy(from url: URL) throws -> AppSettings {
        let config = try TargetsConfig.load(from: url)
        var monitored: [String] = []
        var seen = Set<String>()
        for target in config.targets where target.kind == .docker {
            guard let container = target.container, !container.isEmpty else { continue }
            let key = "\(target.hostId)/\(container)"
            if seen.insert(key).inserted { monitored.append(key) }
        }
        var settings = AppSettings(hosts: config.hosts, monitoredContainers: monitored)
        settings.normalize()
        return settings
    }

    /// Drops duplicates and monitored keys whose host is gone.
    public mutating func normalize() {
        var seenHosts = Set<String>()
        hosts = hosts.filter { seenHosts.insert($0.id).inserted }
        let hostIDs = Set(hosts.map(\.id))
        var seenKeys = Set<String>()
        monitoredContainers = monitoredContainers.filter { key in
            guard let parts = Self.splitKey(key), hostIDs.contains(parts.hostID) else { return false }
            return seenKeys.insert(key).inserted
        }
    }
}
