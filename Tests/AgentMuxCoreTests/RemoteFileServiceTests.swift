import Foundation
import Testing
@testable import AgentMuxCore

@Suite struct RemoteFileServiceTests {
    @Test func listingSortsDirsFirstThenNameAndResolvesSymlinks() {
        let out = "f\tf\t120\treadme.md\nd\td\t4096\tsrc\nf\tf\t0\t.gitignore\nl\td\t12\tlink_to_dir\n"
        let entries = RemoteFileService.parseListing("/data/x", out)
        #expect(entries.map(\.name) == ["link_to_dir", "src", ".gitignore", "readme.md"])
        #expect(entries.first { $0.name == "src" }?.isDirectory == true)
        // a symlink whose target is a directory counts as a directory
        #expect(entries.first { $0.name == "link_to_dir" }?.isDirectory == true)
        #expect(entries.first { $0.name == "readme.md" }?.path == "/data/x/readme.md")
        #expect(entries.first { $0.name == "readme.md" }?.size == 120)
    }

    @Test func listingKeepsTrailingSlashRootClean() {
        let entries = RemoteFileService.parseListing("/data/x/", "f\tf\t1\ta.txt\n")
        #expect(entries.first?.path == "/data/x/a.txt")
    }

    @Test func readDecodesText() throws {
        let out = "@@size 11\n" + Data("hello world".utf8).base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: false, cap: 512 * 1024).get()
        #expect(content == .text("hello world", truncated: false, byteCount: 11))
    }

    @Test func readFlagsTruncatedWhenSizeExceedsCap() throws {
        let out = "@@size 1000\n" + Data("abcd".utf8).base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: false, cap: 4).get()
        guard case let .text(_, truncated, byteCount) = content else { Issue.record("expected text"); return }
        #expect(truncated)
        #expect(byteCount == 1000)
    }

    @Test func readDetectsBinaryViaNUL() throws {
        let out = "@@size 4\n" + Data([0x89, 0x00, 0x01, 0x02]).base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: false, cap: 512 * 1024).get()
        #expect(content == .binary(byteCount: 4))
    }

    @Test func readImageUnderCapIsImage() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let out = "@@size 4\n" + data.base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: true, cap: 1024).get()
        #expect(content == .image(data))
    }

    @Test func readPdfUnderCapIsPdf() throws {
        let data = Data([0x25, 0x50, 0x44, 0x46]) // %PDF
        let out = "@@size 4\n" + data.base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: false, isPDF: true, cap: 1024).get()
        #expect(content == .pdf(data))
    }

    @Test func readImageOverCapIsTooLarge() throws {
        let out = "@@size 99999\n" + Data([0x00]).base64EncodedString()
        let content = try RemoteFileService.parseRead(out, isImage: true, cap: 1024).get()
        #expect(content == .tooLarge(byteCount: 99999))
    }

    @Test func readEmptyFile() throws {
        let content = try RemoteFileService.parseRead("@@size 0\n", isImage: false, cap: 1024).get()
        #expect(content == .empty)
    }

    @Test func readMissingFileIsFailure() {
        #expect((try? RemoteFileService.parseRead("@@size -1\n", isImage: false, cap: 1024).get()) == nil)
    }

    @Test func stripsContainerFramingBeforeRead() throws {
        // RemoteCommand.script prepends an "@@container …" line for containers.
        let framed = "@@container abc123 running 2026-10-13T00:00:00Z 42\n@@size 5\n" + Data("hello".utf8).base64EncodedString()
        let content = try RemoteFileService.parseRead(RemoteFileService.stripFraming(framed), isImage: false, cap: 1024).get()
        #expect(content == .text("hello", truncated: false, byteCount: 5))
    }

    @Test func stripsContainerFramingBeforeListing() {
        let framed = "@@container abc123 running X 42\nd\td\t4096\tsrc\nf\tf\t10\ta.txt\n"
        let entries = RemoteFileService.parseListing("/data/x", RemoteFileService.stripFraming(framed))
        #expect(entries.map(\.name) == ["src", "a.txt"])
    }

    @Test func stripFramingNoOpWithoutContainerLine() {
        #expect(RemoteFileService.stripFraming("@@size 5\nAAAA") == "@@size 5\nAAAA")
    }
}
