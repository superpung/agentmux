# Relocatable preview resources

Date: 2026-11-16

## Evidence

A distributed 0.4.3 app crashed on the main thread while opening a code preview.
The stack entered `Highlightr.init(highlightPath:)` through `CodeHighlighter`
and trapped in SwiftPM's generated `Bundle.module` initializer. The complete
Highlightr bundle, including JavaScript and CSS themes, was present in
`Contents/Resources`. The generated accessor checked the app root and an
absolute build directory on the CI runner; neither existed on the user's Mac.

Local development masked the error because the absolute `.build` resource copy
still existed. Version, signature and startup checks did not initialize the file
preview highlighter, so they did not establish that the app was relocatable.
GhosttyTerminal already had a patch for the same SwiftPM packaging mismatch.

## Decision

Vendor the existing pinned Highlightr 2.3.0 source, without upgrading the library.
Its SwiftPM initializer uses a resolver that loads signed app resources from
`Contents/Resources`. Standalone SwiftPM executables and test runners may use
sibling resource bundles. A signed app does not fall back to an external build
path or sibling app directory. Missing resources return nil instead of invoking
SwiftPM's fatal accessor; `CodeHighlighter` then uses its existing plain-text
fallback. The upstream license and highlight.js license remain with the source.

`scripts/vendor-highlightr.sh` records the upstream tag/commit, verifies the
checkout and reapplies the small lookup patch. The dependency manifest uses the
vendored package so local builds and CI compile the same source.

Add an opt-in resource smoke mode before `AppModel` is initialized. It invokes
the actual `CodeHighlighter` with synthetic Swift text, checks syntax colors in
light/dark appearances and verifies the text is preserved. It writes a JSON
report and exits without settings, SSH, windows or agent input.

The packaging test relocates the app and hides build-directory resource bundles
to prevent an absolute build path from masking a regression. It checks normal
highlighting, an absent Highlightr bundle and an absent highlighter script. The
incomplete fixtures are re-signed after modification. The release workflow runs
this check before creating its downloadable archive. Local testing uses a
separate output bundle so the running app is replaced only after verification.

## Validation

The original release's two lookup candidates were confirmed absent while its
bundled resources were present. The relocated debug and optimized release
bundles must pass all three smoke scenarios with their build resources hidden.
Normal previews preserve text and produce multiple syntax colors; incomplete
resources preserve text in plain form. Existing Swift and script tests continue
to cover the rest of the app.
