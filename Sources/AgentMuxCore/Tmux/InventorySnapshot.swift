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

    /// Token usage read from an agent's session log (structural numbers only).
    public struct AgentUsage: Sendable, Equatable {
        /// Tokens in the current context (the last request's prompt size).
        public var contextTokens: Int?
        /// The model's context window, when the log records it (Codex).
        public var contextWindow: Int?
        /// Rate-limit used percent, when the log records it (Codex weekly).
        public var rateLimitPercent: Double?
        /// Context window used percent, reported directly (Claude status line).
        public var contextPercent: Double?
        /// 5-hour rolling limit used percent (Claude status line; Codex primary).
        public var fiveHourPercent: Double?
        /// 7-day / weekly limit used percent (Claude status line; Codex secondary).
        public var sevenDayPercent: Double?
        /// Unix epoch when the 5-hour window resets, when reported.
        public var fiveHourResetsAt: Int?
        /// Unix epoch when the 7-day/weekly window resets, when reported.
        public var sevenDayResetsAt: Int?

        public init(contextTokens: Int? = nil, contextWindow: Int? = nil, rateLimitPercent: Double? = nil,
                    contextPercent: Double? = nil, fiveHourPercent: Double? = nil, sevenDayPercent: Double? = nil,
                    fiveHourResetsAt: Int? = nil, sevenDayResetsAt: Int? = nil) {
            self.contextTokens = contextTokens
            self.contextWindow = contextWindow
            self.rateLimitPercent = rateLimitPercent
            self.contextPercent = contextPercent
            self.fiveHourPercent = fiveHourPercent
            self.sevenDayPercent = sevenDayPercent
            self.fiveHourResetsAt = fiveHourResetsAt
            self.sevenDayResetsAt = sevenDayResetsAt
        }

        /// Fraction of the context window in use, when both are known.
        public var contextFraction: Double? {
            guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
            return Double(contextTokens) / Double(contextWindow)
        }

        /// Context fill as a fraction (0-1): the directly-reported percent when
        /// present (Claude status line), else computed from tokens/window.
        public var contextUsedFraction: Double? {
            if let contextPercent { return contextPercent / 100 }
            return contextFraction
        }

        /// Claude's session log omits the context window; Claude Code uses
        /// 200k, or 1M for extended-context models, and exposes the exact value
        /// only to its status line. We infer it safely: a context over 200k
        /// must be a 1M window, and ≤200k is treated as 200k. This can overstate
        /// the fraction for a 1M model at low usage, but never understates a
        /// near-full context. Codex records its own window, so this is a no-op.
        public func withInferredWindow() -> Self {
            guard contextWindow == nil, let contextTokens else { return self }
            var copy = self
            copy.contextWindow = contextTokens > 200_000 ? 1_000_000 : 200_000
            return copy
        }
    }

    /// Progress of a long-running job in an agent's pane, from the per-pane JSON
    /// the `agentmux-progress` wrapper writes. Structural only (counts, times,
    /// a short status line), never the conversation.
    public struct AgentProgress: Sendable, Equatable, Decodable {
        public var label: String
        public var state: String // running | done | failed
        /// The tmux pane the job runs in, so it maps to the right agent even when
        /// the file is keyed by a custom --id.
        public var pane: String?
        public var current: Int?
        public var total: Int?
        public var percent: Double?
        public var message: String?
        public var startedAt: Double?
        public var updatedAt: Double?
        public var etaSeconds: Int?
        public var exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case label, state, pane, current, total, percent, message
            case startedAt = "started_at"
            case updatedAt = "updated_at"
            case etaSeconds = "eta_seconds"
            case exitCode = "exit_code"
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil ?? "job"
            state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil ?? "running"
            pane = try? c.decodeIfPresent(String.self, forKey: .pane)
            current = try? c.decodeIfPresent(Int.self, forKey: .current)
            total = try? c.decodeIfPresent(Int.self, forKey: .total)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
            updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
            etaSeconds = try? c.decodeIfPresent(Int.self, forKey: .etaSeconds)
            exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
        }

        /// Fraction complete (0-1) from percent, else current/total.
        public var fraction: Double? {
            if let percent { return max(0, min(1, percent / 100)) }
            guard let current, let total, total > 0 else { return nil }
            return max(0, min(1, Double(current) / Double(total)))
        }
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
    /// Server-computed session-log verdict per Codex pane ("working" / "idle"),
    /// from the rollout's last task_started/task_complete. Only the verdict
    /// leaves the container — never the conversation.
    public var logStates: [String: String] = [:]
    /// Pane id → why its agent's last turn stopped short (usage limit or an
    /// error), when it did.
    public var faults: [String: AgentFault] = [:]
    /// Token usage per agent pane, read from the session log (numbers only).
    public var usage: [String: AgentUsage] = [:]
    /// Long-job progress per agent pane, from the agentmux-progress wrapper.
    public var progress: [String: AgentProgress] = [:]
    /// Model id per agent pane (e.g. "claude-opus-5-5", "gpt-6-astra"), read
    /// from the session log (metadata only).
    public var models: [String: String] = [:]
    /// Reasoning effort per agent pane ("medium"/"high"/"xhigh"), when known.
    public var efforts: [String: String] = [:]
    /// Non-secret account identity per agent pane ("claude:<uuid>" /
    /// "codex:<id>"), when a readable account id exists — used only to merge the
    /// same login across config dirs/containers in the dashboard. Never a token.
    public var accounts: [String: String] = [:]
    /// Seconds since each agent pane's session log was last written — a proxy
    /// for when the agent was last active.
    public var lastActiveSeconds: [String: Int] = [:]
    public var processTableAvailable = true
    /// Set when the target was reached but tmux was not usable.
    public var failure: RemoteFailure?

    public init() {}

    public func pane(_ id: String) -> Pane? {
        panes.first { $0.id == id }
    }

    /// A pane's membership in a real session, preferring one that isn't an
    /// AgentMux grouped mirror session ("agentmux-…"). Grouped sessions share a
    /// real session's windows, so a pane can be a member of both; labels and
    /// identity must come from the real one, and must not flip when a mirror
    /// opens or closes.
    public func primaryMembership(of paneID: String) -> Membership? {
        let rows = memberships.filter { $0.paneID == paneID }
        func isGrouped(_ sessionID: String) -> Bool {
            (sessions.first { $0.id == sessionID }?.name ?? "").hasPrefix(RemoteCommand.groupedSessionPrefix)
        }
        return rows.first { !isGrouped($0.sessionID) } ?? rows.first
    }

    /// Whether a pane belongs to any real (non-grouped) session. A pane that
    /// lives only in an AgentMux grouped mirror session is a ghost — its real
    /// session was killed and only our mirror is keeping the window alive.
    public func hasRealSession(_ paneID: String) -> Bool {
        memberships.contains { membership in
            guard membership.paneID == paneID else { return false }
            let name = sessions.first { $0.id == membership.sessionID }?.name ?? ""
            return !name.hasPrefix(RemoteCommand.groupedSessionPrefix)
        }
    }
}
