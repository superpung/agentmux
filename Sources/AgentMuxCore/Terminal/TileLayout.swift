import CoreGraphics

/// Arranges several terminals in one area. An arrangement splits the area
/// into equal lines (columns or rows) and each line into equal tiles. The
/// pick keeps the worst tile as usable as possible for an agent's TUI, which
/// gains little past ~100 columns or ~50 rows and suffers far more from too
/// few columns than from too few rows.
public enum TileLayout {
    public static let maxTiles = 4

    public enum Axis: Sendable, Equatable {
        /// Lines are columns, left to right; each is split top to bottom.
        case columns
        /// Lines are rows, top to bottom; each is split left to right.
        case rows
    }

    public struct Arrangement: Sendable, Equatable {
        public var axis: Axis
        /// Tiles per line, in order.
        public var lines: [Int]

        public init(_ axis: Axis, _ lines: [Int]) {
            self.axis = axis
            self.lines = lines
        }

        public var count: Int { lines.reduce(0, +) }
    }

    /// The arrangements tried for `count` tiles, most preferred first (ties
    /// go to the earlier one). Tiles fill them in reading order.
    public static func candidates(for count: Int) -> [Arrangement] {
        switch count {
        case ...1: [Arrangement(.columns, [1])]
        case 2: [Arrangement(.columns, [1, 1]), Arrangement(.rows, [1, 1])]
        case 3: [
            Arrangement(.columns, [1, 2]),
            Arrangement(.columns, [1, 1, 1]),
            Arrangement(.rows, [1, 2]),
            Arrangement(.rows, [1, 1, 1]),
        ]
        default: [
            Arrangement(.rows, [2, 2]),
            Arrangement(.columns, [1, 1, 1, 1]),
            Arrangement(.rows, [1, 1, 1, 1]),
        ]
        }
    }

    /// Each tile's rect, in tile order, `gap` points apart, on whole points so
    /// no surface gets a fractional size.
    public static func frames(_ arrangement: Arrangement, in rect: CGRect, gap: CGFloat = 0) -> [CGRect] {
        let lineRects = split(rect, into: arrangement.lines.count, alongX: arrangement.axis == .columns, gap: gap)
        return zip(lineRects, arrangement.lines).flatMap { line, count in
            split(line, into: count, alongX: arrangement.axis == .rows, gap: gap)
        }
    }

    /// How usable a tile is, from 0 to 1: width up to 100 columns counts
    /// quadratically, height up to 50 rows linearly.
    public static func usability(_ size: CGSize, cell: CGSize) -> Double {
        guard cell.width > 0, cell.height > 0 else { return 0 }
        let columns = min(100, max(0, (size.width / cell.width).rounded(.down)))
        let rows = min(50, max(0, (size.height / cell.height).rounded(.down)))
        return (columns / 100) * (columns / 100) * (rows / 50)
    }

    /// The best arrangement of `count` tiles for an area of `size`. Each
    /// tile loses `chrome` points of height to its header. The `current`
    /// arrangement is kept unless another is clearly better, so resizing the
    /// window does not flip the layout (and every remote window) back and
    /// forth near a threshold.
    public static func best(count: Int, in size: CGSize, cell: CGSize, chrome: CGFloat = 0, gap: CGFloat = 0,
                            current: Arrangement? = nil) -> Arrangement {
        let candidates = candidates(for: count)
        let rect = CGRect(origin: .zero, size: size)
        func score(_ arrangement: Arrangement) -> (worst: Double, mean: Double) {
            let values = frames(arrangement, in: rect, gap: gap).map {
                usability(CGSize(width: $0.width, height: $0.height - chrome), cell: cell)
            }
            return (values.min() ?? 0, values.reduce(0, +) / Double(max(1, values.count)))
        }
        var best = candidates[0]
        var bestScore = score(best)
        for candidate in candidates.dropFirst() {
            let s = score(candidate)
            // Worst tile first; the mean only breaks near-ties.
            if s.worst > bestScore.worst + 0.01
                || (abs(s.worst - bestScore.worst) <= 0.01 && s.mean > bestScore.mean + 0.01) {
                best = candidate
                bestScore = s
            }
        }
        if let current, current != best, candidates.contains(current),
           score(current).worst >= bestScore.worst * 0.9 {
            return current
        }
        return best
    }

    private static func split(_ rect: CGRect, into count: Int, alongX: Bool, gap: CGFloat) -> [CGRect] {
        guard count > 1 else { return [rect.integral] }
        let total = alongX ? rect.width : rect.height
        let length = (total - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            let start = (CGFloat(i) * (length + gap)).rounded()
            let end = i == count - 1 ? total : (CGFloat(i) * (length + gap) + length).rounded()
            return alongX
                ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
        }
    }
}
