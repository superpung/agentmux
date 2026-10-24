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

/// Infers what an agent is doing from status-only signals (its terminal title
/// and a server-reduced screen/log verdict — never conversation content).
///
/// Conservative by design (the spec forbids false "done" alerts): `working`
/// and `idle` are claimed only from reliable provider markers. The one
/// attention state we claim is backed by a verified marker too — Codex sets
/// "Action Required" in its title while blocked on the user; Claude Code has
/// no verified title marker yet, so its attention states stay `unknown`.
public enum ActivityDetector {
    /// Resolves activity from status-only inputs. The background probe never
    /// sends screen content: for Claude it reads the session log's last event
    /// type/subtype (`logEvent`), and for any agent it reduces the screen to a
    /// `working`/`idle`/`unknown` verdict on the server (`screenState`), which
    /// mirrors `screenVerdict` below. It also passes the terminal `title` the
    /// agent sets (OSC 2). Priority: an explicit "needs the user" title wins,
    /// then the log, then the screen.
    public static func resolve(
        kind: AgentKind,
        logEvent: String?,
        logAgeSeconds _: Int? = nil,
        screenState: String?,
        logState: String? = nil,
        title: String? = nil
    ) -> ActivityObservation {
        // Highest priority: the agent has explicitly flagged it is blocked on
        // the user. This outranks a "working" log/screen signal because the
        // turn can still read as running while it waits at a prompt.
        if let title, let attention = attentionVerdict(kind: kind, title: title) {
            return attention
        }
        // Codex animates a Braille spinner in its window title while a turn
        // runs — a reliable, per-pane, real-time signal. Two codex agents in the
        // same directory can have their rollout logs cross-attributed (the log
        // is matched by cwd), so a lone logState="working" is not trusted for
        // codex: the title and screen decide, and only their absence falls back
        // to the log's idle verdict. (Codex with no title falls through below.)
        if kind == .codex, let title {
            if codexTitleIsWorking(title) {
                return ActivityObservation(.working, .high, "title: codex running")
            }
            if screenState == "working" {
                return ActivityObservation(.working, .high, "screen verdict: working")
            }
            if screenState == "idle" || logState == "idle" {
                return ActivityObservation(.idle, .high, "codex idle")
            }
            return ActivityObservation(.idle, .medium, "codex: no spinner, no active signal")
        }
        // Codex (no title) / Claude: the rollout's last task_* event, already
        // reduced to a verdict on the server (task_started = working, idle).
        switch logState {
        case "working": return ActivityObservation(.working, .high, "log: task in progress")
        case "idle": return ActivityObservation(.idle, .high, "log: task complete")
        default: break
        }
        // Claude: a written turn-end marker is authoritative. "turn_duration" is
        // emitted when a turn ends; nothing newer follows it in the log (a new
        // turn would append after it), so it outranks the screen.
        if let logEvent, logEvent.hasSuffix("/turn_duration") {
            return ActivityObservation(.idle, .high, "log: turn ended (\(logEvent))")
        }
        // The live screen reflects whether a turn is actually running — a spinner
        // or "esc to interrupt" vs the ready "❯" prompt — and the screen verdict
        // already resolves working ahead of idle. It outranks the log's last-line
        // inference below, which reads a trailing tool_result or plain user/
        // assistant record as "in progress" while Claude in fact sits idle at the
        // prompt (seen on a resumed session, 2026-10-24).
        switch screenState {
        case "working": return ActivityObservation(.working, .high, "screen verdict: working")
        case "waiting": return ActivityObservation(.waitingInput, .high, "screen verdict: selection prompt")
        case "idle": return ActivityObservation(.idle, kind == .codex ? .high : .medium, "screen verdict: idle")
        default: break
        }
        // No screen signal: fall back to the log's last turn event. An assistant
        // or user last event means a turn is still in progress.
        if let logEvent, logEvent.hasPrefix("assistant") || logEvent.hasPrefix("user") {
            return ActivityObservation(.working, .high, "log: turn in progress (\(logEvent))")
        }
        return ActivityObservation(.unknown, .low, "no log or screen signal")
    }

    /// Whether the terminal title shows the agent is waiting on the user.
    ///
    /// Codex prefixes its title with "[ ! ] Action Required | …" while blocked
    /// on a prompt — verified live (2026-10-14): a waiting pane read
    /// "[ ! ] Action Required | … | conf-scheduler" while working/idle panes
    /// read "… | dashboard" / "usage-monitor" with no such marker. The title
    /// can't tell an approval request from a plain question, so the umbrella
    /// `.waitingInput` ("Needs input") is used; both are `needsAttention`.
    /// Claude Code has no verified title marker, so it is left to the log rule.
    public static func attentionVerdict(kind: AgentKind, title: String) -> ActivityObservation? {
        guard kind == .codex else { return nil }
        if title.range(of: "Action Required", options: .caseInsensitive) != nil {
            return ActivityObservation(.waitingInput, .high, "title: Action Required")
        }
        return nil
    }

    /// Codex animates a Braille-dots spinner (U+2800…U+28FF) in its window title
    /// while a turn is running, so any Braille scalar means it is actively
    /// working. The title is per-pane, unlike the rollout log which can be
    /// cross-attributed between codex agents sharing a directory.
    public static func codexTitleIsWorking(_ title: String) -> Bool {
        title.unicodeScalars.contains { (0x2800 ... 0x28FF).contains($0.value) }
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
        // A numbered selection menu with the "❯" cursor on an option is Claude
        // waiting for the user to pick (a permission or question prompt). The
        // cursor also starts a plain idle prompt, so this is matched first.
        if kind == .claudeCode,
           screen.contains(where: { $0.range(of: #"^\s*❯\s+\d+\.\s"#, options: .regularExpression) != nil }) {
            return ActivityObservation(.waitingInput, .high, "screen shows a selection prompt")
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
        // While Codex waits on the user it replaces the task-name slot with the
        // status "[ ! ] Action Required" — a state, not a name. Drop it so the
        // row falls back to the session/path; the waiting state is surfaced by
        // the activity chip, not the title.
        if kind == .codex, title.range(of: "Action Required", options: .caseInsensitive) != nil {
            return nil
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
