import Foundation

/// Watches remote files for changes over one long-lived session, so a check
/// costs a `stat` in the container instead of a new ssh connection and
/// `docker exec` (measured on a host: about 0.3 s of its CPU each, and 0.1 s
/// of the Mac's).
///
/// The session is `ssh -T` → `docker exec -i` → `sh -c` running `script`,
/// which answers each request on its stdin with one stamp a path. It ends by
/// itself when its stdin closes (the watch was stopped, the app quit, the
/// connection dropped), and in any case after `lifetimeSeconds`: a process
/// started by `docker exec` outlives its client otherwise. Read-only.
public final class RemoteWatch: @unchecked Sendable {
    public static let lifetimeSeconds = 600
    /// A check not answered in this time ends the session.
    public static let replyTimeout: TimeInterval = 10

    /// A request is `?`, then one absolute path a line, then `.`. The reply
    /// is `@@stat <inode> <size> <modification time>` (or `@@stat -` for a
    /// path that can't be read) for each path, then `@@done`.
    static let script = """
    while IFS= read -r line; do
      [ "$line" = "?" ] || continue
      while IFS= read -r p && [ "$p" != . ]; do
        s=$(stat -c '%i %s %y' -- "$p" 2>/dev/null) || s=-
        printf '@@stat %s\\n' "$s"
      done
      printf '@@done\\n'
    done
    """

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "agentmux.watch")

    // Confined to `queue`.
    private var buffer = Data()
    private var stamps: [String?] = []
    private var waiting: (id: Int, count: Int, completion: @Sendable ([String?]?) -> Void)?
    private var nextID = 0
    private var finished = false

    public init(host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()) throws {
        let destination = try SSHDestination(host.sshDestination)
        let context = try target.executionContext()
        let remote = RemoteCommand.longLived(Self.script, in: context, lifetimeSeconds: Self.lifetimeSeconds)
        process.executableURL = URL(fileURLWithPath: RemoteCommand.sshExecutable)
        process.arguments = RemoteCommand.ssh(destination, options: options, allocateTTY: false, remote: remote)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// For tests: runs `script` in a local shell.
    init(localShell shell: String, environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", Self.script]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start() throws {
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.finish() }
        }
        // A write after the session ended fails instead of killing the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let reader = output.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let chunk = reader.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.queue.async { self.finish() }
                    return
                }
                self.queue.async { self.consume(chunk) }
            }
        }
    }

    /// Whether the session can still answer.
    public var isRunning: Bool { queue.sync { !finished } }

    /// The stamps of `paths` in order (inode, size and modification time;
    /// nil for a path that can't be read), or nil when the session has ended
    /// or another check is under way. Paths must be absolute.
    public func check(_ paths: [String]) async -> [String?]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finished, waiting == nil, !paths.isEmpty,
                      paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\r") }) else {
                    continuation.resume(returning: nil)
                    return
                }
                nextID += 1
                let id = nextID
                stamps = []
                waiting = (id, paths.count, { continuation.resume(returning: $0) })
                let request = Data(("?\n" + paths.joined(separator: "\n") + "\n.\n").utf8)
                do {
                    try input.fileHandleForWriting.write(contentsOf: request)
                } catch {
                    finish()
                    return
                }
                queue.asyncAfter(deadline: .now() + Self.replyTimeout) { [self] in
                    guard waiting?.id == id else { return }
                    finish()
                    process.terminate()
                }
            }
        }
    }

    /// Ends the session: closing its stdin ends the remote loop.
    public func stop() {
        queue.async { [self] in
            try? input.fileHandleForWriting.close()
            finish()
        }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Queue-confined

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix("@@stat ") {
                let stamp = String(line.dropFirst(7))
                stamps.append(stamp == "-" ? nil : stamp)
            } else if line == "@@done", let done = waiting {
                waiting = nil
                done.completion(stamps.count == done.count ? stamps : nil)
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiting
        waiting = nil
        pending?.completion(nil)
    }
}
