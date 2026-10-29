import Foundation
import Testing
@testable import AgentMuxCore

@Suite struct PreviewFormatTests {
    /// Two slides, the second with a speaker notes page.
    static let pptx = Data(base64Encoded: "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")!

    @Test func formatsByName() {
        #expect(PreviewFormat.of("/a/report.docx") == .document(.word))
        #expect(PreviewFormat.of("/a/data.XLSX") == .document(.spreadsheet))
        #expect(PreviewFormat.of("/a/deck.ppt") == .document(.presentation))
        #expect(PreviewFormat.of("/a/clip.mov") == .document(.video))
        #expect(PreviewFormat.of("/a/app.log.gz") == .compressed(tool: "gzip"))
        #expect(PreviewFormat.of("/a/dump.xz") == .compressed(tool: "xz"))
        #expect(PreviewFormat.of("/a/src.tar.gz") == .archive)
        #expect(PreviewFormat.of("/a/pkg.whl") == .archive)
        #expect(PreviewFormat.of("/a/x.png") == .image)
        #expect(PreviewFormat.of("/a/notes.ipynb") == .text)
        #expect(PreviewFormat.of("/a/Makefile") == .text)
        #expect(PreviewFormat.innerName("/a/data.csv.gz") == "/a/data.csv")
        #expect(PreviewFormat.innerName("/a/src.tar.gz") == "/a/src.tar.gz")
    }

    @Test func zipReadsStoredAndDeflatedFiles() throws {
        let stored = try #require(ZipArchive(Data(base64Encoded: "UEsDBBQAAAAAALmNXV21Aa8PCwAAAAsAAAAFAAAAYS50eHRzdG9yZWQgdGV4dFBLAwQUAAAAAAC5jV1d5iCYNiwBAAAsAQAACQAAAGRpci9iLnR4dGJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYlBLAQIUAxQAAAAAALmNXV21Aa8PCwAAAAsAAAAFAAAAAAAAAAAAAACAAQAAAABhLnR4dFBLAQIUAxQAAAAAALmNXV3mIJg2LAEAACwBAAAJAAAAAAAAAAAAAACAAS4AAABkaXIvYi50eHRQSwUGAAAAAAIAAgBqAAAAgQEAAAAA")!))
        #expect(stored.file("a.txt") == Data("stored text".utf8))
        #expect(stored.file("dir/b.txt") == Data(String(repeating: "b", count: 300).utf8))
        #expect(stored.file("missing") == nil)
        #expect(ZipArchive(Data("not a zip".utf8)) == nil)
        let deflated = try #require(ZipArchive(Data(base64Encoded: "UEsDBBQAAAAIALmNXV0jmjoXugAAADIBAAAPAAAAeGwvd29ya2Jvb2sueG1sjY+9DcIwEIVXsW4ALqSgiJLQ0NAhNjDJhVjEdnTnAOvQwQosBGNg/gR0VPf36b13+XRvO7UlFuNdAeNRAtMy33nerLzfqHh0UkAbQp8hStWS1TLyPbl4aTxbHeLIa5SeSdfSEgXbYZokE7TaOHgqZPyPhm8aU9HMV4MlF54iTJ0OMZq0phf4JFswlvnDTl5VOW2pgOXgBNRjM6/jQ6A4M7HheT0G/GUvp/P1cPyi0y86vdP4tsC3cXkDUEsDBBQAAAAIALmNXV2R8l67pwAAAF4BAAAaAAAAeGwvX3JlbHMvd29ya2Jvb2sueG1sLnJlbHN90MEOgjAMBuBXWfoAFDDxYBicvaovsEBlBBhLuyi+vYuJIsZwavq3+Zq0qOZxUDdi6SanIUtSqMriRIMJMRDbeVFxw4kGG4I/IEptaTSSTJ5cnFwnHk2ILbfoTd2bljBP0z3ytwFrUx0bDXxsMlCXhycNM94n7sUShRgZbilo+ESCr5Il8R7gfyrfpHAe8JfLt7jdwok1TM05cOdaWchV/KZw9bnyCVBLAwQUAAAACAC5jV1d1wliqagAAADsAAAAFAAAAHhsL3NoYXJlZFN0cmluZ3MueG1sXc9BCsIwEAXQq5QcoFNduJA03bgW8QahRhNo2pIZpNu6EcS1hxBcCt4n4jlMaKHi8r8PfxhedLZKjsqhaeqczdKMFYIjUhK8xpxponYJgKVWVmLatKoOzb5xVlKI7gDYOiV3qJUiW8E8yxZgpalZmDGCk1hLqziQ4BDzYCtJf+Yib02pk8HdSKQ6mmSjo/n+6U8X3199fx+7WPzsv1+Pz+08XYDwkfgCUEsDBBQAAAAIALmNXV04nA/VvAAAAFMBAAANAAAAeGwvc3R5bGVzLnhtbG1QywrCMBD8lZC7TSylh5LGgyB47sWDl9BsjZBNSpNK+/emVnyge1lmdnZmWbGb0JIbDOHqXU23Gac7KUKcLTQGIJI0dqGmJsa+Yiy0BlCFzPfg0qTzA6qY4HBhoR9A6bAsoWU55yVDdXVUCjfiAWMgrR9dTBkviqztqBNZFpSsdnuvoaZzqvMG8bzRmhhTIVImBXt6SdGCtc1y5qlLaOo+vYqH9FuxoF8pX5R/lr+p8pfLXxEPU/b+mLwDUEsDBBQAAAAIALmNXV26i2mo7QAAAPgBAAAYAAAAeGwvd29ya3NoZWV0cy9zaGVldDEueG1sbZHBTsQgFEV/peED+lraamIoE53ZzMLVxA/AipZYoAHC+Pm+0gl2GnfwDpd7Auzwo6ciSueVNT2py4ocOLta9+1HKUOB1PiejCHMTwB+GKUWvrSzNEg+rdMi4NZ9gZ+dFB8ppCegVfUAWihDOEuzkwiCM2evhcMWnA7L4rkmReiJx33kFYPIGQw39rJl9T07rUyZSRl5CQ7PKM9Z4Oc0YRDw8DJZEoCtuZrmarq5nu6qkflVM/K2o81O7bhm3/9VW7NNYk3ZZXqn0WaNdqPR7DTadBX90ygfu53JLZ6eIPL+8va6K4TN80P+V/4LUEsDBBQAAAAIALmNXV3cjxhiZwAAAHoAAAAYAAAAeGwvd29ya3NoZWV0cy9zaGVldDIueG1sPYxBDoMwDAS/gvIAHHrggEK49CNWcQkCJ5Ft0T6/EYceZ0c7Yfny2V0kupc8u6H3bonhU+TQRGRds1lnl8zqBKCvRIzal0q5mXcRRmsoG2gVwvU+8QkP70dg3LOL4d6eaAgxwL8cf1BLAQIUAxQAAAAIALmNXV0jmjoXugAAADIBAAAPAAAAAAAAAAAAAACAAQAAAAB4bC93b3JrYm9vay54bWxQSwECFAMUAAAACAC5jV1dkfJeu6cAAABeAQAAGgAAAAAAAAAAAAAAgAHnAAAAeGwvX3JlbHMvd29ya2Jvb2sueG1sLnJlbHNQSwECFAMUAAAACAC5jV1d1wliqagAAADsAAAAFAAAAAAAAAAAAAAAgAHGAQAAeGwvc2hhcmVkU3RyaW5ncy54bWxQSwECFAMUAAAACAC5jV1dOJwP1bwAAABTAQAADQAAAAAAAAAAAAAAgAGgAgAAeGwvc3R5bGVzLnhtbFBLAQIUAxQAAAAIALmNXV26i2mo7QAAAPgBAAAYAAAAAAAAAAAAAACAAYcDAAB4bC93b3Jrc2hlZXRzL3NoZWV0MS54bWxQSwECFAMUAAAACAC5jV1d3I8YYmcAAAB6AAAAGAAAAAAAAAAAAAAAgAGqBAAAeGwvd29ya3NoZWV0cy9zaGVldDIueG1sUEsFBgAAAAAGAAYAjgEAAEcFAAAAAA==")!))
        #expect(deflated.file("xl/sharedStrings.xml").map { String(decoding: $0, as: UTF8.self).contains("ふりがな") } == true)
    }

    @Test func spreadsheetCells() throws {
        let book = try #require(Spreadsheet(xlsx: Data(base64Encoded: "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")!))
        #expect(book.sheets.map(\.name) == ["Runs", "空表"])
        #expect(book.sheets[0].rows == [
            ["Name", "Date", "", "Inline"],
            ["Rich text", "2023-10-31", "TRUE", "3.5"],
            [],
            ["中文", "2023-10-31 18:00:00", "=SUM"],
        ])
        #expect(book.sheets[1].rows.isEmpty)
    }

    @Test func dateFormats() {
        #expect(Spreadsheet.dateStyle(of: "yyyy\\-mm\\-dd") == .date)
        #expect(Spreadsheet.dateStyle(of: "[h]:mm:ss") == .time)
        #expect(Spreadsheet.dateStyle(of: "m/d/yy h:mm") == .dateTime)
        #expect(Spreadsheet.dateStyle(of: "0.00\" days\"") == nil)
        #expect(Spreadsheet.dateStyle(of: "#,##0") == nil)
        #expect(Spreadsheet.formatDate(60, .date, date1904: false) == "1900-02-28")
        #expect(Spreadsheet.formatDate(0, .date, date1904: true) == "1904-01-01")
        #expect(Spreadsheet.formatDate(0.5, .time, date1904: false) == "12:00:00")
    }

    @Test func presentationText() throws {
        let deck = try #require(Presentation(pptx: Self.pptx))
        #expect(deck.slides.count == 2)
        #expect(deck.slides[0].title == "Plan 计划")
        #expect(deck.slides[0].paragraphs == [.init(level: 0, text: "Goals"), .init(level: 1, text: "Ship it"),
                                              .init(level: 0, text: "Free text")])
        #expect(deck.slides[0].notes == ["Say hello"])
        #expect(deck.slides[1].title == "Second")
        #expect(deck.slides[1].paragraphs.isEmpty)
        #expect(deck.slides[1].notes.isEmpty)
    }

    @Test func notebookAsMarkdown() throws {
        let json = """
        {"metadata": {"language_info": {"name": "python"}}, "nbformat": 4, "cells": [
          {"cell_type": "markdown", "source": ["# Title\\n", "Some *text*"]},
          {"cell_type": "code", "source": "print('```')", "outputs": [
            {"output_type": "stream", "text": ["hi\\n"]},
            {"output_type": "display_data", "data": {"image/png": "iVBO\\nRw0K", "text/plain": ["<Figure>"]}},
            {"output_type": "error", "ename": "E", "evalue": "v", "traceback": ["\\u001b[0;31mValueError\\u001b[0m: bad"]}
          ]}
        ]}
        """
        let markdown = try #require(Notebook.markdown(json))
        #expect(markdown == """
        # Title
        Some *text*

        ````python
        print('```')
        ````

        > ```
        > hi
        > ```
        >
        > ![output](data:image/png;base64,iVBORw0K)
        >
        > ```
        > ValueError: bad
        > ```

        """)
        #expect(Notebook.markdown(#"{"cells": 3}"#) == nil)
    }

    @Test func hexDumpMatchesHexdumpC() {
        let data = Data("ELF".utf8) + Data([0, 1, 2]) + Data("hello world, bytes!".utf8)
        #expect(HexDump.format(data) == """
        00000000  45 4c 46 00 01 02 68 65  6c 6c 6f 20 77 6f 72 6c  |ELF...hello worl|
        00000010  64 2c 20 62 79 74 65 73  21                       |d, bytes!|
        """)
    }

    @Test func compressedTextIsCutPastTheCap() throws {
        let out = "@@size 40\n@@stream\n" + Data("abcdef".utf8).base64EncodedString()
        #expect(try RemoteFileService.parseRead(out, format: .compressed(tool: "gzip"), cap: 5).get()
            == .text("abcde", truncated: true, byteCount: nil))
        let small = "@@size 40\n@@stream\n" + Data("abc".utf8).base64EncodedString()
        #expect(try RemoteFileService.parseRead(small, format: .compressed(tool: "gzip"), cap: 5).get()
            == .text("abc", truncated: false, byteCount: nil))
        let binary = "@@size 40\n@@stream\n" + Data([1, 0, 2]).base64EncodedString()
        #expect(try RemoteFileService.parseRead(binary, format: .compressed(tool: "xz"), cap: 5).get()
            == .binary(Data([1, 0, 2]), byteCount: nil))
    }

    @Test func documentsAreWholeOrTooLarge() throws {
        let data = Data([0x50, 0x4B, 0x03, 0x04])
        #expect(try RemoteFileService.parseRead("@@size 4\n" + data.base64EncodedString(), format: .document(.word), cap: 10).get()
            == .document(data))
        #expect(try RemoteFileService.parseRead("@@size 99\n", format: .document(.video), cap: 10).get()
            == .tooLarge(byteCount: 99))
    }

    @Test func archiveListing() throws {
        let out = "@@size 900\n12\t2026-10-29 10:00\tsrc/a.txt\n0\t2026-10-29 10:00\tsrc/\n@@total 3\n"
        #expect(try RemoteFileService.parseRead(out, format: .archive, cap: 1).get() == .archive([
            ArchiveEntry(name: "src/a.txt", size: 12, modified: "2026-10-29 10:00"),
            ArchiveEntry(name: "src/", size: 0, modified: "2026-10-29 10:00"),
        ], total: 3))
        let more = "@@size 900\n1\t2026-10-29 10:00\ta\n@@total more\n"
        guard case let .archive(_, total) = try RemoteFileService.parseRead(more, format: .archive, cap: 1).get() else {
            Issue.record("expected a listing"); return
        }
        #expect(total == nil)
        #expect(try RemoteFileService.parseRead("@@size 9\n@@raw\nlisting\n", format: .archive, cap: 1).get()
            == .text("listing\n", truncated: false, byteCount: nil))
        #expect((try? RemoteFileService.parseRead("@@size 9\n@@err not an archive\n", format: .archive, cap: 1).get()) == nil)
    }

    @Test func speakerNotesAreLeftOutForQuickLook() throws {
        let stripped = try #require(PresentationPackage.withoutSpeakerNotes(Self.pptx))
        let before = try #require(ZipArchive(Self.pptx)), after = try #require(ZipArchive(stripped))
        #expect(before.orderedNames.contains { $0.hasPrefix("ppt/notesSlides/") })
        #expect(!after.orderedNames.contains { $0.hasPrefix("ppt/notesSlides/") })
        #expect(after.file("ppt/slides/_rels/slide2.xml.rels").map { String(decoding: $0, as: UTF8.self).contains("notesSlide") } == false)
        for name in after.orderedNames where !name.hasSuffix(".rels") {
            #expect(after.file(name) == before.file(name))
        }
        let deck = try #require(Presentation(pptx: stripped))
        #expect(deck.slides.map(\.title) == ["Plan 计划", "Second"])
        #expect(deck.slides.allSatisfy { $0.notes.isEmpty })
        // Nothing to take out: the deck is used as it is.
        #expect(PresentationPackage.withoutSpeakerNotes(stripped) == nil)
        #expect(PresentationPackage.withoutSpeakerNotes(Data("not a zip".utf8)) == nil)
    }

    @Test func crc32MatchesTheStandard() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
