import AppKit
import SwiftUI

extension View {
    /// Joins neighboring selected rows of this List into one highlight after
    /// its rows change (`rows` is anything that changes with them: their
    /// order, which ones there are, the selection).
    ///
    /// SwiftUI's List, an NSTableView, keeps a row view's selection shape
    /// when rows move: two selected rows that end up side by side keep their
    /// own rounded corners and the gap between them, where AppKit draws one
    /// block. Each row view's neighbor flags are set again afterwards.
    func joinsSelectedNeighbors<Rows: Equatable>(_ rows: Rows) -> some View {
        background(SelectedNeighbors(rows: rows))
    }
}

private struct SelectedNeighbors<Rows: Equatable>: NSViewRepresentable {
    let rows: Rows

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        guard probe.rows as? Rows != rows else { return }
        probe.rows = rows
        // After AppKit has applied this update's row changes.
        DispatchQueue.main.async { [weak probe] in probe?.joinNeighbors() }
    }

    final class Probe: NSView {
        var rows: Any?
        private weak var table: NSTableView?

        func joinNeighbors() {
            guard let table = table ?? findTable() else { return }
            self.table = table
            let selected = table.selectedRowIndexes
            table.enumerateAvailableRowViews { rowView, row in
                let previous = selected.contains(row - 1), next = selected.contains(row + 1)
                if rowView.isPreviousRowSelected != previous { rowView.isPreviousRowSelected = previous }
                if rowView.isNextRowSelected != next { rowView.isNextRowSelected = next }
            }
        }

        /// The table this probe sits behind: the nearest one whose scroll
        /// view covers the probe's middle.
        private func findTable() -> NSTableView? {
            guard window != nil else { return nil }
            let middle = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let table = Self.tables(in: view).first(where: { table in
                    guard let scroll = table.enclosingScrollView else { return false }
                    return scroll.convert(scroll.bounds, to: nil).contains(middle)
                }) {
                    return table
                }
                ancestor = view.superview
            }
            return nil
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap(tables)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
