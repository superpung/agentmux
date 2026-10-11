import AgentMuxCore
import SwiftUI

/// A dimension the sidebar can group agents by.
enum GroupBy: String, CaseIterable, Identifiable {
    case container
    case project
    case session
    case status

    var id: String { rawValue }

    var label: String {
        switch self {
        case .container: return "Container"
        case .project: return "Project"
        case .session: return "Session"
        case .status: return "Status"
        }
    }

    var systemImage: String {
        switch self {
        case .container: return "shippingbox"
        case .project: return "folder"
        case .session: return "rectangle.split.3x1"
        case .status: return "circle.dashed"
        }
    }

    /// A stable identity for an agent's group on this dimension.
    func key(_ e: AgentEntry) -> String {
        switch self {
        case .container: return e.device.id
        case .project: return "\(e.space.targetID)\n\(e.space.path)"
        case .session: return "\(e.space.targetID)\n\(e.session)"
        case .status: return SidebarView.statusBucket(e.activity).id
        }
    }

    func label(_ e: AgentEntry) -> String {
        switch self {
        case .container: return e.device.name
        case .project: return SpaceLabel.label(e.space.path)
        case .session: return e.session.isEmpty ? "—" : e.session
        case .status: return SidebarView.statusBucket(e.activity).label
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: PaneRef?
    @State private var query = ""
    @AppStorage("sidebarGroupBy") private var groupingRaw = GroupBy.project.rawValue
    @AppStorage("sidebarSubgroupBy") private var subgroupingRaw = ""

    private var grouping: GroupBy { GroupBy(rawValue: groupingRaw) ?? .project }
    /// The optional second level; ignored when it equals the primary dimension.
    private var subgrouping: GroupBy? {
        guard let sub = GroupBy(rawValue: subgroupingRaw), sub != grouping else { return nil }
        return sub
    }

    var body: some View {
        List(selection: $selection) {
            if groups.isEmpty, filteredPanes.isEmpty {
                emptyRow
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.leaves) { leaf in
                        if subgrouping != nil, !leaf.label.isEmpty {
                            subHeader(leaf.label)
                        }
                        ForEach(leaf.agents) { agent in
                            AgentRow(entry: agent, showDevice: showDevice)
                                .tag(agent.ref)
                                .listRowInsets(rowInsets)
                        }
                    }
                } header: {
                    if !group.label.isEmpty { Text(group.label) }
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
            ToolbarItem { groupingMenu }
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

    private var groupingMenu: some View {
        Menu {
            Picker("Group by", selection: $groupingRaw) {
                ForEach(GroupBy.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                }
            }
            Picker("Then by", selection: $subgroupingRaw) {
                Text("None").tag("")
                ForEach(GroupBy.allCases.filter { $0 != grouping }) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                }
            }
        } label: {
            Label("Group by", systemImage: "rectangle.3.group")
        }
        .help("Group agents, and optionally add a second level")
    }

    // MARK: Grouped data

    /// A smallest group of agents, time-sorted. Its label is empty when there
    /// is no subgrouping (it fills its parent section directly).
    private struct Leaf: Identifiable {
        var id: String
        var label: String
        var agents: [AgentEntry]
    }

    private struct Group: Identifiable {
        var id: String
        var label: String
        var leaves: [Leaf]
    }

    /// The container is already a section/subheader, so its per-row badge is
    /// redundant then.
    private var showDevice: Bool {
        grouping != .container && subgrouping != .container && model.showsAgentDeviceBadge
    }

    private var rowInsets: EdgeInsets? {
        subgrouping == nil ? nil : EdgeInsets(top: 2, leading: 26, bottom: 2, trailing: 10)
    }

    private func subHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 1, trailing: 10))
    }

    private func matches(_ haystack: String) -> Bool {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return true }
        let lower = haystack.lowercased()
        return terms.allSatisfy { lower.contains($0) }
    }

    private var matchedAgents: [AgentEntry] {
        model.agentEntries.filter { matches("\($0.title) \($0.kind.label) \($0.space.path) \($0.session) \($0.device.name)") }
    }

    private var groups: [Group] {
        partition(matchedAgents, by: grouping).map { primary in
            let leaves: [Leaf]
            if let sub = subgrouping {
                leaves = partition(primary.agents, by: sub).map { secondary in
                    Leaf(id: secondary.key, label: secondary.label, agents: byTime(secondary.agents))
                }
            } else {
                leaves = [Leaf(id: "·", label: "", agents: byTime(primary.agents))]
            }
            return Group(id: primary.key, label: primary.label, leaves: leaves)
        }
    }

    /// Groups agents on one dimension. Group order is semantic for status and
    /// first-seen (stable) otherwise, so whole sections don't reshuffle; agents
    /// within a leaf are time-sorted separately.
    private func partition(_ agents: [AgentEntry], by dim: GroupBy) -> [(key: String, label: String, agents: [AgentEntry])] {
        var order: [String] = []
        var labels: [String: String] = [:]
        var map: [String: [AgentEntry]] = [:]
        for agent in agents {
            let k = dim.key(agent)
            if map[k] == nil { order.append(k); labels[k] = dim.label(agent) }
            map[k, default: []].append(agent)
        }
        if dim == .status {
            order.sort { Self.statusRank($0) < Self.statusRank($1) }
        }
        return order.map { (key: $0, label: labels[$0] ?? $0, agents: map[$0] ?? []) }
    }

    /// Most-recently-active first; unknown ages last.
    private func byTime(_ agents: [AgentEntry]) -> [AgentEntry] {
        agents.sorted { ($0.lastActiveSeconds ?? .max) < ($1.lastActiveSeconds ?? .max) }
    }

    static func statusBucket(_ activity: AgentActivity) -> (id: String, label: String) {
        if activity.needsAttention { return ("attention", "Needs attention") }
        switch activity {
        case .working: return ("working", "Working")
        case .idle: return ("idle", "Idle")
        case .exited: return ("exited", "Exited")
        default: return ("unknown", "Unknown")
        }
    }

    static func statusRank(_ bucketID: String) -> Int {
        ["attention": 0, "working": 1, "idle": 2, "exited": 3, "unknown": 4][bucketID] ?? 5
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

/// Compact relative durations like "now", "45s", "12m", "3h", "2d".
enum RelativeTime {
    static func short(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
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
            if let active = RelativeTime.short(entry.lastActiveSeconds) {
                Text(active)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
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
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var dotColor: Color {
        if model.targets.contains(where: { $0.lastFailure != nil }) { return .red }
        if model.targets.allSatisfy(\.isOnline) { return .green }
        return .orange
    }

    /// Minimal: the agent count when healthy, or the error when not.
    private var statusText: String {
        if let failure = model.targets.compactMap(\.lastFailure).first,
           model.targets.allSatisfy({ $0.snapshot == nil })
        {
            return failure.kind.rawValue
        }
        if model.targets.contains(where: { $0.snapshot == nil }) { return "Connecting…" }
        let count = model.scopeAgentCount
        return "\(count) agent\(count == 1 ? "" : "s")"
    }
}
