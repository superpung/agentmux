import Foundation
import Testing
@testable import AgentMuxCore

@Suite struct PreviewLinkTests {
    private let doc = "/root/proj/docs/README.md"

    @Test func relativePathsResolveAgainstTheFilesFolder() {
        #expect(PreviewLink.resolve("guide.md", from: doc) == .file("/root/proj/docs/guide.md", anchor: nil))
        #expect(PreviewLink.resolve("./a/b.py", from: doc) == .file("/root/proj/docs/a/b.py", anchor: nil))
        #expect(PreviewLink.resolve("../src//main.swift", from: doc) == .file("/root/proj/src/main.swift", anchor: nil))
        #expect(PreviewLink.resolve("../../../../x.md", from: doc) == .file("/x.md", anchor: nil))
    }

    @Test func absoluteAndFileURLsStayInTheContainer() {
        #expect(PreviewLink.resolve("/etc/hosts", from: doc) == .file("/etc/hosts", anchor: nil))
        #expect(PreviewLink.resolve("file:///root/a.md", from: doc) == .file("/root/a.md", anchor: nil))
        #expect(PreviewLink.resolve("file://localhost/root/a.md", from: doc) == .file("/root/a.md", anchor: nil))
        #expect(PreviewLink.resolve("file://server/share/a.md", from: doc) == .unsupported)
    }

    @Test func percentEncodingIsDecoded() {
        // What Foundation's Markdown parser hands over for `设计/说明.md#安装` and `<my file.md>`.
        #expect(PreviewLink.resolve("%E8%AE%BE%E8%AE%A1/%E8%AF%B4%E6%98%8E.md#%E5%AE%89%E8%A3%85", from: doc)
            == .file("/root/proj/docs/设计/说明.md", anchor: "安装"))
        #expect(PreviewLink.resolve("my%20file.md", from: doc) == .file("/root/proj/docs/my file.md", anchor: nil))
    }

    @Test func fragmentsAndQueries() {
        #expect(PreviewLink.resolve("guide.md#set-up", from: doc) == .file("/root/proj/docs/guide.md", anchor: "set-up"))
        #expect(PreviewLink.resolve("guide.md#", from: doc) == .file("/root/proj/docs/guide.md", anchor: nil))
        #expect(PreviewLink.resolve("guide.md?plain=1#L3", from: doc) == .file("/root/proj/docs/guide.md", anchor: "L3"))
        #expect(PreviewLink.resolve("#usage", from: doc) == .anchor("usage"))
        #expect(PreviewLink.resolve("#", from: doc) == .anchor(""))
        // A link to the file itself stays in it.
        #expect(PreviewLink.resolve("README.md#usage", from: doc) == .anchor("usage"))
        #expect(PreviewLink.resolve("./README.md", from: doc) == .anchor(""))
    }

    @Test func folders() {
        #expect(PreviewLink.resolve("src/", from: doc) == .folder("/root/proj/docs/src"))
        #expect(PreviewLink.resolve("..", from: doc) == .folder("/root/proj"))
        #expect(PreviewLink.resolve(".", from: doc) == .folder("/root/proj/docs"))
        #expect(PreviewLink.resolve("/", from: doc) == .folder("/"))
    }

    @Test func onlyWebAndMailLeaveTheApp() {
        #expect(PreviewLink.resolve("https://example.com/a?b=1#c", from: doc) == .web(URL(string: "https://example.com/a?b=1#c")!))
        #expect(PreviewLink.resolve("HTTP://example.com", from: doc) == .web(URL(string: "HTTP://example.com")!))
        #expect(PreviewLink.resolve("mailto:a@b.c", from: doc) == .web(URL(string: "mailto:a@b.c")!))
        #expect(PreviewLink.resolve("https://example.com/a b", from: doc) == .web(URL(string: "https://example.com/a%20b")!))
        for other in ["javascript:alert(1)", "vscode://file/x", "data:image/png;base64,AA", "ftp://h/x", "  "] {
            #expect(PreviewLink.resolve(other, from: doc) == .unsupported)
        }
    }

    @Test func aColonLaterInAPathIsNotAScheme() {
        #expect(PreviewLink.resolve("notes/a:b.md", from: doc) == .file("/root/proj/docs/notes/a:b.md", anchor: nil))
    }

    @Test func slugsFollowGitHub() {
        #expect(PreviewLink.slug("Getting Started") == "getting-started")
        #expect(PreviewLink.slug("What's new in v2.0?") == "whats-new-in-v20")
        #expect(PreviewLink.slug("`run()` & build") == "run--build")
        #expect(PreviewLink.slug("snake_case-name") == "snake_case-name")
        #expect(PreviewLink.slug("安装 与 配置！") == "安装-与-配置")
        #expect(PreviewLink.slug("Émoji 🚀 Ready") == "émoji--ready")
    }

    @Test func repeatedHeadingsAreNumbered() {
        var slugger = HeadingSlugger()
        #expect(["Usage", "Usage", "Usage-1", "Usage"].map { slugger.slug($0) } == ["usage", "usage-1", "usage-1-1", "usage-2"])
    }

    @Test func historyGoesBackAndForward() {
        var history = BrowseHistory<String>()
        history.leave(nil)
        history.leave("a")
        history.leave("b")
        #expect(history.goBack(from: "c") == "b")
        #expect(history.goBack(from: "b") == "a")
        #expect(history.goBack(from: "a") == nil)
        #expect(history.goForward(from: "a") == "b")
        // Moving somewhere new drops what was ahead.
        history.leave("b")
        #expect(history.forward.isEmpty)
        #expect(history.back == ["a", "b"])
        #expect(history.retract() == "b")
        #expect(history.back == ["a"])
    }

    @Test func retractOnlyUndoesALeave() {
        var history = BrowseHistory<String>()
        history.leave("a")
        history.leave(nil) // From nothing shown: nothing to return to.
        #expect(history.retract() == nil)
        #expect(history.back == ["a"])
        history.leave("b")
        _ = history.goBack(from: "c")
        #expect(history.retract() == nil)
        #expect(history.back == ["a"])
    }

    @Test func lineLinks() {
        #expect(PreviewLink.lines("L12") == 12...12)
        #expect(PreviewLink.lines("L12-L20") == 12...20)
        #expect(PreviewLink.lines("l20-12") == 12...20)
        for other in ["L0", "Lx", "usage", "L12-", ""] { #expect(PreviewLink.lines(other) == nil) }
    }

    @Test func historyKeepsItsLimit() {
        var history = BrowseHistory<Int>(limit: 3)
        for i in 0..<10 { history.leave(i) }
        #expect(history.back == [7, 8, 9])
    }
}
