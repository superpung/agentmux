import AgentMuxCore
import AppKit
import Highlightr
import SwiftUI

/// The right inspector: a Resources / Files switch over the two panels.
struct InspectorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorMode) {
                Text("Resources").tag(AppModel.InspectorMode.resources)
                Text("Files").tag(AppModel.InspectorMode.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            Divider()
            switch model.inspectorMode {
            case .resources: ResourceInspector()
            case .files: filesTab
            }
        }
    }

    @ViewBuilder private var filesTab: some View {
        if let ref = model.selection, let state = model.state(ref.targetID), let root = fileRoot(ref) {
            FilesView(ref: ref, host: state.host, target: state.target, root: root)
                .id(ref) // reset the browser when the selected agent changes
        } else {
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.title3).foregroundStyle(.tertiary)
                Text("Select an agent to browse its files.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
        }
    }

    private func fileRoot(_ ref: PaneRef) -> String? {
        if let a = model.agentEntry(ref), !a.space.path.isEmpty { return a.space.path }
        if let p = model.paneEntry(ref), !p.space.path.isEmpty { return p.space.path }
        return nil
    }
}

private struct FilePreview: Equatable {
    var path: String
    var content: RemoteFileContent
}

/// A read-only directory browser + file preview, rooted at the agent's cwd.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef
    let host: HostConfig
    let target: TargetConfig
    let root: String

    @State private var cwd: String
    @State private var entries: [RemoteFileEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var preview: FilePreview?
    @State private var previewing = false

    init(ref: PaneRef, host: HostConfig, target: TargetConfig, root: String) {
        self.ref = ref
        self.host = host
        self.target = target
        self.root = root
        _cwd = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let preview {
                PreviewPane(preview: preview)
            } else if previewing {
                center { ProgressView().controlSize(.small) }
            } else {
                directoryList
            }
        }
        .task(id: cwd) { await loadDir() }
        .onAppear { consumePreviewRequest() }
        .onChange(of: model.previewRequest) { _, _ in consumePreviewRequest() }
    }

    // MARK: Header / breadcrumb

    private var header: some View {
        HStack(spacing: 6) {
            if preview != nil {
                backButton("chevron.left") { preview = nil }
                Text((cwd as NSString).lastPathComponent + "/" + ((preview?.path ?? "") as NSString).lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.head)
            } else {
                backButton("chevron.up") { navigateUp() }
                    .disabled(cwd == root)
                    .opacity(cwd == root ? 0.35 : 1)
                Text(displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if loading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func backButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.caption.weight(.semibold)) }
            .buttonStyle(.borderless)
    }

    private var displayPath: String {
        guard cwd != root else { return (root as NSString).lastPathComponent }
        let rel = cwd.hasPrefix(root) ? String(cwd.dropFirst(root.count)) : cwd
        return (root as NSString).lastPathComponent + rel
    }

    // MARK: Directory list

    @ViewBuilder private var directoryList: some View {
        if let error {
            center {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        } else if entries.isEmpty, !loading {
            center { Text("Empty folder").font(.caption).foregroundStyle(.tertiary) }
        } else {
            List {
                ForEach(entries) { entry in
                    Button {
                        if entry.isDirectory { cwd = entry.path } else { Task { await open(entry.path) } }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
                                .frame(width: 16)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if !entry.isDirectory {
                                Text(sizeText(entry.size)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                            } else {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
    }

    private func center<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
    }

    // MARK: Loading

    private func loadDir() async {
        error = nil
        loading = true
        defer { loading = false }
        switch await RemoteFileService.list(cwd, host: host, target: target) {
        case let .success(items): entries = items
        case let .failure(f): entries = []; error = "\(f.kind.rawValue): \(f.detail)"
        }
    }

    private func open(_ path: String) async {
        preview = nil
        previewing = true
        defer { previewing = false }
        switch await RemoteFileService.read(path, host: host, target: target) {
        case let .success(content): preview = FilePreview(path: path, content: content)
        case let .failure(f): error = "\(f.kind.rawValue): \(f.detail)"
        }
    }

    private func navigateUp() {
        guard cwd != root else { return }
        let parent = (cwd as NSString).deletingLastPathComponent
        cwd = parent.hasPrefix(root) || parent == root ? parent : root
    }

    private func consumePreviewRequest() {
        guard let req = model.previewRequest, req.targetID == ref.targetID else { return }
        Task { await open(req.path) }
    }

    // MARK: Formatting

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if CodeHighlighter.imageExtensions.contains(ext) { return "photo" }
        if ["md", "markdown", "txt", "rst"].contains(ext) { return "doc.text" }
        if ["json", "yml", "yaml", "toml", "ini", "cfg", "conf"].contains(ext) { return "gearshape" }
        if ["zip", "gz", "tar", "xz", "bz2", "7z"].contains(ext) { return "doc.zipper" }
        return "doc"
    }
}

/// Renders a previewed file: highlighted text, an image, or a status message.
private struct PreviewPane: View {
    let preview: FilePreview

    var body: some View {
        switch preview.content {
        case let .text(text, truncated, bytes):
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
        case let .image(data):
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).padding(8)
                } else {
                    message("Can't decode image", "photo.badge.exclamationmark")
                }
            }
        case let .binary(bytes):
            message("Binary file · \(sizeText(bytes))", "doc.badge.gearshape")
        case let .tooLarge(bytes):
            message("Too large to preview · \(sizeText(bytes))", "exclamationmark.magnifyingglass")
        case .empty:
            message("Empty file", "doc")
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
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = true
            tv.textContainerInset = NSSize(width: 6, height: 8)
            tv.isHorizontallyResizable = true
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let highlighted = CodeHighlighter.shared.highlight(text, language: language)
        tv.textStorage?.setAttributedString(highlighted.string)
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
