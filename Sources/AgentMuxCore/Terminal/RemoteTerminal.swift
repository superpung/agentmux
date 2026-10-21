import Foundation

public enum AttachError: Error, Equatable {
    /// `observe` targets are never attached to.
    case targetIsObserveOnly(String)
}

/// One local view attached to an existing tmux target over
/// `ssh -tt` → `docker exec -it` → `tmux attach-session`.
///
/// Closing the view never sends input. It releases this view's own tmux
/// client, found by its tag, and hangs up the local ssh. Ending ssh alone is
/// not enough: Docker keeps processes started by `docker exec` alive after
/// the client disconnects, which would leave the tmux client behind.
public final class RemoteTerminal: @unchecked Sendable {
    public let clientTag: String
    public let tmuxTarget: String
    private let host: HostConfig
    private let context: ExecutionContext
    private let options: SSHOptions
    private let process: PTYProcess

    public init(
        host: HostConfig,
        target: TargetConfig,
        tmuxTarget: String,
        options: SSHOptions = SSHOptions(),
        columns: UInt16,
        rows: UInt16
    ) throws {
        guard target.access.allowsAttach else {
            throw AttachError.targetIsObserveOnly(target.id)
        }
        let destination = try SSHDestination(host.sshDestination)
        let context = try target.executionContext()
        let tag = ClientRelease.makeTag()
        let remote = RemoteCommand.attach(in: context, target: tmuxTarget, clientTag: tag)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }

        process = try PTYProcess(
            executable: RemoteCommand.sshExecutable,
            arguments: RemoteCommand.ssh(destination, options: options, allocateTTY: true, remote: remote),
            environment: environment,
            columns: columns,
            rows: rows
        )
        self.host = host
        self.context = context
        self.options = options
        self.clientTag = tag
        self.tmuxTarget = tmuxTarget
    }

    public func start(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (PTYProcess.Termination) -> Void
    ) {
        process.start(onOutput: onOutput, onExit: onExit)
    }

    public func write(_ data: Data) {
        process.write(data)
    }

    public func resize(columns: UInt16, rows: UInt16) {
        process.resize(columns: columns, rows: rows)
    }

    /// Ends only the local ssh, e.g. when the host cannot be reached. The
    /// remote tmux client stays until a later `ClientRelease` sweep.
    public func hangUpLocally() {
        process.hangUp()
    }

    /// Releases this view's tmux client remotely, then hangs up locally.
    /// Returns how many clients were released (normally 1).
    @discardableResult
    public func close() async -> Result<Int, RemoteFailure> {
        let released = await ClientRelease.release(host: host, context: context, options: options, tags: [clientTag])
        process.hangUp()
        return released
    }
}

/// Finds tmux clients started by AgentMux through their environment tag and
/// sends SIGHUP to exactly those processes. tmux treats it as a lost
/// terminal: the client leaves, the session and its panes are untouched.
/// Lookup by client name is avoided on purpose: tmux 3.4 was seen resolving
/// a stale client's tty name to a different, active client.
public enum ClientRelease {
    /// A stable per-install id, set once at launch, prefixed onto every tag
    /// this install creates. It scopes the orphan sweep (and the grouped-session
    /// reaper that keys off the tag) to this install's own clients, so a second
    /// AgentMux on another machine sharing the same tmux server never releases
    /// clients it did not start — nor we theirs. Empty means no scoping (a lone
    /// install, or core used directly): the sweep then matches every
    /// AgentMux-tagged client, exactly as before. Written once before any view
    /// opens, read-only thereafter.
    nonisolated(unsafe) public static var ownerPrefix: String = ""

    static func makeTag() -> String {
        ownerPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// `tags` empty means every AgentMux-tagged client except `keeping`
    /// (orphans from a crash or a lost connection); when `ownerPrefix` is set,
    /// the match is further limited to tags this install created, so another
    /// install's live clients are left alone.
    static func script(tmux: TmuxInvocation, tags: [String], keeping: [String] = []) -> String {
        precondition((tags + keeping + [ownerPrefix]).allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        let binary = ShellQuote.word(tmux.executable ?? "tmux")
        let flags = ShellQuote.command(Array(tmux.argv.dropFirst()))
        let variable = RemoteCommand.clientTagVariable
        return """
        tm() { \(binary) \(flags) "$@"; }
        wanted=' \(tags.joined(separator: " ")) '
        keep=' \(keeping.joined(separator: " ")) '
        owner='\(ownerPrefix)'
        n=0
        for pid in $(tm list-clients -F '#{client_pid}' 2>/dev/null); do
          tag=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^\(variable)=//p' | head -n 1)
          [ -n "$tag" ] || continue
          case "$keep" in *" $tag "*) continue ;; esac
          [ -z "$owner" ] || case "$tag" in "$owner"*) ;; *) continue ;; esac
          if [ "$wanted" = '  ' ] || case "$wanted" in *" $tag "*) true ;; *) false ;; esac; then
            kill -HUP "$pid" 2>/dev/null && n=$((n+1))
          fi
        done
        echo "@@released $n"

        """
    }

    public static func release(
        host: HostConfig,
        context: ExecutionContext,
        options: SSHOptions,
        tags: [String],
        keeping: [String] = []
    ) async -> Result<Int, RemoteFailure> {
        guard let destination = try? SSHDestination(host.sshDestination) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid destination"))
        }
        let output = await RemoteScript.run(
            script(tmux: context.tmux, tags: tags, keeping: keeping),
            destination: destination, context: context, options: options, timeoutSeconds: 10
        )
        return output.flatMap { text in
            let count = text.split(separator: "\n")
                .compactMap { $0.hasPrefix("@@released ") ? Int($0.dropFirst("@@released ".count)) : nil }
                .last
            return count.map { .success($0) } ?? .failure(RemoteFailure(.protocolDesync, detail: "no release count"))
        }
    }
}
