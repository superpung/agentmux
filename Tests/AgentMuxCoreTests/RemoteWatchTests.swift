import Foundation
import Testing
@testable import AgentMuxCore

/// The file watch's loop, run for real under the local POSIX shells (the
/// remote runs it under its `sh`). The containers have GNU `stat`; a shim
/// gives the same output from macOS's.
@Suite struct RemoteWatchTests {
    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// A `stat -c FORMAT -- PATH` answering as GNU's does for the watch's format.
    private static func statShim(in dir: URL) throws -> URL {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("stat")
        try Data("""
        #!/bin/sh
        [ "$1" = -c ] || exit 2
        shift 2
        [ "$1" = -- ] && shift
        exec /usr/bin/stat -f '%i %z %Fm' "$1"
        """.utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        return bin
    }

    @Test(arguments: shells)
    func answersEachCheckAndSeesChanges(shell: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("it's a file.md")
        try Data("one".utf8).write(to: file)

        let bin = try Self.statShim(in: dir)
        let watch = RemoteWatch(localShell: shell, environment: ["PATH": bin.path + ":/usr/bin:/bin"])
        try watch.start()
        defer { watch.stop() }

        let first = try #require(await watch.check([file.path, folder.path, folder.path + "/missing"]))
        #expect(first.count == 3)
        #expect(first[0] != nil && first[1] != nil && first[2] == nil)
        #expect(first[0]?.split(separator: " ")[1] == "3") // inode, size, then the time

        // Unchanged: the same stamp. Rewritten: a new one.
        #expect(try #require(await watch.check([file.path]))[0] == first[0])
        try Data("two!".utf8).write(to: file, options: .atomic)
        #expect(try #require(await watch.check([file.path]))[0] != first[0])
        // A new entry changes the folder's stamp.
        try Data().write(to: folder.appendingPathComponent("new.txt"))
        #expect(try #require(await watch.check([folder.path]))[0] != first[1])
    }

    @Test func refusesRelativeOrMultilinePaths() async throws {
        let watch = RemoteWatch(localShell: "/bin/sh")
        try watch.start()
        defer { watch.stop() }
        #expect(await watch.check(["relative.md"]) == nil)
        #expect(await watch.check(["/a\nb"]) == nil)
        #expect(await watch.check([]) == nil)
    }

    @Test func endsWhenItsInputCloses() async throws {
        let watch = RemoteWatch(localShell: "/bin/sh")
        try watch.start()
        watch.stop()
        for _ in 0..<50 where watch.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!watch.isRunning)
        #expect(await watch.check(["/tmp"]) == nil)
    }

    @Test func longLivedKeepsStdinForTheScript() throws {
        let context = try TargetConfig.discovered(host: HostConfig(id: "h", displayName: "h", sshDestination: "h"), container: "c1").executionContext()
        let command = RemoteCommand.longLived("echo hi", in: context, lifetimeSeconds: 600)
        #expect(command.hasPrefix("docker exec -i c1 sh -c "))
        #expect(command.contains("exec timeout 600 sh -c"))
        #expect(!command.contains("docker inspect"))
        #expect(!command.contains("sh -s"))
    }
}
