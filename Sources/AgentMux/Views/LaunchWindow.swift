import AgentMuxCore
import SwiftUI

/// Standalone per-container page: lists every past Claude Code / Codex
/// conversation across all of the container's accounts (most recent first),
/// each with a one-line preview of its last message, and resumes any of them
/// under a chosen account, into a new or existing tmux session. The container
/// picker lives in `ContainerWindow`, so this stays per-container by design.
struct LaunchWindow: View {
    @Environment(AppModel.self) private var model
    @Binding var targetID: String

    @State private var configDirs: [AgentConfigDir] = []
    @State private var sessions: [AgentSessionInfo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var kindFilter: KindFilter = .all
    @State private var destination = ""        // "" = a new tmux session
    @State private var launchingID: String?

    enum KindFilter: String, CaseIterable, Sendable {
        case all, claude, codex
        var label: String { self == .all ? "All" : self == .claude ? "Claude" : "Codex" }
    }

    private var shown: [AgentSessionInfo] {
        sessions.filter {
            switch kindFilter {
            case .all: return true
            case .claude: return $0.kind == .claudeCode
            case .codex: return $0.kind == .codex
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .animation(Motion.quick, value: "\(loading)\(shown.isEmpty)\(error ?? "")")
        }
        .onAppear { if sessions.isEmpty { Task { await load() } } }
        .onChange(of: targetID) { _, _ in sessions = []; configDirs = []; Task { await load() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Kind", selection: $kindFilter) {
                ForEach(KindFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 4) {
                Text("Start in").font(.caption).foregroundStyle(.secondary)
                Picker("Start in", selection: $destination) {
                    Text("New session").tag("")
                    ForEach(model.realSessions(targetID), id: \.id) { s in
                        Text(s.name.isEmpty ? s.id : s.name).tag(s.id)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-scan this container")
                .disabled(loading || model.state(targetID) == nil)
        }
        .animation(Motion.quick, value: loading)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't load conversations", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if shown.isEmpty, loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading conversations…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right")
        } else {
            List(shown) { session in
                ConversationRow(
                    session: session,
                    accounts: configDirs.filter { $0.kind == session.kind },
                    launching: launchingID == session.id,
                    onResume: { account in resume(session, under: account) }
                )
            }
            .listStyle(.inset)
        }
    }

    private func load() async {
        guard model.state(targetID) != nil else { sessions = []; configDirs = []; return }
        loading = true
        error = nil
        if case let .success(dirs) = await model.agentConfigDirs(targetID) { configDirs = dirs }
        // Each account's sessions load concurrently, then merge, most-recent first.
        var all: [AgentSessionInfo] = []
        await withTaskGroup(of: [AgentSessionInfo].self) { group in
            for dir in configDirs {
                group.addTask {
                    if case let .success(list) = await model.agentSessions(targetID, dir) { return list }
                    return []
                }
            }
            for await list in group { all.append(contentsOf: list) }
        }
        // Accounts whole-dir-symlink their projects/sessions to one shared store,
        // so each account's probe returns the same conversations. Collapse to one
        // row per (kind, id); the row still offers every account as a resume target.
        var seen = Set<String>()
        let unique = all.filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }
        sessions = unique.sorted { $0.lastActiveEpoch > $1.lastActiveEpoch }
        loading = false
    }

    private func resume(_ session: AgentSessionInfo, under account: AgentConfigDir) {
        launchingID = session.id
        error = nil
        Task {
            let err: String?
            if destination.isEmpty {
                err = await model.launchAgent(targetID, kind: session.kind, configDir: account.path, cwd: session.cwd, resumeID: session.id)
            } else {
                err = await model.launchAgentInWindow(targetID, sessionID: destination, kind: session.kind, configDir: account.path, cwd: session.cwd, resumeID: session.id)
            }
            launchingID = nil
            if let err { error = err }
        }
    }
}

private struct ConversationRow: View {
    let session: AgentSessionInfo
    let accounts: [AgentConfigDir]
    let launching: Bool
    let onResume: (AgentConfigDir) -> Void

    private var ownAccount: AgentConfigDir { AgentConfigDir(kind: session.kind, path: session.configDir) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let resource = BrandIconLoader.agentIcon(for: session.kind) {
                    BrandIcon(resource: resource, size: 16)
                } else {
                    Image(systemName: session.kind == .claudeCode ? "sparkle" : "terminal")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((session.cwd as NSString).lastPathComponent)
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if !session.configDir.isEmpty {
                        Text((session.configDir as NSString).lastPathComponent)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 6)
                    if session.lastActiveEpoch > 0 {
                        Text(relativeTime(session.lastActiveEpoch)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(session.cwd).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if !session.preview.isEmpty {
                    Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            resumeControl
        }
        .padding(.vertical, 4)
    }

    private var resumeControl: some View {
        Group { resumeChoice }.animation(Motion.quick, value: launching)
    }

    @ViewBuilder private var resumeChoice: some View {
        if launching {
            ProgressView().controlSize(.small).frame(width: 96, alignment: .trailing)
        } else if accounts.count <= 1 {
            Button("Resume") { onResume(accounts.first ?? ownAccount) }
                .frame(width: 96, alignment: .trailing)
        } else {
            Menu("Resume…") {
                ForEach(accounts) { acct in
                    Button(acct.label + (acct.path == session.configDir ? "  (own)" : "")) { onResume(acct) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }
}

private func relativeTime(_ epoch: Int) -> String {
    guard epoch > 0 else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(epoch)), relativeTo: Date())
}
