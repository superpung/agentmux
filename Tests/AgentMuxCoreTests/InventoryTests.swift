@testable import AgentMuxCore
import Foundation
import Testing

/// Probe output shaped like a real run against tmux 3.4 in a container.
/// Values are synthetic; the shapes match what the server returned.
private let nonce = "n0nce"
private let fixture = """
@@container 1b682cd735783f8079d4e93a70176f4d410dbc3a7ec97a702470acec02c4a9db running 2026-07-29T09:45:06.043890362Z 6960
@@begin 1 n0nce
@@uid 0
@@tmux tmux 3.4
@@server 2060241 1785653975 /tmp/tmux-0/default
@@section memberships
$1 @2 %2 0 0 1 1
$1 @3 %3 1 0 1 0
$2 @26 %26 0 0 1 1
$2 @27 %27 1 0 1 0
$2 @28 %28 2 0 1 0
$4 @26 %26 0 0 1 1
@@section panes
%2 244753 0 159 43
%3 605811 0 159 43
%26 1321025 0 159 43
%27 2948506 0 159 43
%28 300845 0 159 43
%26 1321025 0 159 43
@@section session_name
$1 ra
$2 sva work
$4 grouped 中文 "x"
@@section window_name
@2 codex
@3 bash
@26 claude
@27 codex
@28 vim
@26 claude
@@section pane_current_command
%2 bash
%3 bash
%26 claude
%27 codex
%28 vim
@@section pane_current_path
%2 /srv/app/proj a
%3 /srv/app/proj-b
%26 /data/sva
%27 /data/sva
%28 /data/sva
@@section pane_title
%2 @@end n0n
%3 host
%26 ✳ Claude Code
%27 title_with_tab
%28 notes
@@section processes
%2 0 244753 244700 Ss bash
%2 1 636529 244753 Sl+ node
%2 2 644768 636529 Sl codex-code-mode
%3 0 605811 605800 Ss+ bash
%26 0 1321025 1321000 Ss bash
%26 1 2498245 1321025 Sl+ claude
%27 0 2948506 2948500 Ss bash
%27 1 2182058 2948506 Sl+ codex
%27 2 3000001 2182058 Sl claude
%27 2 2679180 2182058 Z codex
%28 0 300845 300800 Ss bash
%28 1 300900 300845 S+ vim
@@section agents
@@agent 636529
exe /usr/bin/node
arg node
arg /usr/lib/node_modules/@openai/codex/bin/codex.js
env TMUX_PANE=%2
start 123
@@agent 2498245
exe /root/.local/share/claude/versions/2.1.288 (deleted)
arg claude
arg --resume
env CLAUDE_CONFIG_DIR=/root/.claude-3
env TMUX_PANE=%26
start 456
@@agent 2182058
exe /root/.codex/packages/standalone/releases/0.160.1-x86_64-unknown-linux-musl/bin/codex
arg codex
arg resume
env CODEX_HOME=/root/.codex-2
env TMUX_PANE=%27
start 789
@@agent 3000001
exe /root/.local/share/claude/versions/2.1.293
arg claude
arg -p
@@section screens
@@screenstate %26 working
@@screenstate %bad notanid
@@end n0nce
"""

@Suite struct InventoryProbeTests {
    @Test func parsesStructure() throws {
        let snapshot = try InventoryProbe.parse(fixture, nonce: nonce)
        #expect(snapshot.container?.id.hasPrefix("1b682cd73578") == true)
        #expect(snapshot.container?.pid == 6960)
        #expect(snapshot.uid == 0)
        #expect(snapshot.tmuxVersion == "tmux 3.4")
        #expect(snapshot.server == .init(pid: 2060241, startTime: 1785653975, socketPath: "/tmp/tmux-0/default"))
        #expect(snapshot.sessions.map(\.id) == ["$1", "$2", "$4"])
        #expect(snapshot.panes.map(\.id) == ["%2", "%3", "%26", "%27", "%28"])
    }

    @Test func linkedWindowPaneIsOnePaneWithTwoMemberships() throws {
        let snapshot = try InventoryProbe.parse(fixture, nonce: nonce)
        #expect(snapshot.panes.filter { $0.id == "%26" }.count == 1)
        #expect(snapshot.memberships.filter { $0.paneID == "%26" }.map(\.sessionID) == ["$2", "$4"])
    }

    @Test func untrustedTextIsKeptVerbatim() throws {
        let snapshot = try InventoryProbe.parse(fixture, nonce: nonce)
        #expect(snapshot.sessions.first { $0.id == "$2" }?.name == "sva work")
        #expect(snapshot.sessions.first { $0.id == "$4" }?.name == "grouped 中文 \"x\"")
        #expect(snapshot.pane("%2")?.currentPath == "/srv/app/proj a")
        // A title that looks like a marker is just text.
        #expect(snapshot.pane("%2")?.title == "@@end n0n")
        #expect(snapshot.pane("%26")?.title == "✳ Claude Code")
    }

    @Test func outputBeforeBeginIsADesync() {
        let polluted = "Welcome to Ubuntu\n" + fixture
        #expect(throws: RemoteFailure.self) { try InventoryProbe.parse(polluted, nonce: nonce) }
    }

    @Test func missingEndIsADesync() {
        let truncated = fixture.replacingOccurrences(of: "@@end n0nce", with: "")
        #expect(throws: RemoteFailure(.protocolDesync, detail: "probe output ended early")) {
            try InventoryProbe.parse(truncated, nonce: nonce)
        }
    }

    @Test func wrongNonceIsNotTheEnd() {
        #expect(throws: RemoteFailure.self) { try InventoryProbe.parse(fixture, nonce: "other") }
    }

    @Test func tmuxProblemsAreReportedNotEmpty() throws {
        let noServer = "@@begin 1 n0nce\n@@uid 1000\n@@tmux tmux 3.4\n@@error tmux-server no server running on /tmp/tmux-1000/default\n@@end n0nce\n"
        #expect(try InventoryProbe.parse(noServer, nonce: nonce).failure?.kind == .noTmuxServer)
        let noTmux = "@@begin 1 n0nce\n@@uid 0\n@@error tmux-not-found\n@@end n0nce\n"
        #expect(try InventoryProbe.parse(noTmux, nonce: nonce).failure?.kind == .tmuxNotFound)
    }

    @Test func parsesScreenStates() throws {
        let snapshot = try InventoryProbe.parse(fixture, nonce: nonce)
        #expect(snapshot.screenStates["%26"] == "working")
        #expect(snapshot.screenStates["%bad"] == nil) // not a valid pane id
    }

    @Test func malformedRowsAreIgnored() throws {
        let odd = fixture.replacingOccurrences(of: "@@section panes\n", with: "@@section panes\nnot a row\n%x 1 0 1 1\n")
        #expect(try InventoryProbe.parse(odd, nonce: nonce).panes.count == 5)
    }
}

@Suite struct AgentDetectorTests {
    let detections = AgentDetector.detect(try! InventoryProbe.parse(fixture, nonce: "n0nce"))

    @Test func agentBehindShellAndNodeIsFound() {
        // T-08: the pane shows bash; node runs the Codex entry point.
        let codex = detections["%2"]
        #expect(codex?.kind == .codex)
        #expect(codex?.pid == 636529)
        #expect(codex?.confidence == .high)
    }

    @Test func versionAndConfigDirectory() {
        let claude = detections["%26"]
        #expect(claude?.kind == .claudeCode)
        #expect(claude?.version == "2.1.288")
        #expect(claude?.configDirectory == "/root/.claude-3")
        let codex = detections["%27"]
        #expect(codex?.version == "0.160.1")
        #expect(codex?.configDirectory == "/root/.codex-2")
    }

    @Test func childAgentWithoutPaneIsAChildNotAPane() {
        // T-23: claude -p under codex; the zombie codex child is ignored.
        #expect(detections["%27"]?.children == [.init(kind: .claudeCode, pid: 3000001)])
    }

    @Test func plainShellIsNotAnAgent() {
        // T-09: nothing runs in the shell, whatever its history says.
        #expect(detections["%3"]?.kind == AgentKind.none)
    }

    @Test func editingAFileNamedAfterAnAgentIsNotAnAgent() {
        // T-10: `vim codex_notes.md`.
        #expect(detections["%28"]?.kind == AgentKind.none)
    }

    @Test func helpersAreNotAgents() {
        let node = InventorySnapshot.ProcessNode(paneID: "%1", depth: 1, pid: 9, ppid: 1, state: "Sl", command: "claude")
        let daemon = InventorySnapshot.AgentEvidence(
            pid: 9, executable: "/root/.local/bin/claude", arguments: ["claude", "daemon"], environment: [:], startTicks: nil
        )
        #expect(AgentDetector.classify(node: node, evidence: daemon) == nil)
    }

    @Test func mismatchedPaneEnvironmentLowersConfidence() throws {
        let moved = fixture.replacingOccurrences(of: "env TMUX_PANE=%27", with: "env TMUX_PANE=%99")
        let detection = AgentDetector.detect(try InventoryProbe.parse(moved, nonce: "n0nce"))["%27"]
        #expect(detection?.kind == .codex)
        #expect(detection?.confidence == .medium)
    }

    @Test func withoutProcessTableOnlyTheCommandNameIsUsed() {
        let pane = InventorySnapshot.Pane(id: "%5", pid: 1, dead: false, width: 80, height: 24, currentCommand: "claude", currentPath: "/", title: "")
        let detection = AgentDetector.detect(pane: pane, processes: [], agents: [:], processTableAvailable: false)
        #expect(detection.kind == .claudeCode)
        #expect(detection.confidence == .low)
        let shell = InventorySnapshot.Pane(id: "%6", pid: 1, dead: false, width: 80, height: 24, currentCommand: "bash", currentPath: "/", title: "")
        #expect(AgentDetector.detect(pane: shell, processes: [], agents: [:], processTableAvailable: false).kind == .unknown)
    }

    @Test func versionParsing() {
        #expect(AgentDetector.codexVersion("/root/.codex/packages/standalone/releases/0.144.2-x86_64-unknown-linux-musl/bin/codex") == "0.144.2")
        #expect(AgentDetector.claudeVersion("/root/.local/share/claude/versions/2.1.288 (deleted)".replacingOccurrences(of: " (deleted)", with: "")) == "2.1.288")
        #expect(AgentDetector.codexVersion("/usr/bin/codex") == nil)
    }
}

@Suite struct TargetsConfigTests {
    @Test func loadsJSON5WithComments() throws {
        let text = """
        // comment
        {
          schemaVersion: 1,
          hosts: [{ id: "lab", displayName: "Lab", sshDestination: "lab-host", usualCommand: "" }],
          targets: [
            { id: "a", hostId: "lab", kind: "docker", container: "c1", execUser: "", tmuxPath: "",
              tmuxSocket: { mode: "default" }, access: "observe", agentProfiles: [], notes: "" },
          ],
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-\(UUID().uuidString).json5")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = try TargetsConfig.load(from: url)
        #expect(config.targets.first?.access == .observe)
        let context = try config.targets[0].executionContext()
        #expect(context.container?.container.value == "c1")
        #expect(context.container?.user == nil)
        #expect(context.tmux.argv == ["tmux", "-u"])
    }

    @Test func rejectsUnsafeValues() {
        var target = TargetConfig(
            id: "a", hostId: "lab", kind: .docker, container: "c1;rm -rf /", execUser: nil, tmuxPath: nil,
            tmuxSocket: .init(mode: .default, value: nil), access: .observe, agentProfiles: nil
        )
        #expect(throws: InvalidRemoteValue.self) { try target.executionContext() }
        target.container = nil
        #expect(throws: ConfigError.missingContainer(target: "a")) { try target.executionContext() }
    }

    @Test func discoveredTargetIsInteractive() throws {
        let host = HostConfig(id: "lab", displayName: "Lab", sshDestination: "lab-host")
        let target = TargetConfig.discovered(host: host, container: "app01")
        #expect(target.id == "lab/app01")
        #expect(target.hostId == "lab")
        #expect(target.kind == .docker)
        #expect(target.container == "app01")
        #expect(target.access == .interact)
        #expect(target.access.allowsAttach)
        let context = try target.executionContext()
        #expect(context.container?.container.value == "app01")
        #expect(context.container?.user == nil)
    }
}

@Suite struct AppSettingsTests {
    @Test func roundTripsThroughJSON() throws {
        let settings = AppSettings(
            hosts: [HostConfig(id: "lab", displayName: "Lab", sshDestination: "lab-host")],
            monitoredContainers: ["lab/app01", "lab/app02"]
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.save(to: url)
        let loaded = try AppSettings.load(from: url)
        #expect(loaded == settings)
    }

    @Test func normalizeDropsOrphansAndDuplicates() {
        var settings = AppSettings(
            hosts: [
                HostConfig(id: "lab", displayName: "Lab", sshDestination: "lab-host"),
                HostConfig(id: "lab", displayName: "Dupe", sshDestination: "205"),
            ],
            monitoredContainers: ["lab/a", "lab/a", "gone/b"]
        )
        settings.normalize()
        #expect(settings.hosts.map(\.id) == ["lab"])
        #expect(settings.monitoredContainers == ["lab/a"])
    }

    @Test func importsLegacyDockerTargets() throws {
        let text = """
        {
          schemaVersion: 1,
          hosts: [{ id: "lab", displayName: "Lab", sshDestination: "lab-host", usualCommand: "" }],
          targets: [
            { id: "a", hostId: "lab", kind: "docker", container: "app01", execUser: "", tmuxPath: "",
              tmuxSocket: { mode: "default" }, access: "interact", agentProfiles: [], notes: "" },
            { id: "a-test", hostId: "lab", kind: "docker", container: "app01", execUser: "", tmuxPath: "",
              tmuxSocket: { mode: "name", value: "agentmux-test" }, access: "test", agentProfiles: [], notes: "" },
          ],
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-\(UUID().uuidString).json5")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = try AppSettings.importLegacy(from: url)
        #expect(settings.hosts.map(\.id) == ["lab"])
        #expect(settings.hosts.first?.sshDestination == "lab-host")
        // Same container twice collapses to one monitored entry.
        #expect(settings.monitoredContainers == ["lab/app01"])
    }
}

@Suite struct DockerDiscoveryTests {
    @Test func parsesTabSeparatedRows() {
        let text = """
        abc123\tapp01\tubuntu:22.04\trunning\tUp 3 hours
        def456\tp01\talpine\texited\tExited (0) 2 days ago
        """
        let containers = DockerDiscovery.parse(text)
        #expect(containers.count == 2)
        #expect(containers[0].fullID == "abc123")
        #expect(containers[0].name == "app01")
        #expect(containers[0].image == "ubuntu:22.04")
        #expect(containers[0].running)
        #expect(containers[0].status == "Up 3 hours")
        #expect(!containers[1].running)
        #expect(containers[1].status == "Exited (0) 2 days ago")
    }

    @Test func skipsMalformedRows() {
        #expect(DockerDiscovery.parse("").isEmpty)
        #expect(DockerDiscovery.parse("abc\tonly\tthree\tfields").isEmpty)
    }
}

@Suite struct AgentTitleTests {
    @Test(arguments: [
        ("✳ demo-dev-v6", AgentKind.claudeCode, "demo-dev-v6"),
        ("⠂ Fix login bug", .claudeCode, "Fix login bug"),
        ("demo-dev-v5 | demo", .codex, "demo-dev-v5"),
        ("#42 fix", .claudeCode, "#42 fix"),
        ("ra-v2", .codex, "ra-v2"),
    ])
    func extractsTaskTitles(_ sample: (String, AgentKind, String)) {
        #expect(AgentTitle.from(paneTitle: sample.0, kind: sample.1) == sample.2)
    }

    @Test(arguments: ["", "Claude Code", "✳ Claude Code", "  "])
    func genericTitlesAreNil(_ title: String) {
        #expect(AgentTitle.from(paneTitle: title, kind: .claudeCode) == nil)
    }
}
