import Foundation

/// Why an agent's last turn stopped short: a usage limit, or an error left
/// after the agent's own retries. Built from the probe's reduced signal (for
/// Claude, the session log's error record fields; for Codex, the class of the
/// last error line on its screen), never from the conversation.
public struct AgentFault: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case usageLimit
        case error
    }

    public var kind: Kind
    /// The agent's error code ("server_error", "unknown", …), when it gives one.
    public var code: String?
    /// When a usage limit resets, in epoch seconds.
    public var resetsAt: Int?
    /// Which limit was hit ("five_hour", "seven_day"), when known.
    public var limitWindow: String?
    /// When the error was written, in epoch seconds, which tells one
    /// occurrence from the next. Nil when the agent gives no time (Codex).
    public var occurredAt: Int?
    /// Whether asking the agent to continue can help: a dropped connection,
    /// a server error or a transient rate limit, but not a usage limit, an
    /// auth or billing problem, or a request the API rejects outright.
    public var isRetryable: Bool

    public init(kind: Kind, code: String? = nil, resetsAt: Int? = nil, limitWindow: String? = nil,
                occurredAt: Int? = nil, isRetryable: Bool) {
        self.kind = kind
        self.code = code
        self.resetsAt = resetsAt
        self.limitWindow = limitWindow
        self.occurredAt = occurredAt
        self.isRetryable = isRetryable
    }

    /// Claude error codes that a later attempt can get past.
    static let retryableClaudeCodes: Set<String> = ["server_error", "unknown", "rate_limit", "overloaded_error", "api_error", "timeout"]

    /// Parses the probe's `@@fault` fields after the pane id:
    /// `<agent> <code> <quota status> <resets at> <limit window> <epoch>`,
    /// with `-` for unknown.
    public static func parse<S: Sequence>(_ fields: S) -> AgentFault? where S.Element == Substring {
        let f = fields.map { $0 == "-" ? nil : String($0) }
        guard f.count >= 2, let agent = f[0], let code = f[1] else { return nil }
        func field(_ i: Int) -> String? { i < f.count ? f[i] : nil }
        switch agent {
        case "claude":
            if code == "rate_limit", field(2) == "rejected" {
                return AgentFault(kind: .usageLimit, code: code, resetsAt: field(3).flatMap(Int.init),
                                  limitWindow: field(4), occurredAt: field(5).flatMap(Int.init), isRetryable: false)
            }
            return AgentFault(kind: .error, code: code, occurredAt: field(5).flatMap(Int.init),
                              isRetryable: retryableClaudeCodes.contains(code))
        case "codex":
            switch code {
            case "usage_limit": return AgentFault(kind: .usageLimit, isRetryable: false)
            case "fatal": return AgentFault(kind: .error, code: "fatal", isRetryable: false)
            default: return AgentFault(kind: .error, isRetryable: true)
            }
        default:
            return nil
        }
    }

    /// A short description for a notification ("Connection error",
    /// "Weekly limit").
    public var summary: String {
        switch kind {
        case .usageLimit:
            switch limitWindow {
            case "five_hour": return "5-hour limit"
            case "seven_day", "seven_day_opus", "seven_day_sonnet": return "Weekly limit"
            default: return "Usage limit"
            }
        case .error:
            switch code {
            case "server_error", "api_error": return "Server error"
            case "unknown": return "Connection error"
            case "overloaded_error": return "API overloaded"
            case "rate_limit": return "Rate limited"
            case "timeout": return "Request timed out"
            case "authentication_failed": return "Authentication failed"
            case "billing_error": return "Billing error"
            case "invalid_request": return "Invalid request"
            case "fatal": return "Unrecoverable error"
            default: return "API error"
            }
        }
    }

    /// Whether two observations are the same occurrence: same kind, and the
    /// same write time when both have one.
    public func isSameOccurrence(as other: AgentFault) -> Bool {
        guard kind == other.kind else { return false }
        if let a = occurredAt, let b = other.occurredAt { return a == b }
        return true
    }
}

/// Follows each agent's fault from poll to poll and reports one only when it
/// starts, so a fault that stays on screen is handled once. A fault that is
/// still there `renudgeAfter` seconds after the agent was asked to continue
/// counts as a new one: the agent tried again and failed the same way (Codex
/// gives no time to tell the two apart).
public struct FaultTracker: Sendable {
    public static let renudgeAfter: TimeInterval = 120

    private struct Spell: Sendable {
        var fault: AgentFault
        var nudgedAt: Date?
        /// No more tries during this fault (a draft in the way, a failed send,
        /// or the tries ran out).
        var isAbandoned = false
    }

    private var spells: [String: Spell] = [:]

    public init() {}

    /// Takes one target's faults (pane id → fault, for agents not working)
    /// and returns the ones that started. `report` false records the current
    /// faults without reporting them (a target's first poll).
    public mutating func update(_ faults: [String: AgentFault], now: Date, report: Bool = true) -> [String: AgentFault] {
        var started: [String: AgentFault] = [:]
        var next: [String: Spell] = [:]
        for (pane, fault) in faults {
            if var spell = spells[pane], spell.fault.isSameOccurrence(as: fault),
               spell.nudgedAt.map({ now.timeIntervalSince($0) < Self.renudgeAfter }) ?? true {
                spell.fault = fault
                next[pane] = spell
            } else {
                next[pane] = Spell(fault: fault)
                if report { started[pane] = fault }
            }
        }
        spells = next
        return started
    }

    /// The agent in `pane` was just asked to continue.
    public mutating func noteNudge(_ pane: String, at date: Date) {
        spells[pane]?.nudgedAt = date
    }

    /// Stops tries for `pane` until its fault clears or a new one starts.
    public mutating func abandon(_ pane: String) {
        spells[pane]?.isAbandoned = true
    }

    /// Whether the agent was already asked to continue during its current
    /// fault, or tries for it were given up.
    public func isHandled(_ pane: String) -> Bool {
        guard let spell = spells[pane] else { return false }
        return spell.nudgedAt != nil || spell.isAbandoned
    }

    /// The fault `pane` shows now, if any.
    public func fault(_ pane: String) -> AgentFault? {
        spells[pane]?.fault
    }
}
