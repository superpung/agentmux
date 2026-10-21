@testable import AgentMuxCore
import Foundation
import Testing

@Suite struct ShellQuoteTests {
    @Test func plainWordsStayReadable() {
        #expect(ShellQuote.word("docker") == "docker")
        #expect(ShellQuote.word("/usr/bin/tmux") == "/usr/bin/tmux")
        #expect(ShellQuote.word("AGENTMUX_CLIENT=ab12") == "AGENTMUX_CLIENT=ab12")
    }

    @Test(arguments: [
        "", "a b", "$(reboot)", "`id`", "a;b", "a|b", "a&b", "x\ny", "it's", "\"q\"", "*", "~", "#{pane_id}", "$1", "你好",
    ])
    func specialWordsAreSingleQuoted(_ value: String) throws {
        let quoted = ShellQuote.word(value)
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        // Round trip through a real POSIX shell.
        let output = try runShell("printf '%s' \(quoted)")
        #expect(output == value)
    }

    @Test func commandRoundTripsEveryWord() throws {
        let argv = ["printf", "%s|", "a b", "c'd", "$(x)", "--", "-n"]
        let output = try runShell(ShellQuote.command(argv))
        #expect(output == "a b|c'd|$(x)|--|-n|")
    }

    private func runShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

@Suite struct RemoteValueTests {
    @Test(arguments: ["lab-host", "user@lab", "lab-host", "lab.example.com", "user@[::1]"])
    func acceptsDestinations(_ value: String) throws {
        #expect(try SSHDestination(value).value == value)
    }

    @Test(arguments: ["-oProxyCommand=x", "", "a b", "a;b", "a\nb", "$(x)", "`x`", "a'b"])
    func rejectsDestinations(_ value: String) {
        #expect(throws: InvalidRemoteValue.self) { try SSHDestination(value) }
    }

    @Test(arguments: ["-it", "a b", "a;rm", "x\n", "$(id)", "", "../x"])
    func rejectsContainers(_ value: String) {
        #expect(throws: InvalidRemoteValue.self) { try ContainerReference(value) }
    }

    @Test(arguments: ["root", "1000", "1000:1000", "worker:staff"])
    func acceptsExecUsers(_ value: String) throws {
        #expect(try ExecUser(value).value == value)
    }

    @Test(arguments: ["-u", "a b", "root;id", "$(id)"])
    func rejectsExecUsers(_ value: String) {
        #expect(throws: InvalidRemoteValue.self) { try ExecUser(value) }
    }

    @Test func socketValuesAreChecked() throws {
        #expect(throws: InvalidRemoteValue.self) { try TmuxInvocation(executable: nil, socket: .name("-x")) }
        #expect(throws: InvalidRemoteValue.self) { try TmuxInvocation(executable: nil, socket: .name("a/b")) }
        #expect(throws: InvalidRemoteValue.self) { try TmuxInvocation(executable: nil, socket: .path("relative")) }
        #expect(throws: InvalidRemoteValue.self) { try TmuxInvocation(executable: nil, socket: .path("/tmp/a\nb")) }
        #expect(throws: InvalidRemoteValue.self) { try TmuxInvocation(executable: "tmux", socket: .default) }
        let path = try TmuxInvocation(executable: "/usr/bin/tmux", socket: .path("/tmp/my sock;x"))
        #expect(path.argv == ["/usr/bin/tmux", "-u", "-S", "/tmp/my sock;x"])
    }
}

@Suite struct RemoteCommandTests {
    let context = try! ExecutionContext(
        container: DockerExec(container: ContainerReference("app01"), user: ExecUser("1000")),
        tmux: TmuxInvocation(executable: nil, socket: .name("agentmux-test"))
    )

    @Test func sshArgvIsNonInteractiveAndEndsOptions() throws {
        let argv = try RemoteCommand.ssh(SSHDestination("lab"), options: SSHOptions(), allocateTTY: false, remote: "true")
        #expect(argv.first == "-T")
        #expect(argv.contains("BatchMode=yes"))
        #expect(!argv.contains { $0.hasPrefix("StrictHostKeyChecking") })
        #expect(Array(argv.suffix(3)) == ["--", "lab", "true"])
    }

    @Test func controlPathIsOnlyUsedNeverStarted() throws {
        let argv = try RemoteCommand.ssh(
            SSHDestination("lab"), options: SSHOptions(controlPath: "/tmp/cm-%C"), allocateTTY: true, remote: "x"
        )
        #expect(argv.first == "-tt")
        #expect(argv.contains("ControlMaster=no"))
        #expect(argv.contains("ControlPath=/tmp/cm-%C"))
        #expect(!argv.contains { $0.hasPrefix("ControlPersist") })
    }

    @Test func scriptInspectsThenExecsWithoutTTY() {
        let remote = RemoteCommand.script(in: context, timeoutSeconds: 20)
        #expect(remote.hasPrefix("docker inspect --type container --format "))
        #expect(remote.contains(" && docker exec -i --user 1000 app01 sh -c "))
        #expect(!remote.contains("-it"))
        #expect(remote.contains("exec timeout 20 sh -s"))
    }

    @Test func attachNeverStealsAndTagsTheClient() {
        let remote = RemoteCommand.attach(in: context, target: "$3", clientTag: "abc123")
        #expect(remote.contains("docker exec -it --user 1000 -e AGENTMUX_CLIENT=abc123 -e TERM=xterm-256color app01"))
        #expect(remote.contains("tmux -u -L agentmux-test attach-session -E -f ignore-size,active-pane -t '$3'"))
        #expect(!remote.contains(" -d"))
    }
}

@Suite(.serialized) struct ClientReleaseTests {
    private let tmux = try! TmuxInvocation(executable: nil, socket: .name("agentmux-test"))

    /// With no owner prefix set, the sweep keeps its legacy reach: every
    /// AgentMux-tagged client except `keeping`, the gate disabled.
    @Test func withoutOwnerReleasesEveryTaggedClient() {
        let saved = ClientRelease.ownerPrefix
        defer { ClientRelease.ownerPrefix = saved }
        ClientRelease.ownerPrefix = ""
        let script = ClientRelease.script(tmux: tmux, tags: [], keeping: ["abc1"])
        #expect(script.contains("owner=''"))
        #expect(script.contains("[ -z \"$owner\" ] || case \"$tag\" in \"$owner\"*)"))
        #expect(!ClientRelease.makeTag().isEmpty)
    }

    /// With an owner prefix set, tags carry it and the sweep only touches tags
    /// that start with it, so another install's clients are skipped.
    @Test func withOwnerScopesTheSweepAndTags() {
        let saved = ClientRelease.ownerPrefix
        defer { ClientRelease.ownerPrefix = saved }
        ClientRelease.ownerPrefix = "deadbeef0001"
        #expect(ClientRelease.makeTag().hasPrefix("deadbeef0001"))
        let script = ClientRelease.script(tmux: tmux, tags: [], keeping: [])
        #expect(script.contains("owner='deadbeef0001'"))
        // The gate continues (skips) any tag that does not start with owner.
        #expect(script.contains("*) continue ;; esac"))
    }
}

@Suite struct RemoteFailureTests {
    private func failed(_ stderr: String, status: Int32 = 255) -> CommandResult {
        CommandResult(exitStatus: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false, stdoutTruncated: false, stderrTruncated: false)
    }

    @Test(arguments: [
        ("user@lab: Permission denied (publickey).", RemoteFailureKind.sshAuthRequired),
        ("Host key verification failed.", .sshHostKey),
        ("ssh: Could not resolve hostname lab: nodename nor servname provided", .hostUnreachable),
        ("ssh: connect to host 10.0.0.1 port 22: Operation timed out", .hostUnreachable),
        ("permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock", .dockerPermissionDenied),
        ("Error: No such object: app09", .containerNotFound),
        ("Error response from daemon: container abc is not running", .containerNotRunning),
        ("unable to find user nobody2: no matching entries in passwd file", .execUserInvalid),
        ("something else", .remoteCommandFailed),
    ])
    func classifiesStderr(_ sample: (String, RemoteFailureKind)) {
        #expect(RemoteFailure.classify(failed(sample.0))?.kind == sample.1)
    }

    @Test func successAndTimeouts() {
        #expect(RemoteFailure.classify(failed("", status: 0)) == nil)
        var timedOut = failed("")
        timedOut.timedOut = true
        #expect(RemoteFailure.classify(timedOut)?.kind == .commandTimeout)
    }

    @Test func tmuxServerErrorsAreDistinguished() {
        #expect(RemoteFailure.classifyTmuxServerError("no server running on /tmp/tmux-0/default").kind == .noTmuxServer)
        #expect(RemoteFailure.classifyTmuxServerError("error connecting to /tmp/tmux-1000/default (Permission denied)").kind == .tmuxSocketUnavailable)
        #expect(RemoteFailure.classifyTmuxServerError("error connecting to /tmp/x (No such file or directory)").kind == .noTmuxServer)
    }

    @Test func detailDropsControlCharacters() {
        #expect(RemoteFailure(.remoteCommandFailed, detail: "a\u{1B}[31mb\u{7}").detail == "a[31mb")
    }
}

@Suite struct CommandRunnerTests {
    @Test func capturesOutputAndStatus() async throws {
        let result = try await CommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "cat; echo err >&2; exit 3"],
            stdin: Data("hello".utf8), timeout: .seconds(5)
        )
        #expect(result.exitStatus == 3)
        #expect(result.stdoutText == "hello")
        #expect(result.stderrText == "err\n")
        #expect(!result.timedOut)
    }

    @Test func timesOut() async throws {
        let result = try await CommandRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(200))
        #expect(result.timedOut)
    }

    @Test func boundsOutput() async throws {
        let result = try await CommandRunner.run(
            executable: "/usr/bin/yes", arguments: [], timeout: .seconds(5), stdoutLimit: 1000
        )
        #expect(result.stdoutTruncated)
        #expect(result.stdout.count == 1000)
    }
}
