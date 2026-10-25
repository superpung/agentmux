@testable import AgentMuxCore
import Foundation
import Testing

/// Byte-level checks that the outgoing filter removes mouse reports while every
/// real keystroke — arrows, application-cursor, function keys, bare Escape —
/// passes through untouched, including when a report is split across two calls.
@Suite struct MouseReportFilterTests {
    private let esc: UInt8 = 0x1B
    private let bracket: UInt8 = 0x5B
    private let less: UInt8 = 0x3C
    private func text(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func passesPlainTextUnchanged() {
        let input = text("ls -la\r")
        let (kept, carry) = MouseReportFilter.scan(input)
        #expect(kept == input)
        #expect(carry.isEmpty)
    }

    @Test func stripsSGRMousePress() {
        let input: [UInt8] = [esc, bracket, less] + text("0;35;70M")
        let (kept, carry) = MouseReportFilter.scan(input)
        #expect(kept.isEmpty)
        #expect(carry.isEmpty)
    }

    @Test func stripsSGRMouseReleaseKeepingSurroundingText() {
        let input = text("ab") + [esc, bracket, less] + text("0;35;70m") + text("cd")
        let (kept, _) = MouseReportFilter.scan(input)
        #expect(kept == text("abcd"))
    }

    @Test func stripsX10Mouse() {
        let input = text("x") + [esc, bracket, 0x4D, 0x20, 0x21, 0x22] + text("y")
        let (kept, carry) = MouseReportFilter.scan(input)
        #expect(kept == text("xy"))
        #expect(carry.isEmpty)
    }

    @Test func passesArrowKeys() {
        let up: [UInt8] = [esc, bracket, 0x41] // ESC [ A
        let down: [UInt8] = [esc, bracket, 0x42] // ESC [ B
        let (kept, _) = MouseReportFilter.scan(up + down)
        #expect(kept == up + down)
    }

    @Test func passesApplicationCursorAndBareEscape() {
        let appUp: [UInt8] = [esc, 0x4F, 0x41] // ESC O A
        let bareEscape: [UInt8] = [esc]
        let (kept, carry) = MouseReportFilter.scan(appUp + bareEscape)
        #expect(kept == appUp + bareEscape)
        #expect(carry.isEmpty)
    }

    @Test func passesFunctionKey() {
        let home: [UInt8] = [esc, bracket] + text("1~") // ESC [ 1 ~
        let (kept, _) = MouseReportFilter.scan(home)
        #expect(kept == home)
    }

    @Test func stripsMouseKeepsInterleavedKeys() {
        let input: [UInt8] = [esc, bracket, 0x41] // arrow up
            + [esc, bracket, less] + text("0;1;1M") // mouse press
            + text("hi")
            + [esc, bracket, 0x4D, 0x20, 0x21, 0x22] // X10 mouse
        let (kept, _) = MouseReportFilter.scan(input)
        #expect(kept == [esc, bracket, 0x41] + text("hi"))
    }

    @Test func carriesSplitSGRAcrossCalls() {
        let filter = MouseReportFilter()
        let part1: [UInt8] = [esc, bracket, less] + text("0;3")
        let part2: [UInt8] = text("5;70M") + text("ok")
        #expect(filter.strip(Data(part1)).isEmpty)
        #expect(Array(filter.strip(Data(part2))) == text("ok"))
    }

    @Test func carriesSplitX10AcrossCalls() {
        let filter = MouseReportFilter()
        let part1: [UInt8] = [esc, bracket, 0x4D, 0x20] // ESC [ M + 1 of 3
        let part2: [UInt8] = [0x21, 0x22] + text("z")
        #expect(filter.strip(Data(part1)).isEmpty)
        #expect(Array(filter.strip(Data(part2))) == text("z"))
    }

    @Test func dropsOverlongMalformedCarry() {
        // ESC [ < with no terminator and absurd length: dropped, never held forever.
        let input: [UInt8] = [esc, bracket, less] + Array(repeating: 0x31, count: 100)
        let (kept, carry) = MouseReportFilter.scan(input)
        #expect(kept.isEmpty)
        #expect(carry.isEmpty)
    }

    @Test func floodOfReportsAllStripped() {
        // The real-world burst: many SGR reports back to back, nothing kept.
        var input: [UInt8] = []
        for _ in 0 ..< 50 { input += [esc, bracket, less] + text("35;70;17M") }
        let (kept, carry) = MouseReportFilter.scan(input)
        #expect(kept.isEmpty)
        #expect(carry.isEmpty)
    }
}
