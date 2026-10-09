import Foundation

public enum AgentKind: String, Sendable, Equatable {
    case codex
    case claudeCode
    /// Nothing agent-like runs in the pane.
    case none
    /// Not enough evidence either way (e.g. no process table).
    case unknown
}

public enum Confidence: String, Sendable, Equatable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// What is known about the agent in one pane, and why.
public struct AgentDetection: Sendable, Equatable {
    public struct Child: Sendable, Equatable {
        public var kind: AgentKind
        public var pid: Int
    }

    public var paneID: String
    public var kind: AgentKind
    public var pid: Int?
    public var startTicks: Int?
    public var version: String?
    /// CODEX_HOME / CLAUDE_CONFIG_DIR of the process; nil means the default
    /// directory or that the environment was not readable.
    public var configDirectory: String?
    public var confidence: Confidence
    public var evidence: [String]
    /// Agents running below the main one (e.g. `claude -p` started by
    /// Codex). They have no pane of their own.
    public var children: [Child]
}

/// Answers "is there a Codex / Claude Code in this pane?" from process
/// evidence. Whether it is working or waiting is a separate question.
public enum AgentDetector {
    public static func detect(_ snapshot: InventorySnapshot) -> [String: AgentDetection] {
        var result: [String: AgentDetection] = [:]
        let byPane = Dictionary(grouping: snapshot.processes, by: \.paneID)
        for pane in snapshot.panes {
            result[pane.id] = detect(
                pane: pane,
                processes: byPane[pane.id] ?? [],
                agents: snapshot.agents,
                processTableAvailable: snapshot.processTableAvailable
            )
        }
        return result
    }

    static func detect(
        pane: InventorySnapshot.Pane,
        processes: [InventorySnapshot.ProcessNode],
        agents: [Int: InventorySnapshot.AgentEvidence],
        processTableAvailable: Bool
    ) -> AgentDetection {
        guard processTableAvailable, !processes.isEmpty else {
            // L0 only: the pane's current command name.
            let kind: AgentKind = switch pane.currentCommand {
            case "codex": .codex
            case "claude": .claudeCode
            default: .unknown
            }
            return AgentDetection(
                paneID: pane.id, kind: kind, pid: nil, startTicks: nil, version: nil,
                configDirectory: nil, confidence: .low,
                evidence: ["pane_current_command=\(pane.currentCommand); no process table"],
                children: []
            )
        }

        let matches = processes
            .sorted { ($0.depth, $0.pid) < ($1.depth, $1.pid) }
            .compactMap { node -> (InventorySnapshot.ProcessNode, Classification)? in
                classify(node: node, evidence: agents[node.pid]).map { (node, $0) }
            }
        guard let (main, classification) = matches.first else {
            return AgentDetection(
                paneID: pane.id, kind: .none, pid: nil, startTicks: nil, version: nil,
                configDirectory: nil, confidence: .medium,
                evidence: ["no agent process among \(processes.count) processes under the pane"],
                children: []
            )
        }

        let evidence = agents[main.pid]
        var reasons = classification.reasons
        var confidence = classification.confidence
        if let tmuxPane = evidence?.environment["TMUX_PANE"] {
            if tmuxPane == pane.id {
                reasons.append("TMUX_PANE=\(tmuxPane)")
                if confidence == .medium { confidence = .high }
            } else {
                reasons.append("TMUX_PANE=\(tmuxPane) differs from pane")
                confidence = min(confidence, .medium)
            }
        }
        let configKey = classification.kind == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        return AgentDetection(
            paneID: pane.id,
            kind: classification.kind,
            pid: main.pid,
            startTicks: evidence?.startTicks,
            version: classification.version,
            configDirectory: evidence?.environment[configKey],
            confidence: confidence,
            evidence: reasons,
            children: matches.dropFirst()
                .filter { $0.0.depth > main.depth }
                .map { .init(kind: $0.1.kind, pid: $0.0.pid) }
        )
    }

    struct Classification: Equatable {
        var kind: AgentKind
        var version: String?
        var confidence: Confidence
        var reasons: [String]
    }

    /// Classifies one process. The executable and argv decide, never the
    /// pane title or terminal text: `vim codex_notes.md` is vim.
    static func classify(node: InventorySnapshot.ProcessNode, evidence: InventorySnapshot.AgentEvidence?) -> Classification? {
        // An exited child that was not reaped yet is not a running agent.
        if node.isZombie { return nil }
        guard let evidence, !evidence.executable.isEmpty else {
            // Only the short command name is known.
            switch node.command {
            case "codex": return Classification(kind: .codex, version: nil, confidence: .low, reasons: ["comm=codex; executable unreadable"])
            case "claude": return Classification(kind: .claudeCode, version: nil, confidence: .low, reasons: ["comm=claude; executable unreadable"])
            default: return nil
            }
        }

        let executable = evidence.executable.replacingOccurrences(of: " (deleted)", with: "")
        let name = (executable as NSString).lastPathComponent
        let subcommand = evidence.arguments.dropFirst().first ?? ""
        let script = subcommand

        // Long-running helpers that are not an interactive agent.
        let helperSubcommands: Set = ["daemon", "bg-pty-host", "bg-spare", "app-server", "mcp-server"]

        if name == "codex" {
            if helperSubcommands.contains(subcommand) { return nil }
            return Classification(
                kind: .codex, version: codexVersion(executable), confidence: .medium,
                reasons: ["executable \(name)"]
            )
        }
        if executable.contains("/claude/versions/") || name == "claude" {
            if helperSubcommands.contains(subcommand) { return nil }
            return Classification(
                kind: .claudeCode, version: claudeVersion(executable), confidence: .medium,
                reasons: ["executable \(executable.contains("/claude/versions/") ? "claude/versions/*" : name)"]
            )
        }
        if ["node", "bun", "deno"].contains(name) {
            if script.contains("@openai/codex") || script.hasSuffix("/codex") || script.hasSuffix("/codex.js") {
                return Classification(kind: .codex, version: nil, confidence: .medium, reasons: ["\(name) running codex entry"])
            }
            if script.contains("@anthropic-ai/claude-code") || script.hasSuffix("/claude") {
                return Classification(kind: .claudeCode, version: nil, confidence: .medium, reasons: ["\(name) running claude-code entry"])
            }
        }
        return nil
    }

    /// `.../releases/0.160.1-x86_64-unknown-linux-musl/bin/codex` -> `0.160.1`
    static func codexVersion(_ path: String) -> String? {
        guard let range = path.range(of: "/releases/") else { return nil }
        let rest = path[range.upperBound...]
        let component = rest.split(separator: "/").first ?? ""
        let version = component.split(separator: "-").first.map(String.init)
        return version?.first?.isNumber == true ? version : nil
    }

    /// `.../claude/versions/2.1.288` -> `2.1.288`
    static func claudeVersion(_ path: String) -> String? {
        guard let range = path.range(of: "/claude/versions/") else { return nil }
        let version = path[range.upperBound...].split(separator: "/").first.map(String.init)
        return version?.first?.isNumber == true ? version : nil
    }
}
