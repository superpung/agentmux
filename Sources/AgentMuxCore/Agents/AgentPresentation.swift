import Foundation

/// What an agent is doing. Kept separate from `AgentKind` (what it is) and
/// from the connection state (whether we can see it at all).
public enum AgentActivity: String, Sendable, Equatable {
    case working
    case waitingInput
    case waitingApproval
    case idle
    case exited
    /// Not enough evidence: unsupported version, stale data, or no rule yet.
    case unknown

    public var needsAttention: Bool {
        self == .waitingInput || self == .waitingApproval
    }
}

/// An activity inference with the evidence behind it.
public struct ActivityObservation: Sendable, Equatable {
    public var activity: AgentActivity
    public var confidence: Confidence
    public var evidence: String

    public init(_ activity: AgentActivity, _ confidence: Confidence, _ evidence: String) {
        self.activity = activity
        self.confidence = confidence
        self.evidence = evidence
    }

    public static let noScreen = ActivityObservation(.unknown, .low, "no screen captured")
}

/// Infers what an agent is doing from a bounded tail of its terminal screen.
///
/// Conservative by design (the spec forbids false "done"/approval alerts):
/// only `working` and `idle` are claimed, from reliable provider markers;
/// everything else is `unknown`. Approval / waiting-input detection needs
/// real fixtures of those states and is deliberately not guessed here.
public enum ActivityDetector {
    /// Resolves activity from status-only inputs. The background probe never
    /// sends screen content: for Claude it reads the session log's last event
    /// type/subtype (`logEvent`), and for any agent it reduces the screen to a
    /// `working`/`idle`/`unknown` verdict on the server (`screenState`), which
    /// mirrors `screenVerdict` below. The log wins when present.
    public static func resolve(
        kind: AgentKind,
        logEvent: String?,
        logAgeSeconds _: Int? = nil,
        screenState: String?,
        logState: String? = nil
    ) -> ActivityObservation {
        // Codex: the rollout's last task_* event, already reduced to a verdict
        // on the server (task_started = working, task_complete = idle).
        switch logState {
        case "working": return ActivityObservation(.working, .high, "log: task in progress")
        case "idle": return ActivityObservation(.idle, .high, "log: task complete")
        default: break
        }
        // Claude: the session log is robust to CLI version changes.
        // "turn_duration" is written when a turn ends; an assistant/user last
        // event means the turn is still in progress.
        if let logEvent {
            if logEvent.hasSuffix("/turn_duration") {
                return ActivityObservation(.idle, .high, "log: turn ended (\(logEvent))")
            }
            if logEvent.hasPrefix("assistant") || logEvent.hasPrefix("user") {
                return ActivityObservation(.working, .high, "log: turn in progress (\(logEvent))")
            }
        }
        switch screenState {
        case "working": return ActivityObservation(.working, .high, "screen verdict: working")
        case "idle": return ActivityObservation(.idle, kind == .codex ? .high : .medium, "screen verdict: idle")
        default: return ActivityObservation(.unknown, .low, "no log or screen signal")
        }
    }

    /// The screen rule, kept as the reference the server's shell mirrors and
    /// for unit tests. Conservative: only `working` and `idle` are claimed.
    public static func screenVerdict(kind: AgentKind, screen: [String]) -> ActivityObservation {
        guard !screen.isEmpty else { return .noScreen }
        let text = screen.joined(separator: "\n")
        let lower = text.lowercased()

        // Working — checked first, because the input box is on screen even while
        // a turn runs. Claude Code (verified) shows a spinner line
        // `✽ <Verb>ing… (23m 36s · …)` and running tool lines `… (8m 1s)`: a
        // Unicode ellipsis followed by a parenthesised elapsed time. Both CLIs
        // may also print an "esc to interrupt" hint.
        if text.range(of: #"…\s*\(\d+\s*[hms]"#, options: .regularExpression) != nil {
            return ActivityObservation(.working, .high, "screen shows a running spinner/elapsed time")
        }
        if lower.contains("esc to interrupt") {
            return ActivityObservation(.working, .high, "screen shows 'esc to interrupt'")
        }
        if text.contains("· Ready ·") || lower.contains(" ready · context") {
            return ActivityObservation(.idle, .high, "Codex status shows 'Ready'")
        }
        if kind == .claudeCode, screen.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) {
            return ActivityObservation(.idle, .medium, "Claude input box ready, no running turn")
        }
        return ActivityObservation(.unknown, .low, "no matching rule")
    }
}

/// Short task titles from the terminal title an agent sets (OSC 2).
public enum AgentTitle {
    /// Claude Code sets `✳ <session>`; Codex sets `<session> | <project>`.
    /// Returns nil when the title carries no task name.
    public static func from(paneTitle: String, kind: AgentKind) -> String? {
        var scalars = Array(paneTitle.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        // Drop status marks and spinners: one glyph followed by a space.
        while scalars.count >= 2, isMark(scalars[0]), scalars[1] == " " {
            scalars.removeFirst(2)
            while scalars.first == " " { scalars.removeFirst() }
        }
        var title = String(String.UnicodeScalarView(scalars))
        if kind == .codex, let separator = title.range(of: " | ") {
            title = String(title[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let generic: Set = ["", "claude", "claude code", "codex"]
        return generic.contains(title.lowercased()) ? nil : title
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        if (0x2800 ... 0x28FF).contains(scalar.value) { return true } // braille spinners
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
