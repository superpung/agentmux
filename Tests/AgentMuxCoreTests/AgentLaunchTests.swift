@testable import AgentMuxCore
import Foundation
import Testing

@Suite struct AgentLaunchTests {
    @Test func claudeResumeCommand() {
        #expect(AgentCommand.launch(kind: .claudeCode, configDir: "/root/.claude-3", resumeID: "66ba23f4-4f35-4260-ba30-70301ef48caa")
            == "CLAUDE_CONFIG_DIR=/root/.claude-3 claude --resume 66ba23f4-4f35-4260-ba30-70301ef48caa")
    }

    @Test func claudeFreshCommand() {
        #expect(AgentCommand.launch(kind: .claudeCode, configDir: "/root/.claude", resumeID: nil)
            == "CLAUDE_CONFIG_DIR=/root/.claude claude")
    }

    @Test func codexResumeCommand() {
        #expect(AgentCommand.launch(kind: .codex, configDir: "/root/.codex-2", resumeID: "019d82a3-d2ff-7e23-99c5-26bbefad8afe")
            == #"if [ -x "$HOME/.local/lib/agentmux/bin/codex" ]; then CODEX_HOME=/root/.codex-2 "$HOME/.local/lib/agentmux/bin/codex" resume 019d82a3-d2ff-7e23-99c5-26bbefad8afe; else CODEX_HOME=/root/.codex-2 codex resume 019d82a3-d2ff-7e23-99c5-26bbefad8afe; fi"#)
    }

    @Test func configDirWithSpaceIsQuoted() {
        #expect(AgentCommand.launch(kind: .codex, configDir: "/root/my home", resumeID: nil)
            == "CODEX_HOME='/root/my home' codex")
    }

    @Test func unsafeResumeIDIsRejected() {
        #expect(AgentCommand.launch(kind: .claudeCode, configDir: "/root/.claude", resumeID: "x; rm -rf /") == nil)
        #expect(AgentCommand.launch(kind: .none, configDir: "/root/.claude", resumeID: nil) == nil)
    }

    @Test func safeTokenRules() {
        #expect(AgentCommand.isSafeToken("66ba23f4-4f35-4260-ba30-70301ef48caa"))
        #expect(AgentCommand.isSafeToken("my_session.name-1"))
        #expect(!AgentCommand.isSafeToken("x; rm"))
        #expect(!AgentCommand.isSafeToken("a b"))
        #expect(!AgentCommand.isSafeToken(""))
    }

    @Test func parsesConfigDirs() {
        let dirs = AgentSessionProbe.parseConfigDirs("claude /root/.claude\nclaude /root/.claude-3\ncodex /root/.codex-2\njunk line\n")
        #expect(dirs == [
            AgentConfigDir(kind: .claudeCode, path: "/root/.claude"),
            AgentConfigDir(kind: .claudeCode, path: "/root/.claude-3"),
            AgentConfigDir(kind: .codex, path: "/root/.codex-2"),
        ])
    }

    @Test func parsesOnlyValidCodexAccountIdentities() {
        #expect(AgentSessionProbe.parseCodexAccounts("/root/.codex|account-a\n/root/.codex-3|account-b\n/root/.codex-exp|\nrelative|account-c\njunk\n") == [
            .init(path: "/root/.codex", accountID: "account-a"),
            .init(path: "/root/.codex-3", accountID: "account-b"),
        ])
    }

    @Test func trailingUnconfiguredCodexDirectoryDoesNotDiscardValidAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [".codex", ".codex-3", ".codex-exp"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(name)/sessions"), withIntermediateDirectories: true)
        }
        // A deterministic jq stand-in: the regression concerns the shell's
        // final exit status, not JSON parsing or the user's real credentials.
        let jq = directory.appendingPathComponent("jq")
        try "#!/bin/sh\ncase \"$3\" in */.codex-exp/*) exit 2;; esac\nprintf 'fixture-account\\n'\n"
            .write(to: jq, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jq.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentSessionProbe.codexAccountScript]
        process.environment = ["HOME": directory.path, "PATH": directory.path + ":/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let accounts = AgentSessionProbe.parseCodexAccounts(String(decoding: output, as: UTF8.self))
        #expect(accounts.map(\.path) == [directory.appendingPathComponent(".codex").path, directory.appendingPathComponent(".codex-3").path])
    }

    @Test func parsesSessionsAndSkipsBadRows() {
        let out = """
        66ba23f4-4f35-4260-ba30-70301ef48caa|1700000000|42|/data/svagen-v3
        |1699990000|1|/data/x
        019d82a3-d2ff-7e23-99c5-26bbefad8afe|1699000000|7|
        """
        let sessions = AgentSessionProbe.parseSessions(out, kind: .codex, configDir: "/root/.codex")
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "66ba23f4-4f35-4260-ba30-70301ef48caa")
        #expect(sessions[0].cwd == "/data/svagen-v3")
        #expect(sessions[0].lastActiveEpoch == 1_700_000_000)
        #expect(sessions[0].eventCount == 42)
        // Empty cwd falls back to ~.
        #expect(sessions[1].cwd == "~")
    }

    @Test func linkGroupsShareAccountsByRealPath() {
        let out = """
        /root/.claude|-srv-app-demo|/root/.claude-2/projects/-srv-app-demo|/srv/app/demo|22|1792211040
        /root/.claude-2|-srv-app-demo|/root/.claude-2/projects/-srv-app-demo|/srv/app/demo|22|1792211040
        /root/.claude-3|-srv-app-demo|/root/.claude-2/projects/-srv-app-demo|/srv/app/demo|22|1792211040
        /root/.claude|-data-ra-ra-v2|/root/.claude/projects/-data-ra-ra-v2||0|0
        /root/.claude-2|-data-ra-ra-v2|/root/.claude-2/projects/-data-ra-ra-v2||0|0
        bad line without enough fields
        """
        let entries = AgentSessionProbe.parseProjectLinks(out)
        #expect(entries.count == 5) // bad line skipped
        let groups = AgentSessionProbe.linkGroups(from: entries)
        let shared = groups.filter(\.isShared)
        #expect(shared.count == 1)
        #expect(shared[0].cwd == "/srv/app/demo")
        #expect(shared[0].accounts == ["/root/.claude", "/root/.claude-2", "/root/.claude-3"])
        #expect(shared[0].sessionCount == 22)
        // The shared group sorts ahead of the independent ones.
        #expect(groups.first?.isShared == true)
        // ra-v2 is two separate real dirs, so neither is shared.
        #expect(groups.filter { $0.realPath.hasSuffix("ra-v2") }.allSatisfy { !$0.isShared })
    }
}
