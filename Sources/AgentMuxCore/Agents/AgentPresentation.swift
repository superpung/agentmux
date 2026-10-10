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
