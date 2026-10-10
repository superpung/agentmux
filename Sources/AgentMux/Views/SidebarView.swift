import AgentMuxCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: PaneRef?
    @State private var query = ""

    var body: some View {
        List(selection: $selection) {
            if agentSpaces.isEmpty, filteredPanes.isEmpty {
                emptyRow
            }
            ForEach(agentSpaces, id: \.space) { group in
                Section(group.label) {
                    ForEach(group.agents) { agent in
                        AgentRow(entry: agent, showDevice: model.showsAgentDeviceBadge)
                            .tag(agent.ref)
                    }
                }
            }
            if !filteredPanes.isEmpty {
                Section("Terminals") {
                    ForEach(filteredPanes) { pane in
                        PaneRow(entry: pane, showDevice: model.showsPaneDeviceBadge)
                            .tag(pane.ref)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search agents")
        .navigationTitle("AgentMux")
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh all targets")
            }
        }
        .safeAreaInset(edge: .bottom) { StatusFooter() }
    }

    // MARK: Filtered data

    private struct SpaceGroup: Hashable {
        var space: SpaceKey
        var label: String
        var agents: [AgentEntry]
    }

    private func matches(_ haystack: String) -> Bool {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return true }
        let lower = haystack.lowercased()
        return terms.allSatisfy { lower.contains($0) }
    }

    private var agentSpaces: [SpaceGroup] {
        var order: [SpaceKey] = []
        var grouped: [SpaceKey: [AgentEntry]] = [:]
        for agent in model.agentEntries where matches("\(agent.title) \(agent.kind.label) \(agent.space.path) \(agent.device.name)") {
            if grouped[agent.space] == nil { order.append(agent.space) }
            grouped[agent.space, default: []].append(agent)
        }
        return order.map { SpaceGroup(space: $0, label: SpaceLabel.label($0.path), agents: grouped[$0] ?? []) }
    }

    private var filteredPanes: [PaneEntry] {
        model.paneEntries.filter { matches("\($0.title) \($0.command) \($0.space.path) \($0.device.name)") }
    }

    private var emptyRow: some View {
        let text: String
        if let failure = model.targets.compactMap(\.lastFailure).first, model.targets.allSatisfy({ $0.snapshot == nil }) {
            text = failure.kind.rawValue
        } else if model.targets.contains(where: { $0.snapshot == nil }) {
            text = "Connecting…"
        } else {
            text = query.isEmpty ? "No agents found" : "No matches"
        }
        return Text(text).foregroundStyle(.secondary)
    }
}

// MARK: - Rows

private struct AgentRow: View {
    let entry: AgentEntry
    let showDevice: Bool

    var body: some View {
        HStack(spacing: 8) {
            agentIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.kind.label)
                    if showDevice {
                        Text("·")
                        Text(entry.device.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            AgentStatusGlyph(activity: entry.activity)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var agentIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: entry.kind) {
            BrandIcon(resource: resource, size: 15)
        } else {
            Image(systemName: "terminal")
        }
    }
}

private struct PaneRow: View {
    let entry: PaneEntry
    let showDevice: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                Text(showDevice ? "\(entry.command) · \(entry.device.name)" : entry.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Connection summary pinned to the bottom of the sidebar.
private struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(statusText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    private var dotColor: Color {
        if model.targets.contains(where: { $0.lastFailure != nil }) { return .red }
        if model.targets.allSatisfy(\.isOnline) { return .green }
        return .orange
    }

    private func statusText(now: Date) -> String {
        if let failure = model.targets.compactMap(\.lastFailure).first,
           model.targets.allSatisfy({ $0.snapshot == nil })
        {
            return failure.kind.rawValue
        }
        let newest = model.targets.compactMap(\.lastSuccess).max()
        guard let newest else { return "Connecting…" }
        let seconds = max(0, Int(now.timeIntervalSince(newest)))
        let ago = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
        return "\(model.scopeAgentCount) agents · updated \(ago)"
    }
}
