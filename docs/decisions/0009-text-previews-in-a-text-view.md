# ADR 0009: Text Previews in a Text View, with Find

Date: 2026-10-29. Status: accepted. Checked in a separate test app (not AgentMux, which mirrors live agents): with the file list focused, the Find menu reaches the preview and opens the find bar; Markdown and CSV render as intended in light and dark; a 200 KB Markdown file renders in ~0.3 s off the main thread and scrolls with every step under 9 ms.

## Context

The Files window previews code, Markdown, CSV/TSV, SVG, PDF and images. ⌘F worked only in code previews and PDFs, and only after clicking into the preview: right after picking a file the list has the keyboard, the preview is outside the responder chain, and the Find menu was disabled. Rendered Markdown (swift-markdown-ui) and CSV (a SwiftUI grid) had no find at all and built every block as a SwiftUI view, so long files scrolled with visible stutter.

## Decision

- **One text view for every text preview.** Code, rendered Markdown and CSV/TSV all show in `PreviewTextView`, a read-only TextKit 1 NSTextView with the system find bar, laying out only what is on screen. Markdown and CSV are built into an attributed string off the main thread.
- **Markdown** is parsed by Foundation (`AttributedString(markdown:)`, CommonMark plus GitHub tables, strikethrough and autolinks) and drawn with paragraph styles and NSTextBlocks: quotes get a left rule, code a tinted box, tables an NSTextTable. Task list items get boxes. Raw HTML shows its text without tags; an image shows as its alt text (a preview reads only the file it shows). This replaces swift-markdown-ui, which also drops three packages.
- **CSV/TSV** become aligned columns on tab stops, with quoted fields parsed properly, all loaded rows rather than the first 1000.
- **Rendered / Source.** Markdown, CSV/TSV and SVG switch to their highlighted source, like GitHub's Preview / Code. A rendered SVG is an image and has no find; its source does.
- **Find from the list.** `PreviewFindRelay` puts a responder right after the window in its responder chain that forwards the Find menu's actions to the preview on screen. Anything focused that handles find itself still answers first, and without a preview the actions pass on as before.

## Consequences

- NSTextBlock quirks shape the renderer: a block with no width wraps every character, so each block is set to 100%; a block's margin is painted with its background, so indents and the gap below a block are the padding of a clear block around it; and nested blocks' bottoms don't add up, so that gap includes the inner block's own bottom.
- Rendered Markdown no longer loads remote images (swift-markdown-ui fetched them over the network); links still open in the browser.
