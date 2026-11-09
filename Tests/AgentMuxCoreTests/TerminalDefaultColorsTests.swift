@testable import AgentMuxCore
import Foundation
import Testing

/// Real OSC queries in disposable local panes, without starting an agent.
@Suite(.serialized) struct TerminalDefaultColorsTests {
    private static let tmuxPath = AgentLauncherTests.tmuxPath
    private let dark = TerminalDefaultColors(foreground: 0xD6D6D6, background: 0x101012)
    private let light = TerminalDefaultColors(foreground: 0x3A3A3A, background: 0xFFFFFF)

    @Test func rejectsNonPaneTargets() {
        for target in ["$1", "@1", "%", "%1;kill-server", "%1\n"] {
            #expect(dark.reportCommands(paneID: target).isEmpty)
        }
    }

    @Test(.enabled(if: tmuxPath != nil)) func controlReportsChangeOnlyTheTargetPane() throws {
        let fixture = try Fixture(tmuxPath: Self.tmuxPath!)
        defer { fixture.close() }
        let pane = try fixture.run(["new-session", "-d", "-s", "t", "-P", "-F", "#{pane_id}", "/bin/sh"])
        try fixture.run(["set-option", "-gw", "window-style", light.paneStyle])
        try fixture.run(["set-option", "-gw", "window-active-style", light.paneStyle])
        let sibling = try fixture.run(["new-window", "-d", "-t", "t", "-P", "-F", "#{pane_id}", "/bin/sh"])

        // Reproduce the startup probe that produced the white composer.
        #expect(try fixture.query(pane)["11"] == "ffff/ffff/ffff")
        let control = try fixture.attach()
        defer { control.close() }
        try control.send(dark.reportCommands(paneID: pane))
        let actualDark = try fixture.query(pane)
        #expect(actualDark["10"] == "d6d6/d6d6/d6d6")
        #expect(actualDark["11"] == "1010/1010/1212")
        #expect(try fixture.query(sibling)["11"] == "ffff/ffff/ffff")

        // Switching back must update both foreground and background too.
        try control.send(light.reportCommands(paneID: pane))
        let actualLight = try fixture.query(pane)
        #expect(actualLight["10"] == "3a3a/3a3a/3a3a")
        #expect(actualLight["11"] == "ffff/ffff/ffff")
    }

    @Test(.enabled(if: tmuxPath != nil)) func launchColorsAreReadyForTheFirstProbe() throws {
        let fixture = try Fixture(tmuxPath: Self.tmuxPath!)
        defer { fixture.close() }
        let creates = [["new-session", "-d", "-s", "t"], ["new-window", "-t", "t"]]
        for (index, create) in creates.enumerated() {
            let colors = index == 0 ? dark : light
            let output = fixture.directory.appendingPathComponent("launch-\(index).json")
            let command = ShellQuote.command(["/usr/bin/python3", fixture.probe.path, output.path])
            let script = AgentLauncher.script(tmux: fixture.tmux, create: create, command: command, defaultColors: colors)
            let pane = try #require(AgentLauncher.paneID(in: Fixture.shell(script)))
            let result = try fixture.result(at: output)
            #expect(result["11"] == (index == 0 ? "1010/1010/1212" : "ffff/ffff/ffff"))
            let style = try fixture.run(["show-options", "-pv", "-t", pane, "window-style"])
            #expect(style == colors.paneStyle)
        }
    }

    private final class Fixture {
        let directory: URL
        let probe: URL
        let tmux: [String]

        init(tmuxPath: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-colors-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            tmux = [tmuxPath, "-L", "agentmux-colors-\(UUID().uuidString.prefix(8))", "-f", "/dev/null"]
            probe = directory.appendingPathComponent("probe.py")
            try #"""
            import json, os, re, select, sys, termios, time, tty
            fd = os.open('/dev/tty', os.O_RDWR)
            old = termios.tcgetattr(fd)
            tty.setraw(fd)
            try:
                os.write(fd, b'\x1b]10;?\x07\x1b]11;?\x07')
                data = b''
                end = time.monotonic() + 2
                pattern = rb'\x1b\](1[01]);rgb:([0-9a-fA-F/]+)'
                while time.monotonic() < end and len(re.findall(pattern, data)) < 2:
                    if select.select([fd], [], [], .05)[0]:
                        data += os.read(fd, 4096)
                colors = {k.decode(): v.decode() for k, v in re.findall(pattern, data)}
                with open(sys.argv[1], 'w') as out:
                    json.dump(colors, out)
            finally:
                termios.tcsetattr(fd, termios.TCSANOW, old)
                os.close(fd)
            time.sleep(30)
            """#.write(to: probe, atomically: true, encoding: .utf8)
        }

        @discardableResult func run(_ args: [String]) throws -> String {
            try Self.shell(ShellQuote.command(tmux + args)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func query(_ pane: String) throws -> [String: String] {
            let output = directory.appendingPathComponent("\(UUID().uuidString).json")
            try run(["respawn-pane", "-k", "-t", pane, "/usr/bin/python3", probe.path, output.path])
            return try result(at: output)
        }

        func result(at output: URL) throws -> [String: String] {
            for _ in 0 ..< 200 {
                if let data = try? Data(contentsOf: output),
                   let result = try? JSONDecoder().decode([String: String].self, from: data) { return result }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw Failure.timeout
        }

        func attach() throws -> Control {
            try Control(tmux: tmux, log: directory.appendingPathComponent("control.log"))
        }

        func close() {
            _ = try? run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }

        static func shell(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure.command(String(decoding: data, as: UTF8.self))
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class Control {
        let process = Process()
        let input = Pipe()
        let log: URL
        let output: FileHandle

        init(tmux: [String], log: URL) throws {
            self.log = log
            FileManager.default.createFile(atPath: log.path, contents: nil)
            output = try FileHandle(forWritingTo: log)
            process.executableURL = URL(fileURLWithPath: tmux[0])
            process.arguments = Array(tmux.dropFirst()) + ["-C", "attach-session", "-t", "t"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            try send([])
        }

        func send(_ commands: [String]) throws {
            let marker = "ready-\(UUID().uuidString)"
            let line = (commands + ["display-message -p " + TmuxQuote.word(marker)]).joined(separator: " ; ") + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            for _ in 0 ..< 200 {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if text.contains(marker) { return }
                if text.contains("%error") { throw Failure.command(text) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw Failure.timeout
        }

        func close() {
            try? input.fileHandleForWriting.write(contentsOf: Data("detach-client\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            try? output.close()
        }
    }

    private enum Failure: Error { case timeout, command(String) }
}
