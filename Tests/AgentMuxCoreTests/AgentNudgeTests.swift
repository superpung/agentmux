@testable import AgentMuxCore
import Foundation
import Testing

/// The auto-continue keystrokes, run under a real shell against a private
/// local tmux server (its own socket, killed afterwards): the message lands
/// in a running program as typed text plus Enter, and never in a shell.
@Suite(.serialized) struct AgentNudgeTests {
    static let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test func rejectsBadInput() {
        let argv = ["tmux"]
        #expect(AgentNudge.script("continue", paneID: "%1", quietSeconds: 30, tmux: argv) != nil)
        #expect(AgentNudge.script("  ", paneID: "%1", quietSeconds: 30, tmux: argv) == nil)
        #expect(AgentNudge.script("a\nb", paneID: "%1", quietSeconds: 30, tmux: argv) == nil)
        #expect(AgentNudge.script("continue", paneID: "1; rm -rf /", quietSeconds: 30, tmux: argv) == nil)
        #expect(AgentNudge.script(String(repeating: "x", count: 501), paneID: "%1", quietSeconds: 30, tmux: argv) == nil)
    }

    @Test func parsesOutcomes() {
        #expect((try? AgentNudge.parse("noise\nSENT\n").get()) == .sent)
        #expect((try? AgentNudge.parse("BUSY").get()) == .busy)
        #expect((try? AgentNudge.parse("GONE").get()) == .gone)
        #expect((try? AgentNudge.parse("DRAFT").get()) == .draft)
        guard case let .failure(failure) = AgentNudge.parse("ERR: could not type the message") else {
            Issue.record("expected failure"); return
        }
        #expect(failure.detail == "could not type the message")
    }

    @Test(.enabled(if: tmuxPath != nil)) func typesIntoAProgramButNeverAShell() throws {
        let tmux = [Self.tmuxPath!, "-L", "agentmux-nudge-\(UUID().uuidString.prefix(8))", "-f", "/dev/null"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nudge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("typed.txt").path
        defer {
            _ = try? Self.sh(ShellQuote.command(tmux) + " kill-server")
            try? FileManager.default.removeItem(at: dir)
        }
        // A program reading its terminal (as an agent would) and a bare shell.
        _ = try Self.sh(ShellQuote.command(tmux) + " new-session -d -s t -x 80 -y 24 " + ShellQuote.word("cat > " + ShellQuote.word(out)))
        _ = try Self.sh(ShellQuote.command(tmux) + " new-window -d -t t /bin/sh")
        let panes = try Self.sh(ShellQuote.command(tmux) + " list-panes -s -t t -F '#{pane_id}'")
            .split(whereSeparator: \.isNewline).map(String.init)
        try #require(panes.count == 2)
        // Let both programs start, so tmux reports their commands.
        Thread.sleep(forTimeInterval: 0.5)

        let message = "continue, it's \"fine\" $HOME"
        let sent = try Self.sh(#require(AgentNudge.script(message, paneID: panes[0], quietSeconds: 30, tmux: tmux)), remote: true)
        #expect((try? AgentNudge.parse(sent).get()) == .sent)
        Thread.sleep(forTimeInterval: 0.5)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == message + "\n")

        let shell = try Self.sh(#require(AgentNudge.script("continue", paneID: panes[1], quietSeconds: 30, tmux: tmux)), remote: true)
        #expect((try? AgentNudge.parse(shell).get()) == .gone)

        let missing = try Self.sh(#require(AgentNudge.script("continue", paneID: "%999", quietSeconds: 30, tmux: tmux)), remote: true)
        #expect((try? AgentNudge.parse(missing).get()) == .gone)
    }

    /// The input line is read with its attributes: dim text is the agent's
    /// placeholder (Claude's suggestion, Codex's "Explain this codebase"),
    /// plain text is a draft the message must not be appended to.
    @Test(.enabled(if: tmuxPath != nil)) func holdsOffOnlyForARealDraft() throws {
        let tmux = [Self.tmuxPath!, "-L", "agentmux-nudge-\(UUID().uuidString.prefix(8))", "-f", "/dev/null"]
        defer { _ = try? Self.sh(ShellQuote.command(tmux) + " kill-server") }
        let screens = [
            // As captured from Claude Code 2.1.31x after an API error: a sent
            // message in the history (grey background), the error, then the
            // input line, whose prompt is padded with a no-break space.
            "claude-empty": #"printf '\033[38;5;246m\033[48;5;237m❯ \033[38;5;231mcontinue\033[39m\n\033[38;5;220m●\033[39m API Error\n\033[39m❯\302\240\n'"#,
            "claude-empty-ascii": #"printf '\033[39m❯ \n'"#,
            "claude-suggestion": #"printf '\033[39m❯\302\240\033[2mwrite the tests next\033[0m\n'"#,
            "codex-placeholder": #"printf '\033[1m›\033[0m\033[48;2;30;30;30m \033[2mExplain this codebase\033[0m\033[48;2;30;30;30m\n'"#,
            "claude-draft": #"printf '\033[39m❯\302\240half a sentence\n'"#,
            "claude-draft-ascii": #"printf '\033[39m❯ half a sentence\n'"#,
            "codex-draft": #"printf '\033[1m›\033[0m\033[48;2;30;30;30m fix the build\033[0m\n'"#,
        ]
        var panes: [String: String] = [:]
        for (name, show) in screens {
            // `exec sleep` leaves a non-shell program in front, as an agent would be.
            let command = ShellQuote.word(show + "; exec sleep 60")
            let pane = try Self.sh(ShellQuote.command(tmux) + " new-session -d -P -F '#{pane_id}' -s \(name) -x 80 -y 24 \(command)")
            panes[name] = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        Thread.sleep(forTimeInterval: 0.5)
        func outcome(_ name: String) throws -> AgentNudge.Outcome? {
            let script = try #require(AgentNudge.script("continue", paneID: panes[name]!, quietSeconds: 30, tmux: tmux))
            return try? AgentNudge.parse(Self.sh(script, remote: true)).get()
        }
        #expect(try outcome("claude-empty") == .sent)
        #expect(try outcome("claude-empty-ascii") == .sent)
        #expect(try outcome("claude-suggestion") == .sent)
        #expect(try outcome("codex-placeholder") == .sent)
        #expect(try outcome("claude-draft") == .draft)
        #expect(try outcome("claude-draft-ascii") == .draft)
        #expect(try outcome("codex-draft") == .draft)
    }

    /// `remote` runs the script as `docker exec` does in the containers: no
    /// locale set, so the C locale (where `tr` takes no no-break space as
    /// space). The tmux server itself keeps the normal environment.
    private static func sh(_ script: String, remote: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        if remote {
            for key in environment.keys where key == "LANG" || key.hasPrefix("LC_") { environment[key] = nil }
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
