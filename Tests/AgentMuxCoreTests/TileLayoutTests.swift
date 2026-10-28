@testable import AgentMuxCore
import CoreGraphics
import Testing

/// The tiled detail view's arrangement: side by side on a landscape area,
/// stacked on a portrait one, never squeezing a tile below a usable width
/// when another arrangement avoids it.
@Suite struct TileLayoutTests {
    /// A 15 pt monospaced cell.
    private let cell = CGSize(width: 9, height: 19)
    private let landscape = CGSize(width: 1536, height: 1050)
    private let portrait = CGSize(width: 1140, height: 2440)

    private func best(_ count: Int, _ size: CGSize, current: TileLayout.Arrangement? = nil) -> TileLayout.Arrangement {
        TileLayout.best(count: count, in: size, cell: cell, chrome: 24, gap: 1, current: current)
    }

    @Test func landscapePutsTwoSideBySide() {
        #expect(best(2, landscape) == .init(.columns, [1, 1]))
    }

    @Test func landscapeGivesThreeOneTallAndTwoStacked() {
        #expect(best(3, landscape) == .init(.columns, [1, 2]))
    }

    @Test func landscapeGivesFourAGrid() {
        #expect(best(4, landscape) == .init(.rows, [2, 2]))
    }

    @Test func portraitStacksEveryCount() {
        #expect(best(2, portrait) == .init(.rows, [1, 1]))
        #expect(best(3, portrait) == .init(.rows, [1, 1, 1]))
        #expect(best(4, portrait) == .init(.rows, [1, 1, 1, 1]))
    }

    @Test func smallWindowStacksRatherThanSqueezeColumns() {
        // Side by side would leave each tile ~44 columns wide.
        #expect(best(2, CGSize(width: 800, height: 640)) == .init(.rows, [1, 1]))
    }

    @Test func keepsTheCurrentArrangementNearAThreshold() {
        // Side by side wins here (79 columns × 50 rows against 100 × 29), but
        // by less than 10%, so an existing stacked layout is kept rather than
        // flipping every remote window.
        let size = CGSize(width: 1440, height: 1160)
        #expect(best(2, size) == .init(.columns, [1, 1]))
        #expect(best(2, size, current: .init(.rows, [1, 1])) == .init(.rows, [1, 1]))
        // Clearly better wins anyway.
        #expect(best(2, landscape, current: .init(.rows, [1, 1])) == .init(.columns, [1, 1]))
    }

    @Test func framesTileTheAreaWithGaps() {
        let rect = CGRect(x: 0, y: 0, width: 1001, height: 601)
        let frames = TileLayout.frames(.init(.columns, [1, 2]), in: rect, gap: 1)
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 500, height: 601),
            CGRect(x: 501, y: 0, width: 500, height: 300),
            CGRect(x: 501, y: 301, width: 500, height: 300),
        ])
    }

    @Test func gridFillsInReadingOrder() {
        let frames = TileLayout.frames(.init(.rows, [2, 2]), in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
    }

    @Test func oneTileFillsTheArea() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(best(1, rect.size) == .init(.columns, [1]))
        #expect(TileLayout.frames(.init(.columns, [1]), in: rect) == [rect])
    }
}
