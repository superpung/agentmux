import AgentMuxCore
import SwiftUI

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
            if let state = model.state(targetID), let snapshot = state.snapshot {
                tree(for: state, snapshot: snapshot)
            } else {
                ContentUnavailableView("No tmux sessions", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("This container has no running tmux server, or isn't connected yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            NewSessionSheet(name: $newSessionName) { name in
                run { await model.newSession(targetID, name: name) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Container", selection: $targetID) {
                ForEach(model.targets) { state in
                    Text(state.device.name).tag(state.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                newSessionName = ""
                showNewSession = true
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .disabled(model.state(targetID) == nil)
        }
        .padding(12)
    }

    // MARK: Tree

    private func tree(for state: TargetState, snapshot: InventorySnapshot) -> some View {
        List {
            ForEach(sessions(in: snapshot)) { session in
                Section {
                    ForEach(session.windows) { window in
                        windowRow(window, state: state)
                        ForEach(window.panes) { pane in
                            paneRow(pane, state: state)
                        }
                    }
                } header: {
                    sessionHeader(session)
                }
            }
        }
    }

    private func sessionHeader(_ session: SessionItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
            Text(session.name.isEmpty ? session.id : session.name).fontWeight(.medium)
            Text(session.id).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { run { await model.newWindow(targetID, sessionID: session.id) } } label: {
                Image(systemName: "plus.rectangle")
            }
            .buttonStyle(.borderless).help("New window in this session")
            Button { confirm = KillRequest(kind: .session, id: session.id, label: "session \(session.name.isEmpty ? session.id : session.name)") } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Kill this session and all its windows")
        }
    }

    private func windowRow(_ window: WindowItem, state: TargetState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow").foregroundStyle(.secondary)
            Text("\(window.index): \(window.name.isEmpty ? window.id : window.name)")
            Spacer()
            Button { confirm = KillRequest(kind: .window, id: window.id, label: "window \(window.name.isEmpty ? window.id : window.name)") } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Kill this window")
        }
        .padding(.leading, 12)
    }

    private func paneRow(_ pane: PaneItem, state: TargetState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").foregroundStyle(.tertiary)
            Text(pane.command).monospaced()
            if let agent = pane.agent {
                Text(agent).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { confirm = KillRequest(kind: .pane, id: pane.id, label: "pane \(pane.id) (\(pane.command))") } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Kill this pane")
        }
        .font(.caption)
        .padding(.leading, 28)
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

    private func run(_ operation: @escaping () async -> String?) {
        busy = true
        Task {
            let result = await operation()
            busy = false
            if let result { error = result }
        }
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

    struct SessionItem: Identifiable { var id: String; var name: String; var windows: [WindowItem] }
    struct WindowItem: Identifiable { var id: String; var name: String; var index: Int; var panes: [PaneItem] }
    struct PaneItem: Identifiable { var id: String; var command: String; var agent: String? }

    private func sessions(in snapshot: InventorySnapshot) -> [SessionItem] {
        snapshot.sessions.map { session in
            let rows = snapshot.memberships.filter { $0.sessionID == session.id }
            let windowIDs = rows.map(\.windowID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let windows = windowIDs.map { windowID -> WindowItem in
                let window = snapshot.windows.first { $0.id == windowID }
                let windowRows = rows.filter { $0.windowID == windowID }.sorted { $0.paneIndex < $1.paneIndex }
                let panes = windowRows.compactMap { row -> PaneItem? in
                    guard let pane = snapshot.pane(row.paneID) else { return nil }
                    return PaneItem(id: pane.id, command: pane.currentCommand, agent: agentLabel(pane.id))
                }
                return WindowItem(id: windowID, name: window?.name ?? "", index: windowRows.first?.windowIndex ?? 0, panes: panes)
            }
            return SessionItem(id: session.id, name: session.name, windows: windows)
        }
    }

    private func agentLabel(_ paneID: String) -> String? {
        guard let state = model.state(targetID), let kind = state.detections[paneID]?.kind,
              kind == .codex || kind == .claudeCode else { return nil }
        let activity = state.activities[paneID] ?? .unknown
        let name = kind == .codex ? "codex" : "claude"
        return activity == .working ? "\(name) · working" : name
    }
}

private struct NewSessionSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.headline)
            TextField("Name", text: $name, prompt: Text("work"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        onCreate(name)
        dismiss()
    }
}
