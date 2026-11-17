@testable import AgentMuxCore
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct PipeReaderTests {
    @Test func deliveredDataSurvivesTheReadPool() throws {
        let pipe = Pipe()
        let bytes = Data(repeating: 0x41, count: 4096)
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        let delivered = PipeReader.readAvailable(from: pipe.fileHandleForReading)
        autoreleasepool { _ = NSMutableData(length: 4096) }
        #expect(delivered == bytes)
        try pipe.fileHandleForWriting.close()
        #expect(PipeReader.readAvailable(from: pipe.fileHandleForReading).isEmpty)
    }

    @Test func streamingDoesNotRetainEveryChunkUntilTheThreadExits() throws {
        let stream = Stream()
        let total = 128 << 20
        let before = try footprint()
        Thread.detachNewThread {
            autoreleasepool {
                var count = 0
                var valid = true
                while count < total {
                    let data = PipeReader.readAvailable(from: stream.pipe.fileHandleForReading)
                    if data.isEmpty { break }
                    valid = valid && data.first == 0x41 && data.last == 0x41
                    count += data.count
                }
                stream.lock.withLock { stream.received = count; stream.valid = valid }
                stream.read.signal()
                // Measure with this thread alive. Letting it exit would drain
                // its outer pool and mask the original long-lived-reader bug.
                stream.allowExit.wait()
            }
            stream.ended.signal()
        }
        defer {
            try? stream.pipe.fileHandleForWriting.close()
            stream.allowExit.signal()
            _ = stream.ended.wait(timeout: .now() + 5)
        }
        var sent = 0
        let chunk = [UInt8](repeating: 0x41, count: 16384)
        try chunk.withUnsafeBytes { buffer in
            while sent < total {
                let count = Darwin.write(stream.pipe.fileHandleForWriting.fileDescriptor,
                                         buffer.baseAddress, min(buffer.count, total - sent))
                if count > 0 { sent += count }
                else if errno != EINTR { throw Failure.write(errno) }
            }
        }
        #expect(stream.read.wait(timeout: .now() + 10) == .success)
        let after = try footprint()
        #expect(stream.lock.withLock { stream.received == total && stream.valid })
        let growth = after > before ? after - before : 0
        // The unpooled reader grows by ~130 MiB for this 128 MiB stream.
        // Leave ample room for allocator/framework bookkeeping in the runner.
        #expect(growth < 64 << 20)
    }

    private func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.measurement(result) }
        return info.phys_footprint
    }

    private final class Stream: @unchecked Sendable {
        let pipe = Pipe()
        let lock = NSLock()
        var received = 0
        var valid = false
        let read = DispatchSemaphore(value: 0)
        let allowExit = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
    }

    private enum Failure: Error {
        case write(Int32)
        case measurement(kern_return_t)
    }
}
