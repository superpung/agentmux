# ADR 0010: Links in Previews

Date: 2026-10-29. Status: accepted. Checked in a separate test app (not AgentMux, which mirrors live agents): every kind of link below resolves as intended when clicked; a `#heading` or `#L12` link scrolls there, also on opening another file; image icons and links read in light and dark. The folder check and the folder marker on a read were run read-only in a container.

## Context

A Markdown preview showed links, but only web links did anything: a click handed the link to macOS. A link to another file in the repository (`docs/guide.md`, `../src/main.swift#L40`) or to a heading (`#install`) did nothing, and a link written as HTML (`<a href>`, common at the top of a README) was not a link at all. Files live in a container on a remote host, so a relative link means a path there, not on the Mac. Handing every link to macOS would also let a file an agent wrote open any app with a custom URL scheme.

## Decision

- **One resolver.** `PreviewLink.resolve` reads a link relative to the file shown. It returns one of five results: a web page or mail address (`http`, `https`, `mailto`); a place in the same file; a file in the container (with `#name` or `#L12`); a folder (a trailing `/`); or unsupported. Percent-encoding is decoded, so CJK and spaced names work. `file://` means a container path. Every other scheme (`javascript:`, `vscode:`, `data:`, …) only beeps.
- **Where each goes.**
  - A web page or mail address opens in the Mac's default app.
  - A file opens in the same window's preview, and the list moves to its folder. A file outside the window's folder still opens in the preview; the list stays where it is.
  - A folder is listed here, or in its own Files window when it is outside this one.
  - A link without an extension (`docs`, `LICENSE`) is checked remotely first, read-only, to tell a folder from a file. A read that lands on a folder anyway, such as a folder picked in a terminal, lists it and goes back to the file shown before.
- **Places in a file.** Headings carry GitHub's slugs (repeats numbered `-1`, `-2`), and HTML `<a name>` / `id` marks a place. `#L12` and `#L12-L20` name lines in code, CSV and text. A jump scrolls the place to the top and flashes it with the find indicator.
- **HTML in Markdown.**
  - `<a href>` becomes a link, `<a name>` an anchor, and `<img>` an icon with its alt text.
  - A Markdown image links to its file, so clicking `img/arch.png` previews it; when the image sits inside a link, the outer link wins.
  - Embedded `data:` images are not links.
- **PDF and SVG.** Their links go through the same resolver. Page links inside a PDF still scroll the PDF.
- **Back and Forward.** The Files window keeps a history of the files shown, with toolbar buttons and ⌃⌘← / ⌃⌘→. ⌘[ and ⌘] already switch agents app-wide.

## Consequences

- Foundation's parser drops an image nested in a link: such a badge shows as its alt text, linked, and one without alt text disappears.
- Back reloads the file from the remote and opens it at the top, not where it was left.
- History is per window and is lost when the window closes.
