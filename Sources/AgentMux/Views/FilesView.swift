import AgentMuxCore
import AppKit
import Highlightr
import MarkdownUI
import PDFKit
import SwiftUI
import WebKit

/// What a Files window browses: a folder in one target. Windows are keyed by
/// it, so each stays on its folder whichever agent is selected later, and
/// opening the same folder again brings its window forward.
struct FilesWindowSpec: Codable, Hashable, Sendable {
    var targetID: String
    var root: String
}

/// A Files window: a two-pane browser (tree | wide preview) for one folder.
struct FileBrowserWindow: View {
    @Environment(AppModel.self) private var model
    let spec: FilesWindowSpec

    var body: some View {
        if let state = model.state(spec.targetID) {
            FileBrowser(spec: spec, host: state.host, target: state.target, deviceName: state.device.name)
        } else {
            // The target was removed in Settings (or a restored window outlived it).
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Directory tree on the left, a wide resizable preview on the right.
private struct FileBrowser: View {
    @Environment(AppModel.self) private var model
    let spec: FilesWindowSpec
    let host: HostConfig
    let target: TargetConfig
    let deviceName: String
    @State private var selected: String?

    private var root: String { spec.root }

    var body: some View {
        NavigationSplitView {
            FileTree(host: host, target: target, root: root, selected: $selected)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            FilePreviewView(host: host, target: target, path: selected)
        }
        .navigationTitle((root as NSString).lastPathComponent)
        // Several Files windows can be open; the container tells same-named
        // folders apart.
        .navigationSubtitle([deviceName, selected.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " · "))
        .onAppear { applyPreviewRequest() }
        .onChange(of: model.previewRequest) { _, _ in applyPreviewRequest() }
    }

    private func applyPreviewRequest() {
        if let req = model.previewRequest, req.spec == spec { selected = req.path }
    }
}

private struct FilePreview: Equatable {
    var path: String
    var content: RemoteFileContent
}

/// A local file headed for a remote path.
private struct PlannedUpload {
    let source: URL
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

/// A failed file operation, shown in an alert.
private struct FileOperationFailure: Equatable {
    let title: String
    let message: String
}

/// A result waiting for the screen: only one prompt shows at a time, and a
/// batch that finishes while another prompt is up must not replace it.
private enum WaitingPrompt {
    case failure(FileOperationFailure)
    case overwrite([PlannedUpload])
}

/// What the name sheet asks for.
private enum NamePrompt: Identifiable {
    case newFile, newFolder, rename(RemoteFileEntry)

    var id: String {
        switch self {
        case .newFile: "new-file"
        case .newFolder: "new-folder"
        case let .rename(entry): "rename:" + entry.path
        }
    }
}

/// A directory browser: navigate into folders, select a file to preview
/// (binds `selected`), and manage the folder's files. Every remote write is
/// an explicit action, and none replaces an existing entry without the user
/// confirming it.
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
    /// Remote writes in flight; any of them shows the header spinner.
    @State private var busy = 0
    @State private var pendingOverwrite: [PlannedUpload] = []
    /// Failures and conflicts that arrived while another prompt was on screen.
    @State private var waitingPrompts: [WaitingPrompt] = []
    @State private var pendingDelete: RemoteFileEntry?
    @State private var namePrompt: NamePrompt?
    @State private var failure: FileOperationFailure?
    @State private var dragOut = FileDragOut()
    /// A Finder drag hovers over the list (upload into the browsed folder).
    @State private var dropTargeted = false
    /// The folder row a Finder drag hovers over (upload into that folder).
    @State private var dropFolder: String?

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
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    let directory = cwd
                    loadDroppedFileURLs(providers) { urls in upload(urls, into: directory) }
                    return true
                }
                .overlay {
                    if dropTargeted, dropFolder == nil {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2)
                            .padding(3).allowsHitTesting(false)
                    }
                }
        }
        .task(id: cwd) { await load() }
        .onAppear { connectDragOut() }
        .onChange(of: host) { connectDragOut() }
        .onChange(of: target) { connectDragOut() }
        .onDisappear { dragOut.disconnect() }
        .sheet(item: $namePrompt) { prompt in
            NameSheet(prompt: prompt, taken: Set(entries.map(\.name))) { name in commit(prompt, name: name) }
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
        .onChange(of: promptOnScreen) { _, onScreen in
            guard !onScreen else { return }
            // Let the closing prompt finish before the next one opens.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                showNextPrompt()
            }
        }
        .confirmationDialog(overwriteTitle,
                            isPresented: Binding(get: { !pendingOverwrite.isEmpty }, set: { if !$0 { pendingOverwrite = [] } }),
                            titleVisibility: .visible, presenting: pendingOverwrite) { uploads in
            Button("Replace", role: .destructive) { runUploads(uploads, overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: { uploads in
            Text(uploads.count == 1 ? "Replacing it overwrites the remote file." : "Replacing them overwrites the remote files.")
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { performDelete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            if entry.isSymlink {
                Text("This removes the link, not what it points to.")
            } else if entry.isDirectory {
                Text("Only an empty folder can be deleted.")
            } else {
                Text("This permanently removes the remote file.")
            }
        }
    }

    private var promptOnScreen: Bool {
        failure != nil || !pendingOverwrite.isEmpty || pendingDelete != nil || namePrompt != nil
    }

    private func show(_ prompt: WaitingPrompt) {
        waitingPrompts.append(prompt)
        showNextPrompt()
    }

    /// Puts the oldest waiting prompt on screen once nothing else is.
    private func showNextPrompt() {
        guard !promptOnScreen, !waitingPrompts.isEmpty else { return }
        switch waitingPrompts.removeFirst() {
        case let .failure(item): failure = item
        case let .overwrite(uploads): pendingOverwrite = uploads
        }
    }

    private var overwriteTitle: String {
        guard let first = pendingOverwrite.first else { return "" }
        let folder = ((first.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return pendingOverwrite.count == 1
            ? "“\(first.name)” already exists in “\(folder)”."
            : "\(pendingOverwrite.count) items already exist in “\(folder)”."
    }

    // MARK: Remote writes

    private func performDelete(_ entry: RemoteFileEntry) {
        busy += 1
        Task {
            let result: Result<Void, RemoteFailure>
            if entry.isDirectory {
                result = await RemoteFileService.removeDirectory(entry.path, host: host, target: target)
            } else {
                result = await RemoteFileService.delete(entry.path, host: host, target: target)
            }
            busy -= 1
            switch result {
            case .success:
                if selected == entry.path { selected = nil }
                await load()
            case let .failure(f):
                show(.failure(FileOperationFailure(title: "Couldn’t delete “\(entry.name)”", message: Self.describe(f))))
            }
        }
    }

    /// Picks local files and uploads them into the folder being browsed.
    private func startUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, into: cwd)
    }

    /// Uploads local files into `directory`. Items the upload policy refuses
    /// are reported; names that already exist are confirmed together
    /// afterwards instead of being replaced.
    private func upload(_ sources: [URL], into directory: String) {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(RemoteFileService.downloadByteCap), countStyle: .file)
        var planned: [PlannedUpload] = []
        var problems: [String] = []
        for url in sources {
            let name = url.lastPathComponent
            // Read through a symlink, but keep the link's own name remotely.
            let source = url.resolvingSymlinksInPath()
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            switch RemoteFileService.uploadRefusal(name: name, isDirectory: values?.isDirectory ?? false,
                                                   isRegularFile: values?.isRegularFile ?? false,
                                                   size: values?.fileSize ?? 0) {
            case .folder?: problems.append("“\(name)” is a folder; only files can be uploaded.")
            case .notAFile?: problems.append("“\(name)” isn’t a regular file; only files can be uploaded.")
            case .unusableName?: problems.append("“\(name)” has a name the remote listing can’t show.")
            case .tooLarge?: problems.append("“\(name)” is larger than the \(limit) upload limit.")
            case nil: planned.append(PlannedUpload(source: source, path: RemoteFileService.path(name, in: directory)))
            }
        }
        runUploads(planned, overwrite: false, problems: problems)
    }

    /// Uploads one file at a time (one ssh session each), then reloads once.
    private func runUploads(_ uploads: [PlannedUpload], overwrite: Bool, problems initial: [String] = []) {
        guard !uploads.isEmpty || !initial.isEmpty else { return }
        busy += 1
        Task {
            var problems = initial
            var conflicts: [PlannedUpload] = []
            var wrote = false
            for upload in uploads {
                let data: Data
                do { data = try await Self.readLocal(upload.source) }
                catch { problems.append("“\(upload.name)”: \(error.localizedDescription)"); continue }
                switch await RemoteFileService.upload(data, to: upload.path, host: host, target: target, overwrite: overwrite) {
                case .success(.written): wrote = true
                case .success(.alreadyExists): conflicts.append(upload)
                case let .failure(f): problems.append("“\(upload.name)”: \(Self.describe(f))")
                }
            }
            busy -= 1
            if wrote { await load() }
            if !problems.isEmpty {
                show(.failure(FileOperationFailure(title: "Upload failed", message: problems.joined(separator: "\n"))))
            }
            if !conflicts.isEmpty { show(.overwrite(conflicts)) }
        }
    }

    /// Reads a local file off the main thread; a dropped file can be 50 MB.
    private static func readLocal(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
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
            downloading.remove(entry.path)
            switch result {
            case let .success(data):
                do { try data.write(to: url) }
                catch { show(.failure(FileOperationFailure(title: "Download failed", message: error.localizedDescription))) }
            case let .failure(f):
                show(.failure(FileOperationFailure(title: "Download failed", message: Self.describe(f))))
            }
        }
    }

    private func commit(_ prompt: NamePrompt, name: String) {
        switch prompt {
        case .newFile: create(name, folder: false)
        case .newFolder: create(name, folder: true)
        case let .rename(entry): rename(entry, to: name)
        }
    }

    /// Creates an empty file or a folder in the browsed folder; a new file is
    /// selected so the preview confirms it.
    private func create(_ name: String, folder: Bool) {
        let directory = cwd
        let path = RemoteFileService.path(name, in: directory)
        busy += 1
        Task {
            let result: Result<RemoteFileService.NoClobberResult, RemoteFailure>
            if folder {
                result = await RemoteFileService.createDirectory(path, host: host, target: target)
            } else {
                result = await RemoteFileService.createFile(path, host: host, target: target)
            }
            busy -= 1
            switch result {
            case .success(.done):
                await load()
                if !folder, directory == cwd { selected = path }
            case .success(.alreadyExists):
                show(.failure(FileOperationFailure(title: "Couldn’t create “\(name)”", message: "“\(name)” already exists in this folder.")))
            case let .failure(f):
                show(.failure(FileOperationFailure(title: "Couldn’t create “\(name)”", message: Self.describe(f))))
            }
        }
    }

    /// Renames an entry in place. The preview follows the rename, including a
    /// file inside a renamed folder.
    private func rename(_ entry: RemoteFileEntry, to name: String) {
        let newPath = RemoteFileService.path(name, in: (entry.path as NSString).deletingLastPathComponent)
        guard newPath != entry.path else { return }
        busy += 1
        Task {
            let result = await RemoteFileService.rename(entry.path, to: newPath, host: host, target: target)
            busy -= 1
            switch result {
            case .success(.done):
                if let current = selected {
                    if current == entry.path {
                        selected = newPath
                    } else if current.hasPrefix(entry.path + "/") {
                        selected = newPath + String(current.dropFirst(entry.path.count))
                    }
                }
                await load()
            case .success(.alreadyExists):
                show(.failure(FileOperationFailure(title: "Couldn’t rename “\(entry.name)”", message: "“\(name)” already exists in this folder.")))
            case let .failure(f):
                show(.failure(FileOperationFailure(title: "Couldn’t rename “\(entry.name)”", message: Self.describe(f))))
            }
        }
    }

    /// Lets file rows be dragged to Finder: the drop downloads the file there.
    /// Rebound when the host or target changes in Settings.
    private func connectDragOut() {
        let host = host, target = target
        dragOut.fetch = { entry in await RemoteFileService.download(entry.path, host: host, target: target) }
        dragOut.onActivity = { path, active in
            if active { downloading.insert(path) } else { downloading.remove(path) }
        }
        dragOut.onFailure = { name, message in
            show(.failure(FileOperationFailure(title: "Couldn’t download “\(name)”", message: message)))
        }
        dragOut.resume()
    }

    private func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private static func describe(_ failure: RemoteFailure) -> String {
        failure.detail.isEmpty ? failure.kind.rawValue : failure.detail
    }

    // MARK: Layout

    private var header: some View {
        HStack(spacing: 6) {
            Button { navigateUp() } label: { Image(systemName: "chevron.up").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).disabled(cwd == root).opacity(cwd == root ? 0.35 : 1)
            Text(displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if loading || busy > 0 { ProgressView().controlSize(.mini) }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).disabled(loading)
                .help("Reload this folder")
            Menu {
                Button("New File…", systemImage: "doc.badge.plus") { namePrompt = .newFile }
                Button("New Folder…", systemImage: "folder.badge.plus") { namePrompt = .newFolder }
            } label: {
                Image(systemName: "plus").font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("New file or folder")
            Button { startUpload() } label: { Image(systemName: "square.and.arrow.up").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless)
                .help("Upload files into this folder")
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
                    .background { if !entry.isDirectory { DragOutRow(entry: entry, controller: dragOut) } }
                    .folderDropTarget(entry, targeted: $dropFolder) { urls, folder in upload(urls, into: folder) }
                    .listRowBackground(rowBackground(entry))
                    .contextMenu {
                        if !entry.isDirectory {
                            Button("Download…", systemImage: "arrow.down.circle") { download(entry) }
                        }
                        Button("Rename…", systemImage: "pencil") { namePrompt = .rename(entry) }
                        Button("Copy Path", systemImage: "doc.on.doc") { copyPath(entry.path) }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func rowBackground(_ entry: RemoteFileEntry) -> Color {
        if entry.isDirectory { return dropFolder == entry.path ? Theme.accent.opacity(0.18) : .clear }
        return selected == entry.path ? Theme.itemWashSelected : .clear
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding()
    }

    @MainActor
    private func load() async {
        let directory = cwd
        error = nil
        loading = true
        let result = await RemoteFileService.list(directory, host: host, target: target)
        // Navigation cancels this load and starts another; a stale result
        // (another folder's, or the failure of a killed ssh) must not land.
        guard directory == cwd, !Task.isCancelled else { return }
        loading = false
        switch result {
        case let .success(items): entries = items; error = nil
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

/// Asks for the name of a new file or folder, or the new name in a rename.
private struct NameSheet: View {
    let prompt: NamePrompt
    /// Names already in the folder, for instant feedback; the remote refuses
    /// an existing name on its own as well.
    let taken: Set<String>
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var committed = false
    @FocusState private var focused: Bool

    init(prompt: NamePrompt, taken: Set<String>, onCommit: @escaping (String) -> Void) {
        self.prompt = prompt
        self.taken = taken
        self.onCommit = onCommit
        if case let .rename(entry) = prompt {
            _name = State(initialValue: entry.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            Text(problem ?? " ")
                .font(.caption).foregroundStyle(Theme.danger)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private var title: String {
        switch prompt {
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case let .rename(entry): "Rename “\(entry.name)”"
        }
    }

    private var actionTitle: String {
        if case .rename = prompt { return "Rename" }
        return "Create"
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var unchanged: Bool {
        if case let .rename(entry) = prompt { return name == entry.name || trimmed == entry.name }
        return false
    }

    /// Shown under the field. nil while the name is usable, unchanged, or
    /// still empty (the disabled button says enough then).
    private var problem: String? {
        if unchanged { return nil }
        switch RemoteFileService.nameProblem(trimmed) {
        case .empty?: return nil
        case .reserved?: return "“\(trimmed)” is reserved."
        case .slash?: return "A name can’t contain “/”."
        case .lineBreak?: return "A name can’t contain line breaks."
        case .tooLong?: return "That name is too long."
        case nil: return taken.contains(trimmed) ? "“\(trimmed)” already exists in this folder." : nil
        }
    }

    private var canCommit: Bool {
        !unchanged && RemoteFileService.nameProblem(trimmed) == nil && !taken.contains(trimmed)
    }

    private func commit() {
        guard canCommit, !committed else { return }
        committed = true
        onCommit(trimmed)
        dismiss()
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
            tv.usesFindBar = true
            tv.isIncrementalSearchingEnabled = true
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

/// Renders a PDF with PDFKit, searchable with the system find bar.
private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> FindablePDFView {
        let view = FindablePDFView()
        view.pdfView.autoScales = true
        view.pdfView.displayMode = .singlePageContinuous
        view.pdfView.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: FindablePDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
