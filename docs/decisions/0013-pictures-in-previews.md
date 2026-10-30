# ADR 0013: Pictures in Markdown, Notebook and HTML Previews

Date: 2026-10-30. Status: accepted. Partly supersedes ADR 0009: "an image shows as its alt text (a preview reads only the file it shows)".

Checked in a separate test app (not AgentMux, which mirrors live agents), using the real renderer, text view and web preview, and real files read read-only from a container (system logos under `/usr/share/pixmaps`):
- In a Markdown file, these all show:
  - pictures given by a relative path, an absolute path, and inside a table cell;
  - an `<img width="120">` at that width;
  - a web SVG badge inside a link.
- A missing file keeps its placeholder.
- The container's pictures arrived in about 0.5 s and the web badge later; each appeared as it arrived.
- With the view scrolled down, the line at the top stayed there while pictures above it came in.
- A 640-point picture in a 300-point view shrank to the line, and a click on it followed its link.
- An HTML page showed at once, then again with its pictures.

## Context

Markdown previews showed every picture as an icon and its alt text. ADR 0009 had dropped swift-markdown-ui, which fetched pictures, for a text view with the system find bar, and kept previews to reading the one file shown.

Reports written by agents put their figures next to them (`![](figures/loss.png)`), and READMEs carry badges, so the preview missed what the file was about.

Switching to the mainstream route (cmark-gfm to HTML in a web view) was weighed against keeping the text view. The user kept the text view for ⌘F. A library would not have removed the hard part anyway: the pictures live in a container behind ssh.

## Decision

**Placeholders, then pictures.** The renderer still draws a placeholder (an icon and the alt text, linked to the picture) and marks it `.previewImage` with the source as written. An `<img>`'s width and height ride along. The text view then works in four steps:
- it collects the sources and fetches them through `previewImages`, set by the Files window for the file shown;
- it swaps each placeholder for a `PreviewImageAttachment` as its picture arrives;
- the placeholder's paragraph style, font and link carry over;
- the line at the top of the view stays put.

A picture that can't be fetched or decoded keeps its placeholder.

**Sizing.** A picture shows at its own size or the size the document asks for, at most 640 points, and never wider than its line. It is an `NSTextAttachment` subclass whose bounds follow the line fragment, so it shrinks in a narrow pane, a quote or a table cell. Unlike an attachment cell, the renderer can make one off the main thread.

**Fetching** (`PreviewImages.remote`). Sources resolve against the previewed file as links do (ADR 0010).
- **Container files** are read in one ssh session (`RemoteFileService.readImages`), read-only:
  - only regular files are read, so a FIFO is never opened;
  - each file up to 5 MB, 32 MB and 64 files a preview.
- **http(s) pictures** come through an ephemeral URLSession (system proxy, no cookies or cache kept), up to 5 MB each.
- Each batch is delivered as it arrives, so the container's pictures don't wait for the web.

**Badges.** Foundation's parser drops an image inside a link (`[![CI](badge.svg)](ci)`). Before parsing, such badges are rewritten to `<a><img></a>`, outside code spans and fenced blocks (`MarkdownSource.unnestingLinkedImages`). Inline HTML tags that arrive side by side in one run are now all read, not just the first.

**Notebooks.** Pictures pasted into a Markdown cell (`attachment:name`) and SVG outputs become `data:` URIs, like PNG outputs already were.

**HTML pages** still load nothing themselves: the content security policy allows only `data:` images. The preview shows the page at once, fetches its `<img>` sources the same way, and loads it again with them inlined (`HTMLImages`); a `srcset` is dropped where its `src` is inlined.

**Fixed on the way:** the web preview loaded every page against a custom `agentmux-preview:` base URL that had no handler. WebKit then loaded nothing at all, so HTML and SVG previews were blank. The scheme now has a handler that answers every request with an error.

## Consequences

- Viewing a Markdown or HTML file now reads more than that file: its pictures in the container, and web pictures over the network.
- CSS background images, `<picture>` sources and pictures inside an SVG are not fetched.
- A picture that changes on the remote shows its new version the next time the file is opened; there is no cache across opens.
