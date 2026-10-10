@testable import AgentMuxCore
import Foundation
import Testing

@Suite struct ControlParserTests {
    private func feed(_ text: String, in chunks: Int = 1) throws -> [ControlEvent] {
        var parser = ControlParser()
        let bytes = Array(text.utf8)
        let size = max(1, bytes.count / chunks)
        var events: [ControlEvent] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            events += try parser.feed(Data(bytes[index ..< end]))
            index = end
        }
        return events
    }

    @Test func repliesAndOwnership() throws {
        let events = try feed("%begin 1 10 0\n%end 1 10 0\n%begin 1 11 1\none\ntwo\n%end 1 11 1\n%begin 1 12 1\nbad\n%error 1 12 1\n")
        #expect(events == [
            .reply(.init(number: 10, fromThisClient: false, success: true, lines: [])),
            .reply(.init(number: 11, fromThisClient: true, success: true, lines: [Data("one".utf8), Data("two".utf8)])),
            .reply(.init(number: 12, fromThisClient: true, success: false, lines: [Data("bad".utf8)])),
        ])
    }

    @Test func replyContentThatLooksLikeAnEndLineIsContent() throws {
        let events = try feed("%begin 5 20 1\n%end 5 19 1\n%output %1 x\n%end 5 20 1\n")
        #expect(events == [.reply(.init(
            number: 20, fromThisClient: true, success: true,
            lines: [Data("%end 5 19 1".utf8), Data("%output %1 x".utf8)]
        ))])
    }

    @Test func outputIsUnescapedToBytes() throws {
        let events = try feed("%output %3 a\\015\\012\\033[1m\\134b 中\n")
        #expect(events == [.output(paneID: "%3", data: Data("a\r\n\u{1B}[1m\\b 中".utf8))])
    }

    @Test func extendedOutput() throws {
        let events = try feed("%extended-output %7 120 : hi\\012\n")
        #expect(events == [.output(paneID: "%7", data: Data("hi\n".utf8))])
    }

    @Test func notificationsAndExit() throws {
        let events = try feed("%session-changed $1 work\n%pause %2\n%exit detached\n")
        #expect(events == [
            .notification(name: "session-changed", arguments: "$1 work"),
            .notification(name: "pause", arguments: "%2"),
            .exit(reason: "detached"),
        ])
    }

    @Test func linesSplitAcrossReadsAreJoined() throws {
        let text = "%begin 1 11 1\nline\n%end 1 11 1\n%output %0 abc\\033[0m\n"
        #expect(try feed(text, in: 1) == feed(text, in: text.utf8.count))
    }

    @Test func unescapeLeavesIncompleteSequences() {
        #expect(ControlParser.unescape(Data("\\01".utf8)) == Data("\\01".utf8))
        #expect(ControlParser.unescape(Data("\\9xy".utf8)) == Data("\\9xy".utf8))
    }
}

@Suite struct TmuxQuoteTests {
    @Test func escapesWhatTmuxWouldInterpret() {
        #expect(TmuxQuote.word("a$HOME b\"q\" c\\d\ne\tf") == "\"a\\$HOME b\\\"q\\\" c\\\\d\\ne\\tf\"")
        #expect(TmuxQuote.word("\u{1B}[A\u{01}") == "\"\\e[A\\001\"")
        #expect(TmuxQuote.word("中文 ;{}#~") == "\"中文 ;{}#~\"")
    }

    @Test func idsAreValidated() {
        #expect(TmuxQuote.id("%12") == "'%12'")
        #expect(TmuxQuote.id("$3") == "'$3'")
        #expect(TmuxQuote.id("%1;kill-server") == nil)
        #expect(TmuxQuote.id("%") == nil)
        #expect(TmuxQuote.id("12") == nil)
    }
}

@Suite struct PaneMirrorSyncTests {
    private let header = "80 24 3 5 0 1 0 1 0 0 1 0 1 0 0 23 1"

    @Test func parsesStateAndBuildsInitialScreen() throws {
        let state = try #require(PaneMirror.parseSync(
            state: [Data(header.utf8)],
            savedNormal: [Data()],
            visible: [Data("$ ls".utf8), Data("\u{1B}[31mred\u{1B}[0m".utf8)]
        ))
        #expect(state.geometry == .init(columns: 80, rows: 24))
        #expect(state.cursorX == 3 && state.cursorY == 5)
        #expect(!state.alternate)
        let bytes = String(decoding: state.initialBytes(), as: UTF8.self)
        #expect(bytes.hasPrefix("\u{1B}c"))
        #expect(bytes.contains("\u{1B}[1;1H$ ls"))
        #expect(bytes.contains("\u{1B}[2;1H\u{1B}[31mred"))
        #expect(bytes.contains("\u{1B}[?1h"))     // keypad cursor mode
        #expect(bytes.contains("\u{1B}[?1000h"))  // mouse standard
        #expect(!bytes.contains("\u{1B}[?1049h")) // no alternate screen
        #expect(bytes.hasSuffix("\u{1B}[6;4H"))   // cursor last
    }

    @Test func alternateScreenDrawsSavedNormalFirst() throws {
        let alternate = "80 24 0 0 1 0 0 0 0 0 0 0 1 0 0 23 0"
        let state = try #require(PaneMirror.parseSync(
            state: [Data(alternate.utf8)],
            savedNormal: [Data("shell".utf8)],
            visible: [Data("tui".utf8)]
        ))
        let bytes = String(decoding: state.initialBytes(), as: UTF8.self)
        let shell = try #require(bytes.range(of: "shell"))
        let switchToAlternate = try #require(bytes.range(of: "\u{1B}[?1049h"))
        let tui = try #require(bytes.range(of: "tui"))
        #expect(shell.lowerBound < switchToAlternate.lowerBound && switchToAlternate.lowerBound < tui.lowerBound)
        #expect(bytes.contains("\u{1B}[?25l")) // cursor hidden
    }

    @Test func malformedStateIsRejected() {
        #expect(PaneMirror.parseSync(state: [Data("80 x".utf8)], savedNormal: [], visible: []) == nil)
        #expect(PaneMirror.parseSync(state: [], savedNormal: [], visible: []) == nil)
    }
}
