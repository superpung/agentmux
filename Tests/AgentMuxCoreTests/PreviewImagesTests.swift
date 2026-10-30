import Foundation
import Testing
@testable import AgentMuxCore

/// Pictures in previews: badges unnested for the Markdown parser, an HTML
/// page's images inlined, image types sniffed, and the batch read of image
/// files run for real under the local POSIX shells.
@Suite struct PreviewImagesTests {
    // MARK: MarkdownSource

    @Test func badgeBecomesHTMLTheRendererReads() {
        let md = "[![CI](https://x.dev/ci.svg)](https://x.dev/ci) and [![](b.png \"t\")](<x y>)"
        #expect(MarkdownSource.unnestingLinkedImages(md) ==
            #"<a href="https://x.dev/ci"><img src="https://x.dev/ci.svg" alt="CI"></a> and [![](b.png "t")](<x y>)"#)
    }

    @Test func badgeTextIsEscaped() {
        let md = #"[![a "b" & <c>](i.png)](l?q=1&r=2)"#
        #expect(MarkdownSource.unnestingLinkedImages(md) ==
            #"<a href="l?q=1&amp;r=2"><img src="i.png" alt="a &quot;b&quot; &amp; &lt;c&gt;"></a>"#)
    }

    @Test func codeIsLeftAsWritten() {
        let md = """
        `[![a](i.png)](l)` [![b](j.png)](m)
        ```
        [![c](k.png)](n)
        ```
        ~~~~md
        [![d](k.png)](n)
        ~~~
        still code [![e](k.png)](n)
        ~~~~
        [![f](k.png)](n)
        """
        let out = MarkdownSource.unnestingLinkedImages(md).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(out[0] == #"`[![a](i.png)](l)` <a href="m"><img src="j.png" alt="b"></a>"#)
        #expect(out[2] == "[![c](k.png)](n)")
        #expect(out[5] == "[![d](k.png)](n)")
        #expect(out[7] == "still code [![e](k.png)](n)")
        #expect(out[9] == #"<a href="n"><img src="k.png" alt="f"></a>"#)
    }

    @Test func plainImagesAndLinksStay() {
        let md = "![a](i.png) [b](l) [![unclosed](i.png)"
        #expect(MarkdownSource.unnestingLinkedImages(md) == md)
    }

    // MARK: HTMLImages

    @Test func listsImageSourcesOnceWithoutDataURIs() {
        let html = #"<p><IMG SRC="a.png"><img alt=x src='b/c.jpg'><img src=d.gif><img src="a.png"><img src="data:image/png;base64,AA"></p>"#
        #expect(HTMLImages.sources(in: html) == ["a.png", "b/c.jpg", "d.gif"])
    }

    @Test func inlinesFetchedImagesAndDropsSrcset() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
        let html = #"<img class="x" src="a.png" srcset="a@2x.png 2x" width="10"><img src="missing.png">"#
        let out = HTMLImages.inlining(["a.png": png], in: html)
        #expect(out == #"<img class="x" src="data:image/png;base64,\#(png.base64EncodedString())" width="10"><img src="missing.png">"#)
    }

    @Test func sourceWithAnEntityIsMatchedDecoded() {
        let html = #"<img src="p.png?a=1&amp;b=2">"#
        #expect(HTMLImages.sources(in: html) == ["p.png?a=1&b=2"])
        #expect(HTMLImages.inlining(["p.png?a=1&b=2": Data("GIF89a".utf8)], in: html).contains("data:image/gif;base64,"))
    }

    // MARK: ImageMIME

    @Test func sniffsCommonImageTypes() {
        #expect(ImageMIME.of(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ImageMIME.of(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "image/webp")
        #expect(ImageMIME.of(Data("<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == "image/svg+xml")
        #expect(ImageMIME.of(Data("\0\0\0\u{1C}ftypavif".utf8)) == "image/avif")
        #expect(ImageMIME.of(Data("hello".utf8)) == "application/octet-stream")
    }

    // MARK: readImages script, run under real shells

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(arguments: shells) func readsRegularFilesAndLeavesOutTheRest(shell: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = Data((0..<200).map { UInt8($0) })
        let big = Data(repeating: 7, count: 300)
        try small.write(to: dir.appendingPathComponent("it's a.png"))
        try big.write(to: dir.appendingPathComponent("big.png"))
        try Data().write(to: dir.appendingPathComponent("empty.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.png"), withIntermediateDirectories: false)
        let fifo = dir.appendingPathComponent("pipe.png").path
        #expect(mkfifo(fifo, 0o644) == 0)
        let paths = ["it's a.png", "missing.png", "big.png", "folder.png", "pipe.png", "empty.png", "it's a.png"]
            .map { dir.appendingPathComponent($0).path }
        // Each file up to 250 bytes; 400 in all.
        let output = try run(RemoteFileService.imagesScript(paths, cap: 250, total: 400), shell)
        let images = RemoteFileService.parseImages(output, paths: paths)
        #expect(images == [paths[0]: small])
        #expect(output.components(separatedBy: "@@img ").count - 1 == paths.count)

        // The total: a second copy of a 200-byte file fits 400, a third does not.
        let again = Array(repeating: paths[0], count: 3)
        let counted = try run(RemoteFileService.imagesScript(again, cap: 250, total: 400), shell)
        #expect(counted.components(separatedBy: "@@img 200").count - 1 == 2)
        #expect(counted.contains("@@img -1"))
    }

    @Test func parsesAfterContainerFraming() {
        let out = "@@container abc running X 1\n@@img 3\nYWJj\n@@img -1\n"
        let paths = ["/a.png", "/b.png"]
        #expect(RemoteFileService.parseImages(RemoteFileService.stripFraming(out), paths: paths) == ["/a.png": Data("abc".utf8)])
    }

    private func run(_ script: String, _ shell: String) throws -> String {
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

/// Pictures a notebook holds: outputs and images pasted into Markdown cells.
@Suite struct NotebookImageTests {
    @Test func pastedImagesBecomeDataURIs() throws {
        let json = """
        {"cells": [
          {"cell_type": "markdown", "source": ["Plot: ![chart](attachment:my%20chart.png) and ![x](attachment:icon.svg)"],
           "attachments": {"my chart.png": {"image/png": "iVBORw0K\\nGgo="}, "icon.svg": {"image/svg+xml": ["<svg/>"]}}},
          {"cell_type": "code", "source": "plot()", "outputs": [
            {"output_type": "display_data", "data": {"image/svg+xml": "<svg/>", "text/plain": "<Figure>"}}]}
        ], "metadata": {}}
        """
        let md = try #require(Notebook.markdown(json))
        let svg = Data("<svg/>".utf8).base64EncodedString()
        #expect(md.contains("![chart](data:image/png;base64,iVBORw0KGgo=)"))
        #expect(md.contains("![x](data:image/svg+xml;base64,\(svg))"))
        #expect(md.contains("> ![output](data:image/svg+xml;base64,\(svg))"))
    }
}
