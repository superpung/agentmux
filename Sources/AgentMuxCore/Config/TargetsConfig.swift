import Foundation

/// The local development target file (`config/targets.local.json5`).
public struct TargetsConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var hosts: [HostConfig]
    public var targets: [TargetConfig]

    public static func load(from url: URL) throws -> TargetsConfig {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(TargetsConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func host(for target: TargetConfig) -> HostConfig? {
        hosts.first { $0.id == target.hostId }
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ConfigError.unsupportedSchema(schemaVersion)
        }
        for host in hosts {
            _ = try SSHDestination(host.sshDestination)
        }
        for target in targets {
            guard host(for: target) != nil else {
                throw ConfigError.unknownHost(target: target.id, host: target.hostId)
            }
            _ = try target.executionContext()
        }
    }
}

public enum ConfigError: Error, Equatable {
    case unsupportedSchema(Int)
    case unknownHost(target: String, host: String)
    case missingContainer(target: String)
}

/// A host AgentMux connects to over ssh. Managed in the app's Settings; the
/// ssh destination is an alias from `~/.ssh/config` or `user@host` (no secrets).
public struct HostConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var sshDestination: String

    public init(id: String, displayName: String, sshDestination: String) {
        self.id = id
        self.displayName = displayName
        self.sshDestination = sshDestination
    }

    // Older config files carried per-host discovery/access defaults; they are
    // ignored now (the app is interactive and discovers every host).
    private enum CodingKeys: String, CodingKey { case id, displayName, sshDestination }
}

public extension TargetConfig {
    /// A target for a container discovered on `host`, on the default tmux socket
    /// and the container's default user. Monitored containers are interactive.
    static func discovered(host: HostConfig, container: String) -> TargetConfig {
        TargetConfig(
            id: "\(host.id)/\(container)",
            displayName: nil,
            hostId: host.id,
            kind: .docker,
            container: container,
            execUser: nil,
            tmuxPath: nil,
            tmuxSocket: .init(mode: .default, value: nil),
            access: .interact,
            agentProfiles: nil
        )
    }
}

public struct TargetConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case docker
        case host
    }

    public enum Access: String, Codable, Sendable {
        /// Read-only: list, ps, /proc reads. No attach, no input, nothing created.
        case observe
        /// May attach and send input to existing panes. Creates and destroys nothing.
        case interact
        /// Like `interact`, and may also create and kill `agentmux-test-*` sessions.
        case test

        public var allowsAttach: Bool { self != .observe }
    }

    public struct Socket: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable {
            case `default`
            case name
            case path
        }

        public var mode: Mode
        public var value: String?

        public init(mode: Mode, value: String? = nil) {
            self.mode = mode
            self.value = value
        }
    }

    public struct AgentProfile: Codable, Sendable, Equatable {
        public var label: String
        public var provider: String
        public var configRoot: String
    }

    public var id: String
    /// Name shown in the app; defaults to the container name.
    public var displayName: String?
    public var hostId: String
    public var kind: Kind
    public var container: String?
    public var execUser: String?
    public var tmuxPath: String?
    public var tmuxSocket: Socket
    public var access: Access
    public var agentProfiles: [AgentProfile]?

    /// Validates the free-text fields and turns them into typed values.
    public func executionContext() throws -> ExecutionContext {
        let tmux = try TmuxInvocation(
            executable: tmuxPath.flatMap { $0.isEmpty ? nil : $0 },
            socket: tmuxSocket
        )
        switch kind {
        case .host:
            return ExecutionContext(container: nil, tmux: tmux)
        case .docker:
            guard let container, !container.isEmpty else {
                throw ConfigError.missingContainer(target: id)
            }
            return try ExecutionContext(
                container: DockerExec(
                    container: ContainerReference(container),
                    user: execUser.flatMap { $0.isEmpty ? nil : try ExecUser($0) }
                ),
                tmux: tmux
            )
        }
    }
}
