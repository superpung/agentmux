import Foundation
import Testing
@testable import AgentMuxCore

/// The no-clobber writes behind New File / New Folder / Rename / folder Delete:
/// marker parsing, name checks, and the generated scripts run for real under
/// the local POSIX shells (the remote runs them under its `sh`).
@Suite struct RemoteFileWriteTests {
    // MARK: parseNoClobber

    @Test func parsesOkAndExists() throws {
        #expect(try RemoteFileService.parseNoClobber("@@ok\n").get() == .done)
        #expect(try RemoteFileService.parseNoClobber("@@exists\n").get() == .alreadyExists)
    }

    @Test func parsesMarkerAfterContainerFraming() throws {
        let framed = "@@container abc123 running X 42\n@@ok\n"
        #expect(try RemoteFileService.parseNoClobber(framed).get() == .done)
    }

    @Test func missingSourceIsFailure() {
        guard case let .failure(failure) = RemoteFileService.parseNoClobber("@@missing\n") else {
            Issue.record("expected failure"); return
        }
        #expect(failure.detail.contains("no longer exists"))
    }

    @Test func errorKeepsTheRemoteMessageAcrossLines() {
        let out = "@@err mkdir: cannot create directory 'x':\nPermission denied\n"
        guard case let .failure(failure) = RemoteFileService.parseNoClobber(out) else {
            Issue.record("expected failure"); return
        }
        #expect(failure.detail == "mkdir: cannot create directory 'x': Permission denied")
    }

    @Test func noMarkerIsFailure() {
        #expect((try? RemoteFileService.parseNoClobber("").get()) == nil)
        #expect((try? RemoteFileService.parseNoClobber("garbage\n").get()) == nil)
    }

    // MARK: names and paths

    @Test func acceptsOrdinaryNames() {
        for name in ["notes.md", ".env", "a b", "it's", "-dash", "目录", "a\tb"] {
            #expect(RemoteFileService.nameProblem(name) == nil, "\(name)")
        }
    }

    @Test func rejectsUnusableNames() {
        #expect(RemoteFileService.nameProblem("") == .empty)
        #expect(RemoteFileService.nameProblem(".") == .reserved)
        #expect(RemoteFileService.nameProblem("..") == .reserved)
        #expect(RemoteFileService.nameProblem("a/b") == .slash)
        #expect(RemoteFileService.nameProblem("a\nb") == .lineBreak)
        #expect(RemoteFileService.nameProblem("a\r\nb") == .lineBreak)
        #expect(RemoteFileService.nameProblem("a\0b") == .lineBreak)
    }

    @Test func limitsNamesTo255Bytes() {
        #expect(RemoteFileService.nameProblem(String(repeating: "a", count: 255)) == nil)
        #expect(RemoteFileService.nameProblem(String(repeating: "a", count: 256)) == .tooLong)
        // 86 three-byte characters = 258 bytes, though only 86 characters.
        #expect(RemoteFileService.nameProblem(String(repeating: "目", count: 86)) == .tooLong)
    }

    @Test func joinsPathsLikeListings() {
        #expect(RemoteFileService.path("a.txt", in: "/data/x") == "/data/x/a.txt")
        #expect(RemoteFileService.path("a.txt", in: "/data/x/") == "/data/x/a.txt")
        #expect(RemoteFileService.path("a.txt", in: "/") == "/a.txt")
    }

    // MARK: scripts, run under real shells

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(arguments: shells) func createFileMakesAnEmptyFileOnce(shell: String) throws {
        try withScratch { dir in
            let path = dir + "/it's -new file.txt"
            #expect(try Self.run(RemoteFileService.createFileScript(path), shell) == .done)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
            // A second create must not truncate what an agent wrote meanwhile.
            try Data("agent wrote this".utf8).write(to: URL(fileURLWithPath: path))
            #expect(try Self.run(RemoteFileService.createFileScript(path), shell) == .alreadyExists)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "agent wrote this")
        }
    }

    @Test(arguments: shells) func createFileRefusesADanglingSymlink(shell: String) throws {
        try withScratch { dir in
            let link = dir + "/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir + "/nowhere")
            #expect(try Self.run(RemoteFileService.createFileScript(link), shell) == .alreadyExists)
            #expect(!FileManager.default.fileExists(atPath: dir + "/nowhere"))
        }
    }

    @Test(arguments: shells) func createFileReportsTheShellError(shell: String) throws {
        try withScratch { dir in
            let result = try Self.runRaw(RemoteFileService.createFileScript(dir + "/missing/x"), shell)
            guard case let .failure(failure) = RemoteFileService.parseNoClobber(result) else {
                Issue.record("expected failure"); return
            }
            #expect(!failure.detail.isEmpty)
        }
    }

    @Test(arguments: shells) func createDirectoryMakesOneFolderOnce(shell: String) throws {
        try withScratch { dir in
            let path = dir + "/-new folder"
            #expect(try Self.run(RemoteFileService.createDirectoryScript(path), shell) == .done)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
            #expect(try Self.run(RemoteFileService.createDirectoryScript(path), shell) == .alreadyExists)
            // No parents: a missing intermediate folder is an error, not created.
            let nested = try Self.runRaw(RemoteFileService.createDirectoryScript(dir + "/a/b"), shell)
            #expect((try? RemoteFileService.parseNoClobber(nested).get()) == nil)
            #expect(!FileManager.default.fileExists(atPath: dir + "/a"))
        }
    }

    @Test(arguments: shells) func renameMovesAndNeverReplaces(shell: String) throws {
        try withScratch { dir in
            let a = dir + "/a.txt", b = dir + "/it's b.txt"
            try Data("A".utf8).write(to: URL(fileURLWithPath: a))
            #expect(try Self.run(RemoteFileService.renameScript(a, to: b), shell) == .done)
            #expect(!FileManager.default.fileExists(atPath: a))
            #expect(try String(contentsOfFile: b, encoding: .utf8) == "A")

            // Destination taken: both files stay as they were.
            let c = dir + "/c.txt"
            try Data("C".utf8).write(to: URL(fileURLWithPath: c))
            #expect(try Self.run(RemoteFileService.renameScript(b, to: c), shell) == .alreadyExists)
            #expect(try String(contentsOfFile: b, encoding: .utf8) == "A")
            #expect(try String(contentsOfFile: c, encoding: .utf8) == "C")

            // An existing folder as destination is refused, not moved into.
            let folder = dir + "/folder"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            #expect(try Self.run(RemoteFileService.renameScript(c, to: folder), shell) == .alreadyExists)
            #expect(!FileManager.default.fileExists(atPath: folder + "/c.txt"))
        }
    }

    @Test(arguments: shells) func renameOfAMissingEntryIsFailure(shell: String) throws {
        try withScratch { dir in
            let out = try Self.runRaw(RemoteFileService.renameScript(dir + "/gone", to: dir + "/new"), shell)
            guard case let .failure(failure) = RemoteFileService.parseNoClobber(out) else {
                Issue.record("expected failure"); return
            }
            #expect(failure.detail.contains("no longer exists"))
        }
    }

    @Test(arguments: shells) func renameMovesAFolderWithItsContents(shell: String) throws {
        try withScratch { dir in
            let src = dir + "/src", dst = dir + "/dst"
            try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: URL(fileURLWithPath: src + "/inner.txt"))
            #expect(try Self.run(RemoteFileService.renameScript(src, to: dst), shell) == .done)
            #expect(FileManager.default.fileExists(atPath: dst + "/inner.txt"))
        }
    }

    @Test(arguments: shells) func removeDirectoryOnlyRemovesEmptyFolders(shell: String) throws {
        try withScratch { dir in
            let empty = dir + "/empty", full = dir + "/full"
            try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: URL(fileURLWithPath: full + "/keep.txt"))

            #expect(try Self.run(RemoteFileService.removeDirectoryScript(empty), shell) == .done)
            #expect(!FileManager.default.fileExists(atPath: empty))

            let out = try Self.runRaw(RemoteFileService.removeDirectoryScript(full), shell)
            #expect((try? RemoteFileService.parseNoClobber(out).get()) == nil)
            #expect(FileManager.default.fileExists(atPath: full + "/keep.txt"))
        }
    }

    @Test(arguments: shells) func removeDirectoryRefusesAFile(shell: String) throws {
        try withScratch { dir in
            let file = dir + "/f.txt"
            try Data("f".utf8).write(to: URL(fileURLWithPath: file))
            let out = try Self.runRaw(RemoteFileService.removeDirectoryScript(file), shell)
            guard case let .failure(failure) = RemoteFileService.parseNoClobber(out) else {
                Issue.record("expected failure"); return
            }
            #expect(failure.detail == "not a folder")
            #expect(FileManager.default.fileExists(atPath: file))
        }
    }

    @Test(arguments: shells) func removeDirectoryRemovesOnlyTheLinkOfASymlinkedFolder(shell: String) throws {
        try withScratch { dir in
            let target = dir + "/target", link = dir + "/link"
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
            try Data("kept".utf8).write(to: URL(fileURLWithPath: target + "/kept.txt"))
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(try Self.run(RemoteFileService.removeDirectoryScript(link), shell) == .done)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil)
            #expect(FileManager.default.fileExists(atPath: target + "/kept.txt"))
        }
    }

    // MARK: upload policy

    @Test func uploadPolicyRefusesFoldersSpecialFilesBadNamesAndOversizedFiles() {
        let cap = RemoteFileService.downloadByteCap
        func refusal(_ name: String, dir: Bool = false, regular: Bool = true, size: Int = 1) -> RemoteFileService.UploadRefusal? {
            RemoteFileService.uploadRefusal(name: name, isDirectory: dir, isRegularFile: regular, size: size)
        }
        #expect(refusal("a.txt", size: cap) == nil)
        #expect(refusal("src", dir: true, regular: false, size: 0) == .folder)
        // A FIFO reports no size and isn't a directory; reading it would block.
        #expect(refusal("pipe", regular: false, size: 0) == .notAFile)
        #expect(refusal("a\nb") == .unusableName)
        #expect(refusal("big.bin", size: cap + 1) == .tooLarge)
    }

    // MARK: helpers

    private func withScratch(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmux-write-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.path)
    }

    private static func run(_ script: String, _ shell: String) throws -> RemoteFileService.NoClobberResult {
        try RemoteFileService.parseNoClobber(runRaw(script, shell)).get()
    }

    private static func runRaw(_ script: String, _ shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
