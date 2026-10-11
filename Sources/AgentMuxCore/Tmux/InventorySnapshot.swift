import Foundation

/// One read of a target: container identity, tmux server, its objects, the
/// process trees under its panes and evidence about agent candidates. Text
/// fields come from the remote side and are untrusted display strings.
public struct InventorySnapshot: Sendable, Equatable {
    public struct Container: Sendable, Equatable {
        public var id: String
        public var status: String
        public var startedAt: String
        public var pid: Int
    }

    public struct Server: Sendable, Equatable {
        public var pid: Int
        public var startTime: Int
        public var socketPath: String
    }

    public struct Session: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
    }

    public struct Window: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
    }

    /// One row of `list-panes -a`: a pane as reached through one session and
    /// window. A pane in a linked window has several memberships.
    public struct Membership: Sendable, Equatable {
        public var sessionID: String
        public var windowID: String
        public var paneID: String
        public var windowIndex: Int
        public var paneIndex: Int
        public var paneActive: Bool
        public var windowActive: Bool
    }

    public struct Pane: Sendable, Equatable, Identifiable {
        public var id: String
        public var pid: Int
        public var dead: Bool
        public var width: Int
        public var height: Int
        public var currentCommand: String
        public var currentPath: String
        public var title: String
    }

    /// A process at `depth` below a pane's root process (depth 0 is the root).
    public struct ProcessNode: Sendable, Equatable {
        public var paneID: String
        public var depth: Int
        public var pid: Int
        public var ppid: Int
        /// `ps` STAT, e.g. `S`, `Rl+`, `Z` (zombie).
        public var state: String
        public var command: String

        public var isZombie: Bool { state.hasPrefix("Z") }
    }

    public struct AgentEvidence: Sendable, Equatable {
        public var pid: Int
        /// `/proc/<pid>/exe` target; may end in " (deleted)" after an update.
        public var executable: String
        /// First arguments, newlines replaced by spaces, each truncated.
        public var arguments: [String]
        /// Only CODEX_HOME, CLAUDE_CONFIG_DIR and TMUX_PANE are collected.
        public var environment: [String: String]
        /// Start time in clock ticks since boot, for process identity.
        public var startTicks: Int?
        /// Claude session log's last event as "type/subtype" (structural only,
        /// no content), e.g. "system/turn_duration" or "assistant/". nil when
        /// no log was read.
        public var logEvent: String?
        /// Seconds since the session log was last written.
        public var logAgeSeconds: Int?
    }

    public var container: Container?
    public var uid: Int?
    /// `ID` from /etc/os-release, e.g. `ubuntu`.
    public var osID: String?
    public var tmuxVersion: String?
    public var server: Server?
    public var sessions: [Session] = []
    public var windows: [Window] = []
    public var memberships: [Membership] = []
    public var panes: [Pane] = []
    public var processes: [ProcessNode] = []
    public var agents: [Int: AgentEvidence] = [:]
    /// Server-computed screen activity verdict per agent pane ("working" /
    /// "idle" / "unknown"). The screen content never leaves the container.
    public var screenStates: [String: String] = [:]
    public var processTableAvailable = true
    /// Set when the target was reached but tmux was not usable.
    public var failure: RemoteFailure?

    public init() {}

    public func pane(_ id: String) -> Pane? {
        panes.first { $0.id == id }
    }
}
