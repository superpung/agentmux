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
