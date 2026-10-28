import AppKit
import os
import PDFKit

/// A PDFView with the system find bar. PDFKit's view handles none of the find
/// actions (⌘F, ⌘G, ⇧⌘G, ⌘E), so this wrapper sits right behind it in the
/// responder chain, takes those actions, and is the NSTextFinder client over
/// the document's text. Each page is its own search chunk, so a match never
/// runs across a page break.
///
/// The wrapper is a non-scrolling NSScrollView because NSTextFinder only
/// shows its bar in a scroll view: a custom NSTextFinderBarContainer gets the
/// bar view but is never told to make it visible. The PDFView, which scrolls
/// on its own, always fills the clip view below the bar.
///
/// NSTextFinder calls `string(at:…)` from its background search queue and
/// everything else on the main thread, so the page text it reads is an
/// immutable snapshot behind a lock.
final class FindablePDFView: NSScrollView, @preconcurrency NSTextFinderClient, NSUserInterfaceValidations {
    let pdfView = PDFView()
    private let finder = NSTextFinder()
    /// Built on first use and dropped when the document changes.
    private let textIndex = OSAllocatedUnfairLock<PageText?>(initialState: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        drawsBackground = false
        borderType = .noBorder
        documentView = pdfView
        finder.client = self
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var document: PDFDocument? {
        get { pdfView.document }
        set {
            finder.noteClientStringWillChange()
            textIndex.withLock { $0 = nil }
            pdfView.document = newValue
        }
    }

    override func tile() {
        super.tile()
        pdfView.frame = contentView.bounds
    }

    override var isFindBarVisible: Bool {
        didSet { if oldValue, !isFindBarVisible { window?.makeFirstResponder(pdfView) } }
    }

    // MARK: Find actions

    /// What the Edit ▸ Find menu sends. Its tags match NSTextFinder.Action.
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return }
        finder.performAction(action)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performFindPanelAction(_:))
                || item.action == #selector(performTextFinderAction(_:)) else { return true }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return finder.validateAction(action)
    }

    // MARK: NSTextFinderClient

    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    /// Called on the main thread before a search, which builds the snapshot
    /// the background `string(at:…)` calls read.
    func stringLength() -> Int { pageText().length }

    nonisolated func string(at characterIndex: Int, effectiveRange outRange: NSRangePointer,
                            endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>) -> String {
        outFlag.pointee = true
        guard let text = textIndex.withLock({ $0 }), let i = text.page(at: characterIndex) else {
            outRange.pointee = NSRange(location: characterIndex, length: 0)
            return ""
        }
        outRange.pointee = text.range(ofPage: i)
        return text.texts[i]
    }

    var firstSelectedRange: NSRange {
        let text = pageText()
        if let selection = pdfView.currentSelection, let page = selection.pages.first,
           let i = pageNumber(of: page), selection.numberOfTextRanges(on: page) > 0 {
            let range = selection.range(at: 0, on: page)
            return NSRange(location: text.starts[i] + range.location, length: range.length)
        }
        // Nothing selected: search from the top of the page in view.
        if let page = pdfView.currentPage, let i = pageNumber(of: page) {
            return NSRange(location: text.starts[i], length: 0)
        }
        return NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue else { return }
            pdfView.setCurrentSelection(selection(for: range), animate: false)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        if let selection = selection(for: range) { pdfView.go(to: selection) }
    }

    var visibleCharacterRanges: [NSValue] {
        let text = pageText()
        return pdfView.visiblePages.compactMap { page in
            pageNumber(of: page).map { NSValue(range: text.range(ofPage: $0)) }
        }
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        let text = pageText()
        outRange.pointee = text.page(at: index).map(text.range(ofPage:)) ?? NSRange(location: 0, length: text.length)
        return pdfView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let selection = selection(for: range) else { return nil }
        return selection.selectionsByLine().flatMap { line in
            line.pages.map { NSValue(rect: pdfView.convert(line.bounds(for: $0), from: $0)) }
        }
    }

    /// Draws the matched words for the find indicator and the dimmed
    /// incremental-search overlay. PDFKit renders pages in its own subviews,
    /// so drawing the content view would leave these blank.
    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let selection = selection(for: range), let page = selection.pages.first,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let box = pdfView.displayBox
        // Page space to view space, read off the view's own conversion so
        // scale, scroll and flipping all match what is on screen.
        let origin = pdfView.convert(CGPoint.zero, from: page)
        let unitX = pdfView.convert(CGPoint(x: 100, y: 0), from: page)
        let unitY = pdfView.convert(CGPoint(x: 0, y: 100), from: page)
        let pageToView = CGAffineTransform(a: (unitX.x - origin.x) / 100, b: (unitX.y - origin.y) / 100,
                                           c: (unitY.x - origin.x) / 100, d: (unitY.y - origin.y) / 100,
                                           tx: origin.x, ty: origin.y)
        context.saveGState()
        context.clip(to: selection.selectionsByLine().map { pdfView.convert($0.bounds(for: page), from: page) })
        context.concatenate(pageToView)
        // draw(with:to:) applies the page's own box transform; undo it so the
        // drawing stays in page space.
        context.concatenate(page.transform(for: box).inverted())
        page.draw(with: box, to: context)
        context.restoreGState()
    }

    // MARK: Text index

    private func pageText() -> PageText {
        if let built = textIndex.withLock({ $0 }) { return built }
        let built = PageText(pdfView.document)
        textIndex.withLock { $0 = built }
        return built
    }

    private func pageNumber(of page: PDFPage) -> Int? {
        guard let i = pdfView.document?.index(for: page), i >= 0, i < pageText().starts.count else { return nil }
        return i
    }

    private func selection(for range: NSRange) -> PDFSelection? {
        let text = pageText()
        guard range.length > 0, let i = text.page(at: range.location),
              let page = pdfView.document?.page(at: i) else { return nil }
        let location = range.location - text.starts[i]
        return page.selection(for: NSRange(location: location, length: min(range.length, text.lengths[i] - location)))
    }
}

/// A document's text as NSTextFinder sees it: one chunk per page, laid end to
/// end, in UTF-16 offsets like the NSRanges PDFPage takes.
private struct PageText: Sendable {
    let starts: [Int]
    let lengths: [Int]
    let texts: [String]

    init(_ document: PDFDocument?) {
        let texts = (0..<(document?.pageCount ?? 0)).map { document?.page(at: $0)?.string ?? "" }
        var starts: [Int] = [], start = 0
        for text in texts {
            starts.append(start)
            start += text.utf16.count
        }
        self.texts = texts
        self.starts = starts
        lengths = texts.map(\.utf16.count)
    }

    var length: Int { (starts.last ?? 0) + (lengths.last ?? 0) }

    func range(ofPage i: Int) -> NSRange { NSRange(location: starts[i], length: lengths[i]) }

    /// The page whose text holds `location`. An empty page shares its start
    /// with the next page, so the last page starting at or before it wins.
    func page(at location: Int) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        let i = low - 1
        guard i >= 0, location < starts[i] + lengths[i] else { return nil }
        return i
    }
}
