import AgentMuxCore
import AppKit
import ObjectiveC
import SwiftUI

extension NSAttributedString.Key {
    /// A place a link can lead to in a preview (`#name`): a heading's slug,
    /// or an HTML anchor's name.
    static let previewAnchor = NSAttributedString.Key("AgentMuxPreviewAnchor")
}

/// What a preview does with a clicked link: resolve it against the file shown
/// and hand it to the window (open a file, a folder, a web page).
struct PreviewLinks {
    /// The previewed file, which relative links resolve against.
    let path: String
    let open: (PreviewLink) -> Void

    /// Follows `link`; without a window to follow it, only a web page opens.
    static func follow(_ link: PreviewLink, with links: PreviewLinks?) {
        if let links {
            links.open(link)
        } else if case let .web(url) = link {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }
}

private struct PreviewLinksKey: EnvironmentKey {
    static var defaultValue: PreviewLinks? { nil }
}

extension EnvironmentValues {
    var previewLinks: PreviewLinks? {
        get { self[PreviewLinksKey.self] }
        set { self[PreviewLinksKey.self] = newValue }
    }
}

/// The text view behind every text preview (code, Markdown, tables): read-only,
/// selectable, with the system find bar. TextKit 1, because rendered Markdown
/// draws quotes, code boxes and tables as NSTextBlocks, which TextKit 2 does
/// not lay out. The Files window's find relay looks for this class.
final class PreviewTextView: NSTextView {
    /// A scroll view around a new preview text view. Wrapping text follows the
    /// view's width; otherwise lines run on and the view scrolls sideways.
    static func makeScrollView(wraps: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wraps
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = PreviewTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = !wraps
        tv.autoresizingMask = wraps ? [.width] : []
        tv.textContainer?.widthTracksTextView = wraps
        if !wraps {
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        }
        // Lay out only what is on screen, so a long file opens and scrolls
        // without laying out all of it first.
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        scroll.documentView = tv
        return scroll
    }

    /// Scrolls a place to the top and flashes it: a heading or an HTML
    /// anchor (matched as written, then as GitHub would slug it), or lines
    /// (`L12`, `L12-L20`). An empty name is the top. False when the text has
    /// no such place.
    @discardableResult
    func scrollToAnchor(_ name: String) -> Bool {
        guard let storage = textStorage else { return false }
        guard !name.isEmpty else {
            scroll(.zero)
            return true
        }
        var anchors: [(name: String, range: NSRange)] = []
        storage.enumerateAttribute(.previewAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value = value as? String { anchors.append((value, range)) }
        }
        let candidates = [name, name.lowercased(), PreviewLink.slug(name)]
        if let range = candidates.lazy.compactMap({ c in anchors.first { $0.name == c }?.range }).first {
            return scrollTo(range)
        }
        if let lines = PreviewLink.lines(name), let range = range(ofLines: lines) {
            return scrollTo(range)
        }
        return false
    }

    /// The characters of `lines` (first line 1), as far as the text goes.
    private func range(ofLines lines: ClosedRange<Int>) -> NSRange? {
        let string = self.string as NSString
        var line = 1, start = 0
        var first: Int?
        while start < string.length {
            let range = string.lineRange(for: NSRange(location: start, length: 0))
            if line == lines.lowerBound { first = range.location }
            if line == lines.upperBound || NSMaxRange(range) >= string.length {
                return first.map { NSRange(location: $0, length: NSMaxRange(range) - $0) }
            }
            line += 1
            start = NSMaxRange(range)
        }
        return nil
    }

    private func scrollTo(_ range: NSRange) -> Bool {
        guard let storage = textStorage, let layoutManager, let textContainer,
              let clip = enclosingScrollView?.contentView else { return false }
        // Lay out everything above it, so the position is exact, and a
        // screenful below, so a place near the end scrolls as far as it can.
        let below = min(storage.length, NSMaxRange(range) + 20_000)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: below))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let top = NSPoint(x: clip.bounds.minX, y: max(0, rect.minY + textContainerOrigin.y - 8))
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: top, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        showFindIndicator(for: range)
        return true
    }
}

/// A finished attributed text in a preview text view. Its links follow the
/// environment's `previewLinks`; a link to a place in the text scrolls there.
struct TextPreview: NSViewRepresentable {
    let text: NSAttributedString
    var wraps = true
    /// The place to show first (`#name` of a link that led here), if any.
    var anchor: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewTextView.makeScrollView(wraps: wraps)
        (scroll.documentView as? NSTextView)?.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.links = context.environment.previewLinks
        // Only a new text resets the view (and its scroll position and find).
        guard context.coordinator.text !== text, let tv = scroll.documentView as? PreviewTextView else { return }
        context.coordinator.text = text
        tv.textStorage?.setAttributedString(text)
        tv.scroll(.zero)
        if let anchor {
            // Once the view has its size from this update's layout.
            Task { @MainActor in tv.scrollToAnchor(anchor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: NSAttributedString?
        var links: PreviewLinks?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let href = (link as? URL)?.absoluteString ?? link as? String else { return false }
            switch PreviewLink.resolve(href, from: links?.path ?? "/") {
            case let .anchor(name):
                if (textView as? PreviewTextView)?.scrollToAnchor(name) != true { NSSound.beep() }
            case let target:
                PreviewLinks.follow(target, with: links)
            }
            return true
        }
    }
}

/// An attributed text built off the main thread (Markdown and tables can take
/// a moment), with a spinner until it is ready.
struct RenderedTextPreview: View {
    /// What the text is built from; a new source builds it again.
    let source: String
    var wraps = true
    var anchor: String?
    let render: @Sendable (String) -> NSAttributedString

    @State private var rendered: Rendered?

    private struct Rendered: @unchecked Sendable {
        let source: String
        let text: NSAttributedString
    }

    var body: some View {
        Group {
            if let rendered, rendered.source == source {
                TextPreview(text: rendered.text, wraps: wraps, anchor: anchor)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) {
            let source = source, render = render
            rendered = await Task.detached(priority: .userInitiated) {
                Rendered(source: source, text: render(source))
            }.value
        }
    }
}

/// Lets the Find menu (⌘F, ⌘G, ⇧⌘G, ⌘E) reach a window's file preview while
/// the file list has the keyboard, so a file can be searched right after
/// picking it. A responder placed right after the window in its responder
/// chain: a focused view that handles find itself (the preview, a text field
/// in a sheet) still answers first.
struct PreviewFindRelay: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        private let relay = Relay()

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            relay.detach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { relay.attach(to: window) }
        }
    }

    final class Relay: NSResponder, NSUserInterfaceValidations {
        private weak var window: NSWindow?
        /// The window holds the relay while it is in the chain, since
        /// `nextResponder` does not retain: a relay freed first would leave
        /// the window pointing at freed memory.
        private nonisolated(unsafe) static var ownerKey: UInt8 = 0

        func attach(to window: NSWindow) {
            self.window = window
            nextResponder = window.nextResponder
            window.nextResponder = self
            objc_setAssociatedObject(window, &Self.ownerKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        func detach() {
            guard let window else { return }
            var link: NSResponder = window
            while let next = link.nextResponder {
                if next === self {
                    link.nextResponder = nextResponder
                    break
                }
                link = next
            }
            nextResponder = nil
            self.window = nil
            objc_setAssociatedObject(window, &Self.ownerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        private static let actions: Set<Selector> = [
            #selector(NSResponder.performTextFinderAction(_:)),
            #selector(NSTextView.performFindPanelAction(_:)),
        ]

        /// The preview showing in this window, if it can find: the first
        /// preview text view or PDF in the window's views.
        private var target: NSView? {
            func search(_ view: NSView) -> NSView? {
                if view.isHidden { return nil }
                if view is PreviewTextView || view is FindablePDFView { return view }
                for subview in view.subviews {
                    if let found = search(subview) { return found }
                }
                return nil
            }
            return window?.contentView.flatMap(search)
        }

        // Without a preview the actions pass on, as if this were not here.
        override func responds(to selector: Selector!) -> Bool {
            if let selector, Self.actions.contains(selector) { return target != nil }
            return super.responds(to: selector)
        }

        override func performTextFinderAction(_ sender: Any?) {
            forward(#selector(NSResponder.performTextFinderAction(_:)), sender)
        }

        @objc func performFindPanelAction(_ sender: Any?) {
            forward(#selector(NSTextView.performFindPanelAction(_:)), sender)
        }

        private func forward(_ action: Selector, _ sender: Any?) {
            guard let target else { return }
            NSApp.sendAction(action, to: target, from: sender)
        }

        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? false
        }
    }
}
