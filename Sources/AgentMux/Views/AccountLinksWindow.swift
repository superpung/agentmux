import AgentMuxCore
import SwiftUI

/// A read-only window that visualizes how a container's Claude accounts share
/// chat sessions. When several accounts' `projects/<cwd>` dirs are symlinked to
/// the same real directory, they share that project's sessions, so an agent
/// running there can be switched between them (the switch itself is offered
/// from the agent terminal's "⋯" menu). A green dot marks an account that
/// currently has a running agent in that project.
struct AccountLinksWindow: View {
    @Environment(AppModel.self) private var model
    @Binding var targetID: String
    @State private var groups: [ProjectLinkGroup] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { Task { await load() } }
        .onChange(of: targetID) { _, _ in
            groups = [] // a different container's links; don't show stale rows
            Task { await load() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-scan this container")
                .disabled(loading || model.state(targetID) == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read accounts", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if groups.isEmpty, loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning accounts…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No Claude accounts",
                systemImage: "person.2.slash",
                description: Text("No Claude account directories with projects were found in this container.")
            )
        } else {
            List {
                let shared = groups.filter(\.isShared)
                let independent = groups.filter { !$0.isShared }
                if !shared.isEmpty {
                    Section("Shared — switchable accounts") {
                        ForEach(shared) { GroupRow(group: $0, running: running(in: $0)) }
                    }
                }
                let scratch = independent.filter { $0.cwd.hasPrefix("/tmp/") || $0.label.hasPrefix("/tmp/") }
                let projects = independent.filter { !($0.cwd.hasPrefix("/tmp/") || $0.label.hasPrefix("/tmp/")) }
                if !projects.isEmpty {
                    Section("Independent") {
                        ForEach(projects) { GroupRow(group: $0, running: running(in: $0)) }
                    }
                }
                if !scratch.isEmpty {
                    Section {
                        DisclosureGroup("Temporary (/tmp) — \(scratch.count)") {
                            ForEach(scratch) { GroupRow(group: $0, running: running(in: $0)) }
                        }
                    }
                }
            }
        }
    }

    /// Config dirs with a Claude agent currently running in this project.
    private func running(in group: ProjectLinkGroup) -> Set<String> {
        guard !group.cwd.isEmpty else { return [] }
        return Set(model.allAgentEntries
            .filter { $0.kind == .claudeCode && $0.space.path == group.cwd }
            .compactMap(\.configDir))
    }

    private func load() async {
        guard let state = model.state(targetID) else { groups = []; return }
        loading = true
        error = nil
        let result = await AgentSessionProbe.projectLinks(host: state.host, target: state.target)
        loading = false
        switch result {
        case let .success(entries):
            groups = AgentSessionProbe.linkGroups(from: entries)
        case let .failure(failure):
            groups = []
            error = failure.detail.isEmpty ? failure.kind.rawValue : failure.detail
        }
    }
}

private struct GroupRow: View {
    let group: ProjectLinkGroup
    let running: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.isShared ? "link" : "doc.text")
                    .foregroundStyle(group.isShared ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(group.label)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(group.sessionCount) session\(group.sessionCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(group.accounts, id: \.self) { account in
                    AccountChip(name: (account as NSString).lastPathComponent,
                                isRunning: running.contains(account))
                }
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }
}

private struct AccountChip: View {
    let name: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isRunning { Circle().fill(.green).frame(width: 6, height: 6) }
            Text(name).font(.caption.monospaced())
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(isRunning ? Color.green.opacity(0.14) : Color.secondary.opacity(0.1), in: Capsule())
        .help(isRunning ? "\(name): an agent is running in this project" : name)
    }
}
