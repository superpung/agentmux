import Foundation

/// Options for the system `/usr/bin/ssh`. Everything is passed on the
/// command line; the user's ssh config is read by ssh as usual and never
/// written.
public struct SSHOptions: Sendable, Equatable {
    public var connectTimeoutSeconds = 10
    public var serverAliveIntervalSeconds = 15
    public var serverAliveCountMax = 3
    /// Control socket of an app-managed master connection, or nil. Commands
    /// only use it (`ControlMaster=no`, falling back to a direct connection
    /// when it is absent); they never start a persistent master themselves,
    /// because a backgrounded master keeps the caller's pipes open. The
    /// user's own master connections are never used or closed.
    public var controlPath: String?

    public init(controlPath: String? = nil) {
        self.controlPath = controlPath
    }
}

/// Builds argv for `/usr/bin/ssh` and the remote command strings that run in
/// an `ExecutionContext`. The remote side parses the command with a shell,
/// so every word is quoted with `ShellQuote`.
public enum RemoteCommand {
    public static let sshExecutable = "/usr/bin/ssh"

    /// Name of the environment variable that tags tmux clients started by
    /// AgentMux, so they can be found and detached precisely later.
    public static let clientTagVariable = "AGENTMUX_CLIENT"

    public static func ssh(
        _ destination: SSHDestination,
        options: SSHOptions,
        allocateTTY: Bool,
        remote: String
    ) -> [String] {
        var argv = [allocateTTY ? "-tt" : "-T"]
        argv += ["-o", "BatchMode=yes"]
        argv += ["-o", "ConnectTimeout=\(options.connectTimeoutSeconds)"]
        argv += ["-o", "ServerAliveInterval=\(options.serverAliveIntervalSeconds)"]
        argv += ["-o", "ServerAliveCountMax=\(options.serverAliveCountMax)"]
        if let controlPath = options.controlPath {
            argv += ["-o", "ControlMaster=no"]
            argv += ["-o", "ControlPath=\(controlPath)"]
        }
        argv += ["--", destination.value, remote]
        return argv
    }

    /// Runs a `sh` script fed on stdin inside the context, without a tty.
    /// For a container, `docker inspect` runs first on the host and prints
    /// one `@@container` line, so every result carries the container's
    /// identity. The script is time-limited inside the target too, because
    /// ending the local ssh does not stop a process started by `docker exec`.
    public static func script(in context: ExecutionContext, timeoutSeconds: Int) -> String {
        let shell = "if command -v timeout >/dev/null 2>&1; then exec timeout \(timeoutSeconds) sh -s; else exec sh -s; fi"
        let runner = ["sh", "-c", shell]
        guard let docker = context.container else {
            return ShellQuote.command(runner)
        }
        let inspect = [
            "docker", "inspect", "--type", "container",
            "--format", "@@container {{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.State.Pid}}",
            docker.container.value,
        ]
        return ShellQuote.command(inspect) + " && " + ShellQuote.command(dockerExec(docker, interactiveTTY: false, environment: [:]) + runner)
    }

    /// Attaches a new tmux client to an existing target, with a tty.
    /// `ignore-size` keeps this client out of window-size decisions and `-E`
    /// keeps attach from updating the session environment. Never `-d`.
    public static func attach(
        in context: ExecutionContext,
        target: String,
        clientTag: String
    ) -> String {
        let tmux = context.tmux.argv + ["attach-session", "-E", "-f", "ignore-size,active-pane", "-t", target]
        guard let docker = context.container else {
            return ShellQuote.command(["env", "\(clientTagVariable)=\(clientTag)", "TERM=xterm-256color"] + tmux)
        }
        let environment = [clientTagVariable: clientTag, "TERM": "xterm-256color"]
        return ShellQuote.command(dockerExec(docker, interactiveTTY: true, environment: environment) + tmux)
    }

    /// Session name prefix for the per-view grouped sessions AgentMux creates.
    public static let groupedSessionPrefix = "agentmux-"

    public static func groupedSessionName(clientTag: String) -> String {
        "\(groupedSessionPrefix)\(clientTag)"
    }

    /// A tmux control-mode client, without a tty, attached to a new session
    /// *grouped* with `session`. A grouped session shares `session`'s windows
    /// but has its own current window and size, so the view can focus and
    /// size the agent's window without touching the user's other clients. The
    /// mirror sets `destroy-unattached` so the grouped session is removed when
    /// the client leaves (or the app dies and its stdin closes). `pause-after`
    /// makes tmux pause a pane instead of buffering without bound.
    public static func controlAttach(
        in context: ExecutionContext,
        session: String,
        clientTag: String,
        pauseAfterSeconds: Int
    ) -> String {
        let tmux = context.tmux.argv + [
            "-C", "new-session", "-s", groupedSessionName(clientTag: clientTag),
            "-t", session, "-f", "pause-after=\(pauseAfterSeconds)",
        ]
        guard let docker = context.container else {
            return ShellQuote.command(["env", "\(clientTagVariable)=\(clientTag)"] + tmux)
        }
        return ShellQuote.command(dockerExec(docker, interactiveTTY: false, environment: [clientTagVariable: clientTag]) + tmux)
    }

    /// An interactive shell in the context, with a tty, and NOT inside tmux. For
    /// a container it is `docker exec -it <c> <shell>`; on a bare host it is just
    /// the shell. The shell lives only as long as this ssh connection, so closing
    /// the view ends it and leaves no tmux state behind.
    public static func shell(in context: ExecutionContext, environment: [String: String] = [:]) -> String {
        let env = environment.merging(["TERM": "xterm-256color"]) { current, _ in current }
        // Default to a UTF-8 locale when the container sets none (a bare shell
        // often has LANG unset / charmap ASCII, so CJK and other non-ASCII text
        // renders as "?"). Only fills in when unset, so a configured locale wins.
        let command = ["sh", "-c", ": \"${LANG:=C.UTF-8}\"; : \"${LC_CTYPE:=$LANG}\"; export LANG LC_CTYPE; if command -v bash >/dev/null 2>&1; then exec bash -i; else exec sh -i; fi"]
        guard let docker = context.container else {
            let envArgs = ["env"] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return ShellQuote.command(envArgs + command)
        }
        return ShellQuote.command(dockerExec(docker, interactiveTTY: true, environment: env) + command)
    }

    /// Runs `script` with `sh -c` in the context, leaving its stdin to the
    /// script's own input, for at most `lifetimeSeconds` where `timeout`
    /// exists. No `docker inspect` first: a long-lived session needs no
    /// identity line.
    public static func longLived(_ script: String, in context: ExecutionContext, lifetimeSeconds: Int) -> String {
        let runner = [
            "sh", "-c",
            "if command -v timeout >/dev/null 2>&1; then exec timeout \(lifetimeSeconds) sh -c \"$1\"; else exec sh -c \"$1\"; fi",
            "sh", script,
        ]
        guard let docker = context.container else { return ShellQuote.command(runner) }
        return ShellQuote.command(dockerExec(docker, interactiveTTY: false, environment: [:]) + runner)
    }

    static func dockerExec(_ docker: DockerExec, interactiveTTY: Bool, environment: [String: String]) -> [String] {
        var argv = ["docker", "exec", interactiveTTY ? "-it" : "-i"]
        if let user = docker.user {
            argv += ["--user", user.value]
        }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            argv += ["-e", "\(key)=\(value)"]
        }
        argv.append(docker.container.value)
        return argv
    }
}
