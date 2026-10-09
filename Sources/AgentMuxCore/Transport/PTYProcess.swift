import CPTY
import Foundation

public enum PTYProcessError: Error, Equatable {
    case executableNotAbsolute(String)
    case spawnFailed(errno: Int32)
}

/// A local child process attached to a pseudo-terminal.
///
/// All mutable state is confined to `queue`. `hangUp()` closes the master
/// side of the pty, which is how a local view lets go of its connection:
/// nothing is ever written to the child when a view closes.
public final class PTYProcess: @unchecked Sendable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    /// Writes queued beyond this are dropped rather than buffered without bound.
    public static let maxPendingWriteBytes = 16 << 20

    public let pid: pid_t
    private let masterFD: Int32
    private let queue: DispatchQueue

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pendingWrites = Data()
    private var isWriteSourceResumed = false
    private var isReadSourceSuspended = false
    private var isHungUp = false
    private var termination: Termination?
    private var onOutput: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable (Termination) -> Void)?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        columns: UInt16,
        rows: UInt16
    ) throws {
        guard executable.hasPrefix("/") else {
            throw PTYProcessError.executableNotAbsolute(executable)
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var fd: Int32 = -1
        let child = agentmux_spawn_pty(executable, argv, envp, columns, rows, &fd)
        guard child > 0 else {
            throw PTYProcessError.spawnFailed(errno: errno)
        }
        pid = child
        masterFD = fd
        queue = DispatchQueue(label: "agentmux.pty.\(child)")
    }

    /// Starts delivering output and the exit notification. Both callbacks run
    /// on the process's private queue. Call once.
    public func start(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Termination) -> Void
    ) {
        queue.async { [self] in
            self.onOutput = onOutput
            self.onExit = onExit

            let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
            read.setEventHandler { [unowned self] in drainOutput() }
            readSource = read

            let write = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
            write.setEventHandler { [unowned self] in flushWrites() }
            writeSource = write

            // Retains self until the child has been reaped.
            let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in reap() }
            processSource = process

            read.resume()
            process.resume()
        }
    }

    /// Queues bytes for the child's terminal input, in order.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !isHungUp, termination == nil else { return }
            guard pendingWrites.count + data.count <= Self.maxPendingWriteBytes else { return }
            pendingWrites.append(data)
            flushWrites()
        }
    }

    public func resize(columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0 else { return }
        queue.async { [self] in
            guard !isHungUp else { return }
            _ = agentmux_set_window_size(masterFD, columns, rows)
        }
    }

    /// Closes the pty. The child sees a hangup; if it is still around after
    /// `grace` it gets SIGTERM, then SIGKILL. Only this local process group
    /// is signalled.
    public func hangUp(grace: TimeInterval = 3) {
        queue.async { [self] in
            guard !isHungUp else { return }
            isHungUp = true
            pendingWrites.removeAll()
            closeMaster()
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                guard termination == nil else { return }
                kill(-pid, SIGTERM)
                queue.asyncAfter(deadline: .now() + grace) { [self] in
                    if termination == nil { kill(-pid, SIGKILL) }
                }
            }
        }
    }

    // MARK: - Queue-confined

    private func drainOutput() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(masterFD, $0.baseAddress, $0.count) }
            if count > 0 {
                onOutput?(Data(buffer[0 ..< count]))
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            // EOF or EIO: the slave side is gone.
            if !isReadSourceSuspended {
                isReadSourceSuspended = true
                readSource?.suspend()
            }
            return
        }
    }

    private func flushWrites() {
        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingWrites.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if !isWriteSourceResumed {
                    isWriteSourceResumed = true
                    writeSource?.resume()
                }
                return
            }
            pendingWrites.removeAll()
            break
        }
        if isWriteSourceResumed {
            isWriteSourceResumed = false
            writeSource?.suspend()
        }
    }

    private func reap() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        if !isHungUp { drainOutput() }
        let signal = status & 0x7F
        let result: Termination = signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
        termination = result
        processSource?.cancel()
        processSource = nil
        if !isHungUp {
            isHungUp = true
            closeMaster()
        }
        onExit?(result)
        onOutput = nil
        onExit = nil
    }

    private func closeMaster() {
        // Suspended sources must be resumed before cancel; the fd is closed
        // only after every source using it has been cancelled.
        let fd = masterFD
        let group = DispatchGroup()
        for source in [readSource, writeSource] as [(any DispatchSourceProtocol)?] {
            guard let source else { continue }
            group.enter()
            source.setCancelHandler { group.leave() }
        }
        if let readSource {
            readSource.cancel()
            if isReadSourceSuspended { readSource.resume() }
        }
        if let writeSource {
            writeSource.cancel()
            if !isWriteSourceResumed { writeSource.resume() }
        }
        readSource = nil
        writeSource = nil
        group.notify(queue: queue) { close(fd) }
    }
}
