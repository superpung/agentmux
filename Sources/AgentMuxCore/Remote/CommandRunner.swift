import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitStatus: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a local, non-interactive process (no pty) with a time limit and
/// bounded output. Used for every background query; terminals go through
/// `PTYProcess` instead.
public enum CommandRunner {
    /// How long to keep reading after the process exits, in case a grandchild
    /// still holds the pipes open.
    static let drainGrace: TimeInterval = 2

    public static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: Duration,
        stdoutLimit: Int = 4 << 20,
        stderrLimit: Int = 64 << 10
    ) async throws -> CommandResult {
        // Record what we're about to run remotely, including the piped script
        // (truncated), so a later crash can be traced to the exact command.
        let scriptPreview = stdin.map { String(decoding: $0.prefix(2000), as: UTF8.self) } ?? ""
        CommandLog.log("ssh", (executable as NSString).lastPathComponent,
                       (arguments.joined(separator: " ") + (scriptPreview.isEmpty ? "" : " <<< " + scriptPreview)))

        let run = Run(stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, any Error>) in
                let readers = DispatchGroup()
                startReader(outPipe.fileHandleForReading, group: readers, append: run.appendStdout)
                startReader(errPipe.fileHandleForReading, group: readers, append: run.appendStderr)

                process.terminationHandler = { process in
                    let status = process.terminationStatus
                    DispatchQueue.global().async {
                        _ = readers.wait(timeout: .now() + drainGrace)
                        continuation.resume(returning: run.result(exitStatus: status))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                run.setProcess(process)

                let writer = inPipe.fileHandleForWriting
                DispatchQueue.global().async {
                    if let stdin, !stdin.isEmpty {
                        try? writer.write(contentsOf: stdin)
                    }
                    try? writer.close()
                }

                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    run.timeOut()
                }
            }
        } onCancel: {
            run.terminate()
        }
    }

    private static func startReader(
        _ handle: FileHandle,
        group: DispatchGroup,
        append: @escaping @Sendable (Data) -> Void
    ) {
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                append(chunk)
            }
            group.leave()
        }
    }
}

/// Output accumulation and termination state for one run.
private final class Run: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutLimit: Int
    private let stderrLimit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var timedOut = false
    private var process: Process?
    private var finished = false

    init(stdoutLimit: Int, stderrLimit: Int) {
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
    }

    func setProcess(_ process: Process) {
        lock.withLock { self.process = process }
    }

    func appendStdout(_ data: Data) {
        let overflow = lock.withLock { Self.append(data, to: &stdout, limit: stdoutLimit, truncated: &stdoutTruncated) }
        if overflow { terminate() }
    }

    func appendStderr(_ data: Data) {
        _ = lock.withLock { Self.append(data, to: &stderr, limit: stderrLimit, truncated: &stderrTruncated) }
    }

    func timeOut() {
        let shouldTerminate = lock.withLock {
            guard !finished else { return false }
            timedOut = true
            return true
        }
        if shouldTerminate { terminate() }
    }

    /// SIGTERM, then SIGKILL after a grace period. Local process only.
    func terminate() {
        guard let process = lock.withLock({ finished ? nil : self.process }), process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func result(exitStatus: Int32) -> CommandResult {
        lock.withLock {
            finished = true
            return CommandResult(
                exitStatus: exitStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: timedOut,
                stdoutTruncated: stdoutTruncated,
                stderrTruncated: stderrTruncated
            )
        }
    }

    /// Returns true when the limit was just exceeded.
    private static func append(_ data: Data, to buffer: inout Data, limit: Int, truncated: inout Bool) -> Bool {
        guard !data.isEmpty, !truncated else { return false }
        let room = limit - buffer.count
        if data.count <= room {
            buffer.append(data)
            return false
        }
        buffer.append(data.prefix(max(0, room)))
        truncated = true
        return true
    }
}
