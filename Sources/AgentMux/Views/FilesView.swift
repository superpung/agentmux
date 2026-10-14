import AgentMuxCore
import AppKit
import Highlightr
import MarkdownUI
import PDFKit
import SwiftUI
import WebKit

/// The dedicated Files window: a two-pane browser (tree | wide preview) for the
/// selected agent's project files. Read-only.
struct FileBrowserWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.selection, let state = model.state(ref.targetID), let root = fileRoot(ref) {
            FileBrowser(ref: ref, host: state.host, target: state.target, root: root)
                .id(ref) // reset the browser when the selected agent changes
        } else {
            VStack(spacing: 10) {
                Image(systemName: "folder").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select an agent in the main window to browse its files.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
        }
    }

    private func fileRoot(_ ref: PaneRef) -> String? {
        if let a = model.agentEntry(ref), !a.space.path.isEmpty { return a.space.path }
        if let p = model.paneEntry(ref), !p.space.path.isEmpty { return p.space.path }
        return nil
    }
}

/// Directory tree on the left, a wide resizable preview on the right.
private struct FileBrowser: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef
    let host: HostConfig
    let target: TargetConfig
    let root: String
    @State private var selected: String?

    var body: some View {
        NavigationSplitView {
            FileTree(host: host, target: target, root: root, selected: $selected)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            FilePreviewView(host: host, target: target, path: selected)
        }
        .navigationTitle((root as NSString).lastPathComponent)
        .navigationSubtitle(selected.map { ($0 as NSString).lastPathComponent } ?? "")
        .onAppear { applyPreviewRequest() }
        .onChange(of: model.previewRequest) { _, _ in applyPreviewRequest() }
    }

    private func applyPreviewRequest() {
        if let req = model.previewRequest, req.targetID == ref.targetID { selected = req.path }
    }
}

private struct FilePreview: Equatable {
    var path: String
    var content: RemoteFileContent
}

/// A read-only directory browser: navigate into folders, select a file to
/// preview (binds `selected`).
private struct FileTree: View {
    let host: HostConfig
    let target: TargetConfig
    let root: String
    @Binding var selected: String?

    @State private var cwd: String
    @State private var entries: [RemoteFileEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var downloading: Set<String> = []
    @State private var downloadError: String?

    init(host: HostConfig, target: TargetConfig, root: String, selected: Binding<String?>) {
        self.host = host
        self.target = target
        self.root = root
        _selected = selected
        _cwd = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: cwd) { await load() }
        .alert("Download failed", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
    }

    /// Saves a remote file to a Mac location the user picks. Read-only on the
    /// remote; a spinner replaces the row's size while it transfers.
    private func download(_ entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloading.insert(entry.path)
        Task {
            let result = await RemoteFileService.download(entry.path, host: host, target: target)
            await MainActor.run {
                downloading.remove(entry.path)
                switch result {
                case let .success(data):
                    do { try data.write(to: url) }
                    catch { downloadError = "Could not save: \(error.localizedDescription)" }
                case let .failure(failure):
                    downloadError = failure.detail.isEmpty ? failure.kind.rawValue : failure.detail
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { navigateUp() } label: { Image(systemName: "chevron.up").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).disabled(cwd == root).opacity(cwd == root ? 0.35 : 1)
            Text(displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if loading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var displayPath: String {
        guard cwd != root else { return (root as NSString).lastPathComponent }
        let rel = cwd.hasPrefix(root) ? String(cwd.dropFirst(root.count)) : cwd
        return (root as NSString).lastPathComponent + rel
    }

    @ViewBuilder private var content: some View {
        if let error {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        } else if entries.isEmpty, !loading {
            centered { Text("Empty folder").font(.caption).foregroundStyle(.tertiary) }
        } else {
            List {
                ForEach(entries) { entry in
                    Button {
                        if entry.isDirectory { cwd = entry.path } else { selected = entry.path }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
                                .frame(width: 16)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if entry.isDirectory {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            } else if downloading.contains(entry.path) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text(sizeText(entry.size)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(!entry.isDirectory && selected == entry.path ? Theme.itemWashSelected : Color.clear)
                    .contextMenu {
                        if !entry.isDirectory {
                            Button("Download…", systemImage: "arrow.down.circle") { download(entry) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
    }

    private func load() async {
        error = nil
        loading = true
        defer { loading = false }
        switch await RemoteFileService.list(cwd, host: host, target: target) {
        case let .success(items): entries = items
        case let .failure(f): entries = []; error = "\(f.kind.rawValue): \(f.detail)"
        }
    }

    private func navigateUp() {
        guard cwd != root else { return }
        let parent = (cwd as NSString).deletingLastPathComponent
        cwd = parent.hasPrefix(root) || parent == root ? parent : root
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if CodeHighlighter.imageExtensions.contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        if ["md", "markdown", "txt", "rst"].contains(ext) { return "doc.text" }
        if ["json", "yml", "yaml", "toml", "ini", "cfg", "conf"].contains(ext) { return "gearshape" }
        if ["csv", "tsv"].contains(ext) { return "tablecells" }
        if ["zip", "gz", "tar", "xz", "bz2", "7z"].contains(ext) { return "doc.zipper" }
        return "doc"
    }
}

/// Loads and shows the preview for one selected file path (right pane).
private struct FilePreviewView: View {
    let host: HostConfig
    let target: TargetConfig
    let path: String?

    @State private var content: RemoteFileContent?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if path == nil {
                placeholder("Select a file to preview", "doc.text.magnifyingglass")
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                placeholder(error, "exclamationmark.triangle")
            } else if let content, let path {
                PreviewPane(preview: FilePreview(path: path, content: content))
            }
        }
        .task(id: path) { await load() }
    }

    private func placeholder(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
    }

    private func load() async {
        content = nil
        error = nil
        guard let path else { return }
        loading = true
        defer { loading = false }
        switch await RemoteFileService.read(path, host: host, target: target) {
        case let .success(c): content = c
        case let .failure(f): error = "\(f.kind.rawValue): \(f.detail)"
        }
    }
}

/// Renders a previewed file: highlighted text, an image, or a status message.
private struct PreviewPane: View {
    let preview: FilePreview

    private var ext: String { (preview.path as NSString).pathExtension.lowercased() }

    var body: some View {
        switch preview.content {
        case let .text(text, truncated, bytes):
            switch ext {
            case "md", "markdown": MarkdownPreview(source: text)
            case "csv": CSVPreview(text: text, separator: ",")
            case "tsv": CSVPreview(text: text, separator: "\t")
            case "svg": SVGPreview(svg: text)
            default: codeText(text, truncated: truncated, bytes: bytes)
            }
        case let .image(data):
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).padding(8)
                } else {
                    message("Can't decode image", "photo.badge.exclamationmark")
                }
            }
        case let .pdf(data):
            PDFPreview(data: data)
        case let .binary(bytes):
            message("Binary file · \(sizeText(bytes))", "doc.badge.gearshape")
        case let .tooLarge(bytes):
            message("Too large to preview · \(sizeText(bytes))", "exclamationmark.magnifyingglass")
        case .empty:
            message("Empty file", "doc")
        }
    }

    private func codeText(_ text: String, truncated: Bool, bytes: Int) -> some View {
        VStack(spacing: 0) {
            if truncated {
                Label("Showing the first \(RemoteFileService.textByteCap / 1024) KB of \(sizeText(bytes))",
                      systemImage: "scissors")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.itemWash)
            }
            CodePreview(text: text, language: CodeHighlighter.language(for: preview.path))
        }
    }

    private func message(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A read-only, scrollable, syntax-highlighted text view.
private struct CodePreview: NSViewRepresentable {
    let text: String
    let language: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = true
            tv.textContainerInset = NSSize(width: 8, height: 8)
            // Soft-wrap long lines to the (narrow) panel width so nothing runs
            // off the right edge; the inspector is too narrow for horizontal
            // scrolling to be readable.
            tv.isHorizontallyResizable = false
            tv.isVerticallyResizable = true
            tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = true
            tv.textContainer?.lineBreakMode = .byCharWrapping
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let highlighted = CodeHighlighter.shared.highlight(text, language: language)
        // Force char-level wrapping across the whole text (keeps the highlight
        // colours) so even a long URL / key wraps instead of overflowing.
        let styled = NSMutableAttributedString(attributedString: highlighted.string)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping
        styled.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: styled.length))
        tv.textStorage?.setAttributedString(styled)
        tv.backgroundColor = highlighted.background
    }
}

/// A shared, main-actor wrapper over Highlightr with light/dark themes.
@MainActor
final class CodeHighlighter {
    static let shared = CodeHighlighter()
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "ico"]
    /// Highlighting very large text through JavaScriptCore is slow; above this
    /// we fall back to plain monospaced text.
    private static let highlightByteCap = 150_000

    private let highlightr = Highlightr()
    private let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    struct Result { var string: NSAttributedString; var background: NSColor }

    func highlight(_ code: String, language: String?) -> Result {
        guard let highlightr, code.utf8.count <= Self.highlightByteCap else {
            return Result(string: plain(code), background: .textBackgroundColor)
        }
        highlightr.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")
        highlightr.theme.setCodeFont(font)
        if let attributed = highlightr.highlight(code, as: language) {
            return Result(string: attributed, background: highlightr.theme.themeBackgroundColor)
        }
        return Result(string: plain(code), background: .textBackgroundColor)
    }

    private func plain(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.textColor])
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// highlight.js language name from a file extension (nil = auto-detect).
    static func language(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "py": return "python"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp", "hxx", "cxx": return "cpp"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "rb": return "ruby"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "cfg", "conf": return "ini"
        case "html", "htm", "xml", "svg": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "v", "sv", "svh", "vh": return "verilog"
        case "vhd", "vhdl": return "vhdl"
        case "tcl": return "tcl"
        case "mk", "make", "makefile": return "makefile"
        case "dockerfile": return "dockerfile"
        case "sql": return "sql"
        case "lua": return "lua"
        case "pl", "pm": return "perl"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}

// MARK: - Rich-format previews

/// Markdown with a Rendered / Source toggle (rendered via swift-markdown-ui).
private struct MarkdownPreview: View {
    let source: String
    @State private var rendered = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $rendered) {
                Text("Rendered").tag(true)
                Text("Source").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if rendered {
                ScrollView {
                    Markdown(source)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                CodePreview(text: source, language: "markdown")
            }
        }
    }
}

/// A CSV / TSV table (first row as header). Basic split — no quoted-field CSV.
private struct CSVPreview: View {
    let text: String
    let separator: Character

    private var rows: [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: true).prefix(1000).map {
            $0.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 11.5, design: .monospaced))
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .foregroundStyle(index == 0 ? Theme.text : Theme.textSecondary)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
        }
    }
}

/// Renders an SVG via WKWebView (JavaScript disabled, external navigation
/// blocked). Suited to self-contained SVGs such as waveforms.
private struct SVGPreview: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.svg != svg else { return }
        context.coordinator.svg = svg
        context.coordinator.programmaticLoad = true
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%}body{display:flex;align-items:center;justify-content:center}
        svg{max-width:100%;height:auto}</style></head><body>\(svg)</body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var svg: String?
        var programmaticLoad = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if programmaticLoad { programmaticLoad = false; decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}

/// Renders a PDF with PDFKit.
private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
