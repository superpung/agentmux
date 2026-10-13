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
    @State private var targetID = ""
    @State private var confirm: KillRequest?
    @State private var newSessionName = ""
    @State private var showNewSession = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Sessions")
        .onAppear(perform: pickDefaultTarget)
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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
            Picker("Container", selection: $targetID) {
                ForEach(model.targets) { state in
                    Text(state.device.name).tag(state.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            if busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                newSessionName = ""
                showNewSession = true
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.state(targetID) == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                if model.state(targetID) != nil {
                    Button {
                        newSessionName = ""
                        showNewSession = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
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

    private func pickDefaultTarget() {
        if model.state(targetID) == nil {
            targetID = model.selection?.targetID ?? model.targets.first?.id ?? ""
        }
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
        return snapshot.sessions.map { session in
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
