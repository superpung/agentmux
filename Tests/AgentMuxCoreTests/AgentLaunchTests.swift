@testable import AgentMuxCore
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
            == "CODEX_HOME=/root/.codex-2 codex resume 019d82a3-d2ff-7e23-99c5-26bbefad8afe")
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
