import Foundation
import Testing
@testable import AgentMuxCore

/// The read-only local copies a remote file is opened from in a Mac app.
@Suite final class LocalCopiesTests {
    private let copies: LocalCopies
    private let fm = FileManager.default

    init() {
        let root = fm.temporaryDirectory.appendingPathComponent("LocalCopiesTests-\(UUID().uuidString)", isDirectory: true)
        copies = LocalCopies(root: root)
    }

    deinit {
        try? fm.removeItem(at: copies.root)
    }

    private func permissions(_ url: URL) throws -> Int {
        try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }

    private func modified(_ url: URL) throws -> Date {
        try fm.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    private func inode(_ url: URL) throws -> Int {
        try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as! Int
    }

    @Test func keepsTheRemoteNameInAFolderPerFile() {
        let a = copies.url(for: "/work/deck.pptx", target: "xp01")
        #expect(a.lastPathComponent == "deck.pptx")
        #expect(a == copies.url(for: "/work/deck.pptx", target: "xp01"))
        // Same name, another folder or another container: another copy.
        #expect(a != copies.url(for: "/other/deck.pptx", target: "xp01"))
        #expect(a != copies.url(for: "/work/deck.pptx", target: "jg20"))
        #expect(a.deletingLastPathComponent().deletingLastPathComponent() == copies.root)
    }

    @Test func storesAReadOnlyCopy() throws {
        let url = try copies.store(Data("slides".utf8), for: "/work/deck.pptx", target: "xp01")
        #expect(try Data(contentsOf: url) == Data("slides".utf8))
        #expect(try permissions(url) == 0o444)
        #expect(!fm.isWritableFile(atPath: url.path))
    }

    @Test func leavesAnUnchangedCopyInPlaceButMarksItUsed() throws {
        let url = try copies.store(Data("same".utf8), for: "/work/a.docx", target: "xp01")
        let old = Date(timeIntervalSinceNow: -3 * 86400)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let before = try inode(url)
        try copies.store(Data("same".utf8), for: "/work/a.docx", target: "xp01")
        #expect(try inode(url) == before)
        #expect(try modified(url) > old.addingTimeInterval(86400))
        #expect(try permissions(url) == 0o444)
    }

    @Test func replacesAChangedCopy() throws {
        let url = try copies.store(Data("v1".utf8), for: "/work/a.xlsx", target: "xp01")
        try copies.store(Data("version 2".utf8), for: "/work/a.xlsx", target: "xp01")
        #expect(try Data(contentsOf: url) == Data("version 2".utf8))
        #expect(try permissions(url) == 0o444)
    }

    @Test func prunesCopiesUnusedForDays() throws {
        let stale = try copies.store(Data("old".utf8), for: "/work/old.pptx", target: "xp01")
        let fresh = try copies.store(Data("new".utf8), for: "/work/new.pptx", target: "xp01")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: stale.path)
        copies.prune(olderThanDays: 7)
        #expect(!fm.fileExists(atPath: stale.deletingLastPathComponent().path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    @Test func pruneWithoutAnyCopiesIsQuiet() {
        LocalCopies(root: copies.root.appendingPathComponent("missing")).prune(olderThanDays: 7)
    }
}
