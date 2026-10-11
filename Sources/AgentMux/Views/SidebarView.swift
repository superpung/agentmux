import AgentMuxCore
import SwiftUI

/// How the sidebar groups agents into sections.
enum AgentGrouping: String, CaseIterable, Identifiable {
    case project
    case container
    case status

    var id: String { rawValue }

    var label: String {
        switch self {
        case .project: return "Project"
        case .container: return "Container"
        case .status: return "Status"
        }
    }

    var systemImage: String {
        switch self {
        case .project: return "folder"
        case .container: return "shippingbox"
        case .status: return "circle.dashed"
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: PaneRef?
    @State private var query = ""
    @AppStorage("agentGrouping") private var groupingRaw = AgentGrouping.project.rawValue

    private var grouping: AgentGrouping { AgentGrouping(rawValue: groupingRaw) ?? .project }

    var body: some View {
        List(selection: $selection) {
            if agentGroups.isEmpty, filteredPanes.isEmpty {
                emptyRow
            }
            ForEach(agentGroups) { group in
                Section(group.label) {
                    ForEach(group.agents) { agent in
                        AgentRow(entry: agent, showDevice: showDevice)
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
                Menu {
                    Picker("Group by", selection: $groupingRaw) {
                        ForEach(AgentGrouping.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                        }
                    }
                } label: {
                    Label("Group by", systemImage: "rectangle.3.group")
                }
                .help("Group agents by project, container or status")
            }
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

    /// When grouping by container, the container is the section header, so the
    /// per-row device badge would be redundant.
    private var showDevice: Bool {
        grouping != .container && model.showsAgentDeviceBadge
    }

    private struct AgentGroup: Identifiable {
        var id: String
        var label: String
        var agents: [AgentEntry]
    }

    private func matches(_ haystack: String) -> Bool {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return true }
        let lower = haystack.lowercased()
        return terms.allSatisfy { lower.contains($0) }
    }

    private var matchedAgents: [AgentEntry] {
        model.agentEntries.filter { matches("\($0.title) \($0.kind.label) \($0.space.path) \($0.device.name)") }
    }

    private var agentGroups: [AgentGroup] {
        switch grouping {
        case .project:
            // Keep tmux order within a project so rows don't jump as state changes.
            return grouped(by: { "\($0.space.targetID)\n\($0.space.path)" }, label: { SpaceLabel.label($0.space.path) })
        case .container:
            return grouped(by: { $0.device.id }, label: { $0.device.name })
        case .status:
            return statusGroups()
        }
    }

    /// Groups the matched agents by `key`, preserving first-seen (tmux) order
    /// both of the groups and of the rows within each group.
    private func grouped(by key: (AgentEntry) -> String, label: (AgentEntry) -> String) -> [AgentGroup] {
        var order: [String] = []
        var labels: [String: String] = [:]
        var rows: [String: [AgentEntry]] = [:]
        for agent in matchedAgents {
            let k = key(agent)
            if rows[k] == nil { order.append(k); labels[k] = label(agent) }
            rows[k, default: []].append(agent)
        }
        return order.map { AgentGroup(id: $0, label: labels[$0] ?? $0, agents: rows[$0] ?? []) }
    }

    /// Buckets agents by activity, in attention → working → idle → other order.
    private func statusGroups() -> [AgentGroup] {
        let buckets: [(id: String, label: String, test: (AgentActivity) -> Bool)] = [
            ("attention", "Needs attention", { $0.needsAttention }),
            ("working", "Working", { $0 == .working }),
            ("idle", "Idle", { $0 == .idle }),
            ("exited", "Exited", { $0 == .exited }),
            ("other", "Unknown", { $0 == .unknown }),
        ]
        return buckets.compactMap { bucket in
            let agents = matchedAgents.filter { bucket.test($0.activity) }
            return agents.isEmpty ? nil : AgentGroup(id: bucket.id, label: bucket.label, agents: agents)
        }
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
