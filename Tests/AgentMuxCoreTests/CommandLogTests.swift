@testable import AgentMuxCore
import Foundation
import Testing

@Suite struct RotatingLogFileTests {
    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotlog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-commands.log")
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func rotatesPastTheLimitKeepingOnePreviousFile() {
        let url = scratch()
        let log = RotatingLogFile(url: url, maxBytes: 10)
        #expect(log.previousURL.lastPathComponent == "remote-commands.1.log")
        log.append(Data("aaaa\n".utf8))
        log.append(Data("bbbb\n".utf8))
        #expect(read(url) == "aaaa\nbbbb\n")
        log.append(Data("cccc\n".utf8))
        #expect(read(log.previousURL) == "aaaa\nbbbb\n")
        #expect(read(url) == "cccc\n")
        log.append(Data("dddd\n".utf8))
        log.append(Data("eeee\n".utf8))
        #expect(read(log.previousURL) == "cccc\ndddd\n")
        #expect(read(url) == "eeee\n")
    }

    @Test func aFileAlreadyPastTheLimitRotatesOnTheFirstLine() throws {
        let url = scratch()
        try Data(String(repeating: "x", count: 50).utf8).write(to: url)
        let log = RotatingLogFile(url: url, maxBytes: 10)
        log.append(Data("new\n".utf8))
        #expect(read(url) == "new\n")
        #expect(read(log.previousURL).count == 50)
    }

    @Test func keepsAppendingAcrossReopens() {
        let url = scratch()
        RotatingLogFile(url: url, maxBytes: 100).append(Data("one\n".utf8))
        RotatingLogFile(url: url, maxBytes: 100).append(Data("two\n".utf8))
        #expect(read(url) == "one\ntwo\n")
    }
}
