import AgentMuxCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Agents") {
                let rows = model.agentRows
                if rows.isEmpty {
                    Text("No agents found yet").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    AgentRowView(row: row)
                        .tag(row.ref)
                }
            }
            ForEach(model.targets) { state in
                Section {
                    TargetTreeView(state: state)
                } header: {
                    TargetHeaderView(state: state)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        HStack(spacing: 8) {
            AgentBadge(kind: row.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.location).lineLimit(1)
                Text(verbatim: [row.targetID, row.configDirectory.map { ($0 as NSString).lastPathComponent }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct AgentBadge: View {
    let kind: AgentKind

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private var label: String {
        switch kind {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .none: "shell"
        case .unknown: "?"
        }
    }

    private var color: Color {
        switch kind {
        case .codex: .blue
        case .claudeCode: .orange
        case .none, .unknown: .secondary
        }
    }
}

struct TargetHeaderView: View {
    let state: TargetState

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: state.target.id)
            if let container = state.target.container {
                Text(verbatim: "· \(container)").foregroundStyle(.secondary)
            }
            if state.target.access == .observe {
                Text("observe").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            FreshnessView(state: state)
        }
    }
}

/// Connection state in words, with the time of the last verification.
struct FreshnessView: View {
    let state: TargetState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if state.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Text(verbatim: text(now: context.date))
                    .font(.caption2)
                    .foregroundStyle(state.lastFailure == nil ? Color.secondary : Color.red)
            }
        }
    }

    private func text(now: Date) -> String {
        let verified = state.lastSuccess.map { "verified \(Self.ago($0, now: now))" }
        if let failure = state.lastFailure {
            return ["\(failure.kind.rawValue)", verified].compactMap { $0 }.joined(separator: " · ")
        }
        return verified ?? "connecting"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }
}

struct TargetTreeView: View {
    let state: TargetState

    var body: some View {
        if let snapshot = state.snapshot {
            if let failure = snapshot.failure {
                Text(verbatim: "\(failure.kind.rawValue) \(failure.detail)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.sessions) { session in
                DisclosureGroup {
                    let rows = snapshot.memberships.filter { $0.sessionID == session.id }
                    ForEach(windowIDs(rows), id: \.self) { windowID in
                        DisclosureGroup {
                            ForEach(rows.filter { $0.windowID == windowID }, id: \.paneID) { row in
                                if let pane = snapshot.pane(row.paneID), let ref = state.ref(for: pane.id) {
                                    PaneRowView(pane: pane, row: row, detection: state.detections[pane.id])
                                        .tag(ref)
                                }
                            }
                        } label: {
                            let window = snapshot.windows.first { $0.id == windowID }
                            let index = rows.first { $0.windowID == windowID }?.windowIndex ?? 0
                            Text(verbatim: "\(index): \(window?.name ?? windowID)").lineLimit(1)
                        }
                    }
                } label: {
                    Text(verbatim: session.name).lineLimit(1)
                }
            }
        } else if let failure = state.lastFailure {
            Text(verbatim: "\(failure.kind.rawValue) \(failure.detail)")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("Connecting…").foregroundStyle(.secondary)
        }
    }

    private func windowIDs(_ rows: [InventorySnapshot.Membership]) -> [String] {
        var seen = Set<String>()
        return rows.map(\.windowID).filter { seen.insert($0).inserted }
    }
}

struct PaneRowView: View {
    let pane: InventorySnapshot.Pane
    let row: InventorySnapshot.Membership
    let detection: AgentDetection?

    var body: some View {
        HStack(spacing: 6) {
            if let detection, detection.kind == .codex || detection.kind == .claudeCode {
                AgentBadge(kind: detection.kind)
            }
            Text(verbatim: "\(row.paneIndex) \(pane.currentCommand)").lineLimit(1)
            Text(verbatim: pane.id).font(.caption2).foregroundStyle(.tertiary)
            if pane.dead {
                Text("dead").font(.caption2).foregroundStyle(.red)
            }
        }
        .help(Text(verbatim: pane.currentPath))
    }
}
