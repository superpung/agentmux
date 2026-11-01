@testable import AgentMuxCore
import Foundation
import Testing

/// The launch script, run under a real shell against a private local tmux
/// server (its own socket, killed afterwards): it reports the new pane's id
/// and types the command into that pane.
@Suite(.serialized) struct AgentLauncherTests {
    static let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test func readsThePaneID() {
        #expect(AgentLauncher.paneID(in: "noise\n@@pane %12\n") == "%12")
        #expect(AgentLauncher.paneID(in: "@@pane 12\n") == nil)
        #expect(AgentLauncher.paneID(in: "can't find session: x") == nil)
    }

    @Test(.enabled(if: tmuxPath != nil)) func launchesIntoTheNewPaneAndReportsIt() throws {
        let tmux = [Self.tmuxPath!, "-L", "agentmux-launch-\(UUID().uuidString.prefix(8))", "-f", "/dev/null"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            _ = try? Self.sh(ShellQuote.command(tmux) + " kill-server")
            try? FileManager.default.removeItem(at: dir)
        }

        // A new session, then a new window in it, each running its command.
        for (index, create) in [["new-session", "-d", "-s", "t", "-c", dir.path], ["new-window", "-t", "t", "-c", dir.path]].enumerated() {
            let out = dir.appendingPathComponent("ran-\(index).txt").path
            let script = AgentLauncher.script(tmux: tmux, create: create, command: "printf ran > " + ShellQuote.word(out))
            let pane = try #require(AgentLauncher.paneID(in: Self.sh(script)))
            let panes = try Self.sh(ShellQuote.command(tmux) + " list-panes -a -F '#{pane_id}'")
            #expect(panes.split(whereSeparator: \.isNewline).map(String.init).contains(pane))
            for _ in 0 ..< 50 where !FileManager.default.fileExists(atPath: out) { Thread.sleep(forTimeInterval: 0.1) }
            #expect((try? String(contentsOfFile: out, encoding: .utf8)) == "ran")
        }
    }

    private static func sh(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
