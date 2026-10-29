# ADR 0011: Documents, Media and Archives in the Preview

Date: 2026-10-29. Status: accepted. Checked in a separate test app (not AgentMux, which mirrors live agents):
- Quick Look shows Word and Excel files, and the player shows audio and video with its controls.
- The Text forms of Word, Excel and PowerPoint read right in light and dark mode, including Word tables, Excel dates and PowerPoint notes.
- ⌘F on a Quick Look page switches to the Text form and opens the find bar.
- A notebook shows its plots inline.
- An HTML page loads nothing beyond itself.

The new remote reads ran read-only in a container on existing files (a `.gz` changelog, a wheel, a folder, an ELF binary). The tar listing ran locally.

## Context

The Files preview showed text, images, PDFs and SVGs. Everything else was "Binary file" with its size: Word, Excel and PowerPoint (zip packages), audio and video, compressed logs and archives. A notebook showed as raw JSON and an HTML page as its source.

## Decision

- **Read by format.** `PreviewFormat` names how a file is read, from its name. The read script reports a folder instead of reading it.

  | Kind | How it is read |
  |---|---|
  | Office, iWork, audio, video | Whole, up to 20 MB, or not at all |
  | `.gz`, `.bz2`, `.xz` | Decompressed on the remote, up to the text cap, without knowing the full size |
  | zip and tar archives | Listed with python3, up to 20,000 entries; `unzip -l` / `tar -tvf` output when python3 is missing |
  | Anything else | As before, but a binary file keeps its first 64 KB for a hex view |

  The remote is only read. A file that is read whole goes to a temporary copy on the Mac, removed when the preview goes and swept on first use after a restart.
- **Office and iWork through Quick Look**, as Finder's space bar shows them.
  - Quick Look draws out of process, so its page cannot be searched. Word, Excel and PowerPoint therefore also get a **Text** form in the preview text view:
    - Word: AppKit's own reader, tables included.
    - Excel: each sheet as a table, from the workbook XML read through a small `ZipArchive`; dates shown as dates.
    - PowerPoint: each slide's title, body by outline level, and notes.
  - In the Text form, text and rules left black and white fills take the appearance's colors.
  - ⌘F on the page switches to Text and opens the find bar there, as it does from a rendered web view to its source.
  - The old binary `.xls` / `.ppt` have no Text form.
  - `.odt` has no Quick Look viewer and shows as text only.
- **Audio and video in AVKit's player** (AVPlayerView). Quick Look's player is out of process and showed nothing for video in testing.
- **Notebooks** become one Markdown document: code fenced, outputs quoted under their cell, errors without terminal colors. Plots render inline, because the Markdown renderer now draws an image the document holds as a `data:` URI. Other images still show as their alt text.
- **HTML** renders in a web view with scripts off. A Content-Security-Policy meta tag blocks every request beyond the page and its `data:` URIs. Relative links resolve against the file under a scheme nothing serves, so they reach the window like other preview links. SVG uses the same view.
- **RTF** renders through AppKit, with its source a switch away.
- **Other binaries** show their first 64 KB as `hexdump -C` prints it, searchable.

## Consequences

- An Office page stays white in dark mode (Quick Look draws it); the Text form follows the appearance.
- Files over 20 MB (most videos) show "Too large to preview".
- Excel numbers show as stored, not in their display format (`0.30000000000000004`, no thousands separators); only dates are formatted.
- Listing a large `.tar.gz` decompresses it on the remote up to the entry cap, within the read's timeout.
