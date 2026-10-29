import AppKit
import ObjectiveC
import SwiftUI

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
}

/// A finished attributed text in a preview text view.
struct TextPreview: NSViewRepresentable {
    let text: NSAttributedString
    var wraps = true

    func makeNSView(context: Context) -> NSScrollView {
        PreviewTextView.makeScrollView(wraps: wraps)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Only a new text resets the view (and its scroll position and find).
        guard context.coordinator.text !== text, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = text
        tv.textStorage?.setAttributedString(text)
        tv.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var text: NSAttributedString? }
}

/// An attributed text built off the main thread (Markdown and tables can take
/// a moment), with a spinner until it is ready.
struct RenderedTextPreview: View {
    /// What the text is built from; a new source builds it again.
    let source: String
    var wraps = true
    let render: @Sendable (String) -> NSAttributedString

    @State private var rendered: Rendered?

    private struct Rendered: @unchecked Sendable {
        let source: String
        let text: NSAttributedString
    }

    var body: some View {
        Group {
            if let rendered, rendered.source == source {
                TextPreview(text: rendered.text, wraps: wraps)
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
