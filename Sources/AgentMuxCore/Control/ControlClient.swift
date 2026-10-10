import Foundation

public enum ControlError: Error, Sendable, Equatable {
    case closed(String)
    case invalidCommand
    case tooManyPendingCommands
    case failed([String])
}

/// One tmux control-mode client (`tmux -C`) attached to a session over
/// `ssh -T` → `docker exec -i`, without a tty. tmux keeps no state for it
/// beyond the client itself: it never sets the window size
/// (`ignore-size`), and it leaves when its stdin closes, so a dropped
/// connection does not leave it behind.
///
/// Replies, pane output and notifications are all delivered on `queue` in
/// the order tmux wrote them.
public final class ControlClient: @unchecked Sendable {
    public let clientTag: String
    public let queue: DispatchQueue
    public static let maxPendingCommands = 512

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writeQueue: DispatchQueue

    // Confined to `queue`.
    private var parser = ControlParser()
    /// One entry per command line. tmux replies once per command in the
    /// line, and stops the line at the first error.
    private struct Waiting {
        var remaining: Int
        var replies: [ControlReply]
        var completion: @Sendable (Result<[ControlReply], ControlError>) -> Void
    }

    private var waiting: [Waiting] = []
    private var onEvent: (@Sendable (ControlEvent) -> Void)?
    private var finished = false
    private var stderrTail = Data()

    public init(
        host: HostConfig,
        target: TargetConfig,
        session: String,
        options: SSHOptions = SSHOptions(),
        pauseAfterSeconds: Int = 30
    ) throws {
        guard target.access.allowsAttach else {
            throw AttachError.targetIsObserveOnly(target.id)
        }
        guard TmuxQuote.id(session) != nil else {
            throw InvalidRemoteValue(field: "session", value: session)
        }
        let destination = try SSHDestination(host.sshDestination)
        let context = try target.executionContext()
        let tag = ClientRelease.makeTag()
        let remote = RemoteCommand.controlAttach(
            in: context, session: session, clientTag: tag, pauseAfterSeconds: pauseAfterSeconds
        )
        process.executableURL = URL(fileURLWithPath: RemoteCommand.sshExecutable)
        process.arguments = RemoteCommand.ssh(destination, options: options, allocateTTY: false, remote: remote)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        clientTag = tag
        queue = DispatchQueue(label: "agentmux.control.\(tag)")
        writeQueue = DispatchQueue(label: "agentmux.control.write.\(tag)")
    }

    /// Starts the connection. `onEvent` gets output, notifications and the
    /// final `.exit`, on `queue`.
    public func start(onEvent: @escaping @Sendable (ControlEvent) -> Void) throws {
        queue.sync { self.onEvent = onEvent }
        process.terminationHandler = { [weak self] process in
            self?.queue.async { self?.finish(reason: "exit \(process.terminationStatus)") }
        }
        try process.run()

        let reader = output.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let chunk = reader.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.queue.async { self.finish(reason: "connection closed") }
                    return
                }
                self.queue.async { self.consume(chunk) }
            }
        }
        let errorReader = errors.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let chunk = errorReader.availableData
                guard let self, !chunk.isEmpty else { return }
                self.queue.async {
                    self.stderrTail.append(chunk)
                    if self.stderrTail.count > 4096 { self.stderrTail = self.stderrTail.suffix(4096) }
                }
            }
        }
    }

    /// Sends one command; `completion` runs on `queue` when its reply
    /// arrives, in order with output events.
    public func send(_ command: String, completion: @escaping @Sendable (Result<ControlReply, ControlError>) -> Void) {
        send([command]) { result in completion(result.map { $0[0] }) }
    }

    /// Sends commands as one line. tmux runs a line as one unit, with no
    /// pane output processed in between; `completion` gets one reply per
    /// command, or the first error.
    public func send(_ commands: [String], completion: @escaping @Sendable (Result<[ControlReply], ControlError>) -> Void) {
        let command = commands.joined(separator: " ; ")
        guard !commands.isEmpty, !command.contains("\n"), !command.contains("\r") else {
            queue.async { completion(.failure(.invalidCommand)) }
            return
        }
        queue.async { [self] in
            if finished {
                completion(.failure(.closed(lastError)))
                return
            }
            guard waiting.count < Self.maxPendingCommands else {
                completion(.failure(.tooManyPendingCommands))
                return
            }
            waiting.append(Waiting(remaining: commands.count, replies: [], completion: completion))
            let line = Data((command + "\n").utf8)
            let handle = input.fileHandleForWriting
            writeQueue.async { try? handle.write(contentsOf: line) }
        }
    }

    public func send(_ command: String) async -> Result<ControlReply, ControlError> {
        await withCheckedContinuation { continuation in
            send(command) { continuation.resume(returning: $0) }
        }
    }

    /// Detaches this client and ends the connection. The session and its
    /// panes are untouched.
    public func close(grace: TimeInterval = 3) {
        send("detach-client") { _ in }
        writeQueue.async { [input] in try? input.fileHandleForWriting.close() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Queue-confined

    private var lastError: String {
        String(decoding: stderrTail, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? "connection closed"
    }

    private func consume(_ chunk: Data) {
        guard !finished else { return }
        let events: [ControlEvent]
        do {
            events = try parser.feed(chunk)
        } catch {
            finish(reason: "protocol error: \(error)")
            process.terminate()
            return
        }
        for event in events {
            switch event {
            case let .reply(reply):
                // The reply to the attach command itself is not ours.
                guard reply.fromThisClient, !waiting.isEmpty else { continue }
                if !reply.success {
                    waiting.removeFirst().completion(.failure(.failed(reply.textLines)))
                    continue
                }
                waiting[0].replies.append(reply)
                waiting[0].remaining -= 1
                if waiting[0].remaining == 0 {
                    let done = waiting.removeFirst()
                    done.completion(.success(done.replies))
                }
            case let .exit(reason):
                onEvent?(event)
                finish(reason: reason ?? "exit")
            default:
                onEvent?(event)
            }
        }
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        let detail = stderrTail.isEmpty ? reason : lastError
        for entry in waiting {
            entry.completion(.failure(.closed(detail)))
        }
        waiting.removeAll()
        onEvent?(.exit(reason: detail))
        onEvent = nil
    }
}
