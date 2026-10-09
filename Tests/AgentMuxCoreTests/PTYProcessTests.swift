@testable import AgentMuxCore
import Foundation
import Testing

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var termination: PTYProcess.Termination?

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func finish(_ value: PTYProcess.Termination) { lock.withLock { termination = value } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var result: PTYProcess.Termination? { lock.withLock { termination } }
}

private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite struct PTYProcessTests {
    @Test func rejectsRelativeExecutable() {
        #expect(throws: PTYProcessError.executableNotAbsolute("sh")) {
            try PTYProcess(executable: "sh", arguments: [], environment: [:], columns: 80, rows: 24)
        }
    }

    @Test func childSeesTerminalSizeAndUTF8() async throws {
        let process = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", "stty size; printf '你好\\n'"],
            environment: ["LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"],
            columns: 101,
            rows: 33
        )
        let out = Collector()
        process.start(onOutput: out.append, onExit: out.finish)
        await waitUntil { out.result != nil }
        #expect(out.result == .exited(0))
        #expect(out.text.contains("33 101"))
        #expect(out.text.contains("你好"))
    }

    @Test func inputReachesChildAndResizeDeliversSIGWINCH() async throws {
        // The shell reports its size on SIGWINCH and echoes one line of input.
        let script = "trap 'stty size' WINCH; read line; echo \"got:$line\"; sleep 1"
        let process = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let out = Collector()
        process.start(onOutput: out.append, onExit: out.finish)
        try await Task.sleep(for: .milliseconds(200))
        process.resize(columns: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(200))
        process.write(Data("hello\r".utf8))
        await waitUntil { out.result != nil }
        #expect(out.text.contains("got:hello"))
        #expect(out.text.contains("40 120"))
    }

    @Test func hangUpEndsChildWithoutWritingToIt() async throws {
        let process = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let out = Collector()
        process.start(onOutput: out.append, onExit: out.finish)
        process.hangUp(grace: 1)
        await waitUntil { out.result != nil }
        #expect(out.result != nil)
    }
}
