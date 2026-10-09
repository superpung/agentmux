import Foundation

/// Rejected free-text input. Every value that ends up in a remote command
/// passes through one of the typed wrappers below first.
public struct InvalidRemoteValue: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let value: String

    public var description: String {
        "invalid \(field): \(value.debugDescription)"
    }
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) == value.startIndex ..< value.endIndex
}

private func hasControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

/// An ssh destination: a config alias or `user@host`. Never starts with `-`,
/// so ssh cannot read it as an option.
public struct SSHDestination: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        guard matches(value, "[A-Za-z0-9_.][A-Za-z0-9_.@:%\\[\\]-]{0,254}") else {
            throw InvalidRemoteValue(field: "sshDestination", value: value)
        }
        self.value = value
    }

    public var description: String { value }
}

/// A container name or ID as Docker accepts them.
public struct ContainerReference: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        guard matches(value, "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}") else {
            throw InvalidRemoteValue(field: "container", value: value)
        }
        self.value = value
    }

    public var description: String { value }
}

/// `docker exec --user`: a name or UID, optionally with `:group`.
public struct ExecUser: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        let part = "[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}"
        guard matches(value, "\(part)(:\(part))?") else {
            throw InvalidRemoteValue(field: "execUser", value: value)
        }
        self.value = value
    }

    public var description: String { value }
}

/// How to reach one tmux server: the binary and its socket.
public struct TmuxInvocation: Sendable, Equatable {
    public enum Socket: Sendable, Equatable {
        case `default`
        /// `tmux -L name`
        case name(String)
        /// `tmux -S path`
        case path(String)
    }

    /// Absolute path, or nil to use `tmux` from the remote PATH.
    public let executable: String?
    public let socket: Socket

    public init(executable: String?, socket: Socket) throws {
        if let executable {
            guard executable.hasPrefix("/"), !hasControlCharacters(executable), executable.count < 1024 else {
                throw InvalidRemoteValue(field: "tmuxPath", value: executable)
            }
        }
        switch socket {
        case .default:
            break
        case let .name(name):
            guard matches(name, "[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}") else {
                throw InvalidRemoteValue(field: "tmuxSocket.name", value: name)
            }
        case let .path(path):
            guard path.hasPrefix("/"), !hasControlCharacters(path), path.utf8.count < 104 else {
                throw InvalidRemoteValue(field: "tmuxSocket.path", value: path)
            }
        }
        self.executable = executable
        self.socket = socket
    }

    init(executable: String?, socket: TargetConfig.Socket) throws {
        let typed: Socket = switch socket.mode {
        case .default: .default
        case .name: .name(socket.value ?? "")
        case .path: .path(socket.value ?? "")
        }
        try self.init(executable: executable, socket: typed)
    }

    /// argv prefix: binary, `-u` (UTF-8 output regardless of locale) and the socket flag.
    public var argv: [String] {
        var argv = [executable ?? "tmux", "-u"]
        switch socket {
        case .default: break
        case let .name(name): argv += ["-L", name]
        case let .path(path): argv += ["-S", path]
        }
        return argv
    }
}

public struct DockerExec: Sendable, Equatable {
    public let container: ContainerReference
    public let user: ExecUser?

    public init(container: ContainerReference, user: ExecUser?) {
        self.container = container
        self.user = user
    }
}

/// Where remote commands run: on the host itself or inside one container as
/// one user, against one tmux server. Discovery, detection and attach all go
/// through the same context.
public struct ExecutionContext: Sendable, Equatable {
    public let container: DockerExec?
    public let tmux: TmuxInvocation

    public init(container: DockerExec?, tmux: TmuxInvocation) {
        self.container = container
        self.tmux = tmux
    }
}
