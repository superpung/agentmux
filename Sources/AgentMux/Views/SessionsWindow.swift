import AgentMuxCore
import SwiftUI

// NOTE: body/header/actions/tree-model live here; the tree is rendered fully
// expanded (sessions → windows → panes all visible) so nothing has to be
// unfolded one row at a time.

/// A dedicated, deliberately-opened window for managing a container's tmux
/// tree: sessions → windows → panes. This is the ONLY place that creates or
/// kills tmux objects on the user's own server, and every kill is confirmed.
struct SessionsWindow: View {
    @Environment(AppModel.self) private var model
    @Binding var targetID: String
    @State private var confirm: KillRequest?
    @State private var newSessionName = ""
    @State private var showNewSession = false
    @State private var showLaunch = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .alert("Couldn't complete the operation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .alert(confirm.map { "Kill \($0.label)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { request in
            Button("Kill", role: .destructive) { perform(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("The programs running in \(request.label) will be terminated. This can't be undone.")
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(name: $newSessionName, container: model.state(targetID)?.device.name ?? targetID) { name in
                run { await model.newSession(targetID, name: name) }
            }
        }
        .sheet(isPresented: $showLaunch) {
            LaunchAgentSheet(targetID: targetID)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            newMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var newMenu: some View {
        Menu {
            Button { showLaunch = true } label: { Label("Launch Agent…", systemImage: "sparkles") }
            Button { newSessionName = ""; showNewSession = true } label: { Label("Empty Session", systemImage: "terminal") }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.state(targetID) == nil)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = model.state(targetID)?.snapshot, !snapshot.sessions.isEmpty {
            List {
                ForEach(nodes(in: snapshot)) { session in
                    Section {
                        ForEach(session.children ?? []) { window in
                            windowRow(window, in: session)
                            ForEach(window.children ?? []) { pane in
                                paneRow(pane, in: window, session: session)
                            }
                        }
                    } header: {
                        sessionHeader(session)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView {
                Label("No tmux sessions", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text(model.state(targetID) == nil
                    ? "This container isn't connected yet."
                    : "This container has no running tmux server. Create a session to start one.")
            } actions: {
                if model.state(targetID) != nil { newMenu }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Rows — session → window → pane, each indented so icons line up.

    @ViewBuilder private func sessionHeader(_ node: Node) -> some View {
        if case let .session(name, windowCount) = node.kind {
            let title = name.isEmpty ? node.id : name
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text("\(windowCount) window\(windowCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                rowMenu {
                    Button { run { await model.newWindow(targetID, sessionID: node.id) } } label: { Label("New Window", systemImage: "plus.rectangle") }
                    Divider()
                    Button(role: .destructive) { confirm = KillRequest(kind: .session, id: node.id, label: "session \(title)") } label: { Label("Kill Session", systemImage: "trash") }
                }
            }
            .padding(.vertical, 2)
            .textCase(nil)
        }
    }

    @ViewBuilder private func windowRow(_ node: Node, in session: Node) -> some View {
        if case let .window(index, name) = node.kind {
            let title = name.isEmpty ? node.id : name
            row(indent: 0, icon: AnyView(Image(systemName: "macwindow").foregroundStyle(.secondary)), title: "\(index)  \(title)", mono: false, accessory: AnyView(EmptyView())) {
                Button { run { await model.newWindow(targetID, sessionID: session.id) } } label: { Label("New Window in \(sessionName(session))", systemImage: "plus.rectangle") }
                Divider()
                Button(role: .destructive) {
                    confirm = KillRequest(kind: .window, id: node.id, label: "window \(index) (\(title)) in session \(sessionName(session))")
                } label: { Label("Kill Window", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private func paneRow(_ node: Node, in window: Node, session: Node) -> some View {
        if case let .pane(command, agentKind, activity) = node.kind {
            row(indent: 1, icon: AnyView(paneIcon(agentKind)), title: command, mono: true, accessory: AnyView(agentKind != nil ? AnyView(AgentStatusGlyph(activity: activity)) : AnyView(EmptyView()))) {
                Button(role: .destructive) {
                    confirm = KillRequest(kind: .pane, id: node.id, label: "pane \(node.id) (\(command)) in \(sessionName(session)):\(windowIndex(window))")
                } label: { Label("Kill Pane", systemImage: "trash") }
            }
        }
    }

    private func sessionName(_ node: Node) -> String {
        if case let .session(name, _) = node.kind { return name.isEmpty ? node.id : name }
        return node.id
    }

    private func windowIndex(_ node: Node) -> String {
        if case let .window(index, _) = node.kind { return "\(index)" }
        return node.id
    }

    private func row(indent: Int, icon: AnyView, title: String, mono: Bool, accessory: AnyView, @ViewBuilder menu: () -> some View) -> some View {
        HStack(spacing: 8) {
            if indent > 0 { Spacer().frame(width: CGFloat(indent) * 18) }
            icon.frame(width: 18)
            Text(title)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(1)
            Spacer(minLength: 6)
            accessory
            rowMenu(menu)
        }
        .padding(.vertical, 1)
    }

    /// A trailing "···" menu whose glyph uses an explicit adaptive color, so it
    /// stays visible in dark mode (a plain borderless menu renders it black).
    private func rowMenu(@ViewBuilder _ content: () -> some View) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.textSecondary)
        .fixedSize()
    }

    @ViewBuilder private func paneIcon(_ kind: AgentKind?) -> some View {
        if let kind, let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 14)
        } else {
            Image(systemName: "terminal").foregroundStyle(.tertiary)
        }
    }

    // MARK: Actions

    private func perform(_ request: KillRequest) {
        run {
            switch request.kind {
            case .session: return await model.killSession(targetID, sessionID: request.id)
            case .window: return await model.killWindow(targetID, windowID: request.id)
            case .pane: return await model.killPane(targetID, paneID: request.id)
            }
        }
    }

    /// Runs a create/kill, then keeps the "Updating…" indicator up until the
    /// live tree actually reflects the change (the next poll round-trip, ~1-3s),
    /// so the result never feels like it was dropped.
    private func run(_ operation: @escaping () async -> String?) {
        busy = true
        Task {
            let before = treeSignature()
            let result = await operation()
            if let result {
                busy = false
                error = result
                return
            }
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(150))
                if treeSignature() != before { break }
            }
            busy = false
        }
    }

    /// A fingerprint of the current tmux tree, used to detect when a create or
    /// kill has landed in a fresh snapshot.
    private func treeSignature() -> String {
        guard let s = model.state(targetID)?.snapshot else { return "nil" }
        let sessions = s.sessions.map(\.id).sorted().joined(separator: ",")
        let panes = s.memberships.map(\.paneID).sorted().joined(separator: ",")
        return "\(sessions)|\(panes)"
    }

    // MARK: Tree model

    struct KillRequest {
        enum Kind { case session, window, pane }
        let kind: Kind
        let id: String
        let label: String
    }

    struct Node: Identifiable {
        let id: String
        let kind: Kind
        var children: [Node]?
        enum Kind {
            case session(name: String, windowCount: Int)
            case window(index: Int, name: String)
            case pane(command: String, agent: AgentKind?, activity: AgentActivity)
        }
    }

    private func nodes(in snapshot: InventorySnapshot) -> [Node] {
        let state = model.state(targetID)
        // Hide AgentMux's own grouped mirror sessions ("agentmux-…"); they just
        // mirror a real session's windows and aren't the user's to manage.
        return snapshot.sessions.filter { !$0.name.hasPrefix(RemoteCommand.groupedSessionPrefix) }.map { session in
            let rows = snapshot.memberships.filter { $0.sessionID == session.id }
            let windowIDs = rows.map(\.windowID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let windows = windowIDs.map { windowID -> Node in
                let window = snapshot.windows.first { $0.id == windowID }
                let windowRows = rows.filter { $0.windowID == windowID }.sorted { $0.paneIndex < $1.paneIndex }
                let panes = windowRows.compactMap { r -> Node? in
                    guard let pane = snapshot.pane(r.paneID) else { return nil }
                    let kind = state?.detections[pane.id]?.kind
                    let agent = (kind == .codex || kind == .claudeCode) ? kind : nil
                    return Node(id: pane.id, kind: .pane(command: pane.currentCommand, agent: agent, activity: state?.activities[pane.id] ?? .unknown), children: nil)
                }
                return Node(id: windowID, kind: .window(index: windowRows.first?.windowIndex ?? 0, name: window?.name ?? ""), children: panes)
            }
            return Node(id: session.id, kind: .session(name: session.name, windowCount: windows.count), children: windows)
        }
    }
}

private struct NewSessionSheet: View {
    @Binding var name: String
    let container: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session").font(.headline)
                Label(container, systemImage: "shippingbox")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Name", text: $name, prompt: Text("work"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("A detached tmux session; names with spaces, “.” or “:” are not allowed.")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(where: { " .:".contains($0) })
    }

    private func create() {
        guard isValid else { return }
        onCreate(name)
        dismiss()
    }
}

/// Launch (or resume) a Claude Code / Codex agent: pick the account (config
/// dir), then resume chosen past sessions or start fresh in a project dir. Each
/// launched agent lands in its own new tmux session. Session metadata only —
/// never message text.
private struct LaunchAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let targetID: String

    @State private var kind: AgentKind = .claudeCode
    @State private var configDirs: [AgentConfigDir] = []
    @State private var selectedDir: AgentConfigDir?
    @State private var resuming = true
    @State private var sessions: [AgentSessionInfo] = []
    @State private var picked: Set<String> = []
    @State private var freshCwd = ""
    @State private var browsing = false
    @State private var destination = ""   // "" = new session, else a session id
    @State private var loadingDirs = true
    @State private var loadingSessions = false
    @State private var launching = false
    @State private var error: String?

    private var dirsForKind: [AgentConfigDir] { configDirs.filter { $0.kind == kind } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch Agent").font(.headline)
                Label(model.state(targetID)?.device.name ?? targetID, systemImage: "shippingbox")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Agent", selection: $kind) {
                Text("Claude Code").tag(AgentKind.claudeCode)
                Text("Codex").tag(AgentKind.codex)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in selectDefaultDir(); Task { await loadSessions() } }

            HStack {
                Text("Account").foregroundStyle(.secondary)
                Picker("Account", selection: Binding(get: { selectedDir }, set: { selectedDir = $0; Task { await loadSessions() } })) {
                    if dirsForKind.isEmpty { Text("none found").tag(Optional<AgentConfigDir>.none) }
                    ForEach(dirsForKind) { dir in
                        Text(dir.label).tag(Optional(dir))
                    }
                }
                .labelsHidden()
                if loadingDirs { ProgressView().controlSize(.small) }
            }

            Picker("Mode", selection: $resuming) {
                Text("Resume existing").tag(true)
                Text("Start fresh").tag(false)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Start in").foregroundStyle(.secondary)
                Picker("Start in", selection: $destination) {
                    Text("New session").tag("")
                    ForEach(model.realSessions(targetID), id: \.id) { s in
                        Text("session: \(s.name.isEmpty ? s.id : s.name)").tag(s.id)
                    }
                }
                .labelsHidden()
            }

            Divider()

            if resuming { resumeList } else { freshFields }

            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }

            HStack {
                if launching { ProgressView().controlSize(.small); Text("Launching…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Launch") { launch() }.keyboardShortcut(.defaultAction)
                    .disabled(!canLaunch)
            }
        }
        .padding(18)
        .frame(width: 540, height: 580)
        .task { await loadDirs() }
    }

    @ViewBuilder private var resumeList: some View {
        if loadingSessions {
            centered { ProgressView(); Text("Loading sessions…").font(.caption).foregroundStyle(.secondary) }
        } else if selectedDir == nil {
            centered { Text("No account selected.").foregroundStyle(.secondary) }
        } else if sessions.isEmpty {
            centered { Text("No past sessions for this account.").foregroundStyle(.secondary) }
        } else {
            List(sessions) { session in
                Button { toggle(session.id) } label: {
                    SessionPickRow(session: session, picked: picked.contains(session.id))
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var freshFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project directory").foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Path", text: $freshCwd, prompt: Text("/data/project"))
                    .textFieldStyle(.roundedBorder)
                if !knownDirs.isEmpty {
                    Menu {
                        ForEach(knownDirs, id: \.self) { dir in
                            Button(dir) { freshCwd = dir }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Existing project directories on this container")
                }
                Button { browsing = true } label: { Image(systemName: "folder") }
                    .help("Browse the container")
            }
            Text("A new \(kind == .codex ? "Codex" : "Claude Code") agent starts in a tmux session here — created if it doesn't exist.")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $browsing) {
            if let state = model.state(targetID) {
                RemoteDirPicker(host: state.host, target: state.target, start: browseStart) { freshCwd = $0 }
            }
        }
    }

    /// Distinct cwds of agents / panes already on this container — the common
    /// case for a new launch is reusing an existing project.
    private var knownDirs: [String] {
        let agents = model.allAgentEntries.filter { $0.ref.targetID == targetID }.map(\.space.path)
        let panes = model.paneEntries.filter { $0.ref.targetID == targetID }.map(\.space.path)
        return Array(Set(agents + panes)).filter { !$0.isEmpty && $0 != "~" }.sorted()
    }

    private var browseStart: String {
        let typed = freshCwd.trimmingCharacters(in: .whitespaces)
        if typed.hasPrefix("/") { return typed }
        if let first = knownDirs.first { return (first as NSString).deletingLastPathComponent }
        return "/"
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canLaunch: Bool {
        guard !launching, selectedDir != nil else { return false }
        return resuming ? !picked.isEmpty : !freshCwd.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    // MARK: Loading

    private func loadDirs() async {
        loadingDirs = true
        if case let .success(dirs) = await model.agentConfigDirs(targetID) { configDirs = dirs }
        loadingDirs = false
        selectDefaultDir()
        await loadSessions()
    }

    private func selectDefaultDir() {
        if selectedDir == nil || selectedDir?.kind != kind { selectedDir = dirsForKind.first }
    }

    private func loadSessions() async {
        picked = []
        guard let dir = selectedDir else { sessions = []; return }
        loadingSessions = true
        sessions = []
        switch await model.agentSessions(targetID, dir) {
        case let .success(list): sessions = list
        case let .failure(f): error = "\(f.kind.rawValue): \(f.detail)"
        }
        loadingSessions = false
    }

    private func launch() {
        guard let dir = selectedDir else { return }
        launching = true
        error = nil
        let into = destination
        Task {
            var failures: [String] = []
            func start(cwd: String, resumeID: String?) async -> String? {
                if into.isEmpty {
                    return await model.launchAgent(targetID, kind: kind, configDir: dir.path, cwd: cwd, resumeID: resumeID)
                } else {
                    return await model.launchAgentInWindow(targetID, sessionID: into, kind: kind, configDir: dir.path, cwd: cwd, resumeID: resumeID)
                }
            }
            if resuming {
                for session in sessions where picked.contains(session.id) {
                    if let e = await start(cwd: session.cwd, resumeID: session.id) { failures.append(e) }
                }
            } else {
                let cwd = freshCwd.trimmingCharacters(in: .whitespaces)
                // Create the directory if it doesn't exist (idempotent), so a
                // brand-new project path works.
                if let state = model.state(targetID),
                   case let .failure(f) = await RemoteFileService.makeDirectory(cwd, host: state.host, target: state.target) {
                    failures.append("\(f.kind.rawValue): \(f.detail)")
                } else if let e = await start(cwd: cwd, resumeID: nil) {
                    failures.append(e)
                }
            }
            launching = false
            if failures.isEmpty { dismiss() } else { error = failures.joined(separator: "\n") }
        }
    }
}

/// A remote directory picker: navigate the container's folders, make a new one,
/// and choose the current folder. Dir-only (read lists + one `mkdir` write).
private struct RemoteDirPicker: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostConfig
    let target: TargetConfig
    let onChoose: (String) -> Void

    @State private var cwd: String
    @State private var dirs: [RemoteFileEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var makingFolder = false
    @State private var newName = ""

    init(host: HostConfig, target: TargetConfig, start: String, onChoose: @escaping (String) -> Void) {
        self.host = host
        self.target = target
        self.onChoose = onChoose
        _cwd = State(initialValue: start.isEmpty ? "/" : start)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { up() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(cwd == "/")
                Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            Group {
                if let error {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if dirs.isEmpty, !loading {
                    Text("No subfolders").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(dirs) { dir in
                            Button { cwd = dir.path } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent).frame(width: 16)
                                    Text(dir.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.listStyle(.inset)
                }
            }
            Divider()
            HStack {
                Button { newName = ""; makingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose") { onChoose(cwd); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 460, height: 460)
        .task(id: cwd) { await load() }
        .alert("New folder in \((cwd as NSString).lastPathComponent)", isPresented: $makingFolder) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func load() async {
        error = nil
        loading = true
        defer { loading = false }
        switch await RemoteFileService.list(cwd, host: host, target: target) {
        case let .success(items): dirs = items.filter(\.isDirectory)
        case let .failure(f): dirs = []; error = "\(f.kind.rawValue): \(f.detail)"
        }
    }

    private func up() {
        let parent = (cwd as NSString).deletingLastPathComponent
        cwd = parent.isEmpty ? "/" : parent
    }

    private func createFolder() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        let path = (cwd as NSString).appendingPathComponent(name)
        switch await RemoteFileService.makeDirectory(path, host: host, target: target) {
        case .success: cwd = path // navigate into the new folder
        case let .failure(f): error = "\(f.kind.rawValue): \(f.detail)"
        }
    }
}

private struct SessionPickRow: View {
    let session: AgentSessionInfo
    let picked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(picked ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(SpaceLabel.label(session.cwd)).lineLimit(1)
                Text(session.cwd).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let rel = RelativeTime.short(max(0, Int(Date().timeIntervalSince1970) - session.lastActiveEpoch)) {
                    Text(rel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("\(session.eventCount) events").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
