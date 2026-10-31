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

/// Which agents the sidebar shows.
enum AgentFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All agents"
        case .active: return "Active"
        case .attention: return "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "circle.grid.2x2"
        case .active: return "bolt"
        case .attention: return "exclamationmark.circle"
        }
    }

    func includes(_ activity: AgentActivity) -> Bool {
        switch self {
        case .all: return true
        case .active: return activity == .working || activity.needsAttention
        case .attention: return activity.needsAttention
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @AppStorage("sidebarGroupBy") private var groupingRaw = GroupBy.project.rawValue
    @AppStorage("sidebarFilter") private var filterRaw = AgentFilter.all.rawValue
    @State private var renaming: AgentEntry?

    private var grouping: GroupBy { GroupBy(rawValue: groupingRaw) ?? .project }
    private var filter: AgentFilter { AgentFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        List(selection: selection) {
            if groups.isEmpty, filteredPanes.isEmpty {
                emptyRow
            }
            ForEach(groups) { group in
                let isPinned = group.id == Self.pinnedGroupID
                Section {
                    ForEach(group.agents) { agent in
                        // Pinned rows span containers/projects, so they show both
                        // badges to stay self-describing regardless of grouping.
                        AgentRow(entry: agent,
                                 showDevice: isPinned ? model.showsAgentDeviceBadge : showDevice,
                                 showServer: showServer,
                                 showProject: isPinned ? true : showProject)
                            .tag(agent.ref)
                            .contextMenu { rowMenu(agent) }
                    }
                } header: {
                    if isPinned {
                        // Plain HStack, not Label: Label tints the icon accent,
                        // and no colour override keeps the text the same native
                        // section-header colour as the container headers below.
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill").imageScale(.small)
                            Text("Pinned")
                        }
                    } else if !group.label.isEmpty {
                        Text(group.label)
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
        .animation(Motion.list, value: groups.map { g in g.agents.map { "\($0.id)" }.joined(separator: ",") }.joined(separator: "|"))
        .searchable(text: $query, placement: .sidebar, prompt: "Search agents")
        .navigationTitle("AgentMux")
        .toolbar {
            ToolbarItem { viewOptionsMenu }
            ToolbarItem {
                Button {
                    model.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh all targets")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter() }
        .sheet(item: $renaming) { agent in
            RenameSheet(current: model.customName(agent.identityKey) ?? "", placeholder: agent.title) { name in
                model.setCustomName(agent.identityKey, name)
            }
        }
    }

    /// One row fills the detail area; ⌘- or ⇧-clicking more rows shows them
    /// together (`AppModel.show`).
    private var selection: Binding<Set<PaneRef>> {
        Binding(
            get: { Set(model.isTiled ? model.tiles : model.selection.map { [$0] } ?? []) },
            set: { refs in
                if refs.count > TileLayout.maxTiles { NSSound.beep() }
                model.show(refs, sidebarOrder: groups.flatMap { $0.agents.map(\.ref) } + filteredPanes.map(\.ref))
            }
        )
    }

    @ViewBuilder private func rowMenu(_ agent: AgentEntry) -> some View {
        if model.pendingNudges[agent.ref] != nil {
            Button("Continue Now") { model.sendNudgeNow(agent.ref) }
            Button("Cancel Auto-continue") { model.cancelNudge(agent.ref) }
            Divider()
        }
        Button(model.isPinned(agent.identityKey) ? "Unpin" : "Pin") {
            model.togglePin(agent.identityKey)
        }
        Button("Rename…") { renaming = agent }
        if model.customName(agent.identityKey) != nil {
            Button("Reset Name") { model.setCustomName(agent.identityKey, "") }
        }
    }

    private var viewOptionsMenu: some View {
        Menu {
            Picker("Show", selection: $filterRaw) {
                ForEach(AgentFilter.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                }
            }
            Divider()
            Picker("Group by", selection: $groupingRaw) {
                ForEach(GroupBy.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option.rawValue)
                }
            }
        } label: {
            Label("View options", systemImage: filter == .all ? "slider.horizontal.3" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter and group agents")
    }

    // MARK: Grouped data

    private struct Group: Identifiable {
        var id: String
        var label: String
        var agents: [AgentEntry]
    }

    /// The container is already the section header, so its per-row badge is
    /// redundant then; both are shown only when agents span more than one.
    private var showDevice: Bool {
        grouping != .container && model.showsAgentDeviceBadge
    }

    private var showServer: Bool {
        model.showsAgentServerBadge
    }

    /// The project is the section header only when grouping by project; the
    /// other groupings don't show it otherwise, so put it on the row.
    private var showProject: Bool {
        grouping != .project
    }

    private func matches(_ haystack: String) -> Bool {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return true }
        let lower = haystack.lowercased()
        return terms.allSatisfy { lower.contains($0) }
    }

    private var matchedAgents: [AgentEntry] {
        model.agentEntries.filter { agent in
            filter.includes(agent.activity)
                && matches("\(agent.title) \(agent.kind.label) \(agent.configLabel) \(agent.space.path) \(agent.session) \(agent.device.name)")
        }
    }

    /// Sentinel id for the cross-cutting "Pinned" section at the very top.
    static let pinnedGroupID = "agentmux.pinned"

    private var groups: [Group] {
        // Pinned agents form a single section at the very top, across containers
        // (and out of their normal group), so the one or two you actively use are
        // always together and reachable regardless of their container's size.
        let pinned = matchedAgents.filter { model.isPinned($0.identityKey) }
        var labels: [String: String] = [:]
        var map: [String: [AgentEntry]] = [:]
        for agent in matchedAgents where !model.isPinned(agent.identityKey) {
            let k = grouping.key(agent)
            if map[k] == nil { labels[k] = grouping.label(agent) }
            map[k, default: []].append(agent)
        }
        var result = map.map { Group(id: $0.key, label: labels[$0.key] ?? $0.key, agents: sorted($0.value)) }
        if grouping == .status {
            result.sort { Self.statusRank($0.id) < Self.statusRank($1.id) }
        } else {
            // Order groups by their top agent, so the group holding the most
            // relevant agent (pinned / needs-attention / working / most-recent)
            // comes first — a brand-new agent floats its group to the top.
            result.sort { lhs, rhs in
                guard let a = lhs.agents.first, let b = rhs.agents.first else { return lhs.agents.count > rhs.agents.count }
                let ka = rank(a), kb = rank(b)
                return ka == kb ? lhs.label < rhs.label : ka < kb
            }
        }
        if !pinned.isEmpty {
            result.insert(Group(id: Self.pinnedGroupID, label: "Pinned", agents: sorted(pinned)), at: 0)
        }
        return result
    }

    /// Within a group: pinned first, then needs-attention, then working, then
    /// the rest — each tier most-recently-active first (unknown ages last).
    private func sorted(_ agents: [AgentEntry]) -> [AgentEntry] {
        agents.sorted { rank($0) < rank($1) }
    }

    /// Sort key: pinned, then activity (attention / working / other), then
    /// most-recently-active, then identityKey as a stable tiebreaker so equal
    /// keys (e.g. several agents sharing a last-active second) keep a fixed
    /// order instead of reshuffling on every refresh.
    private func rank(_ agent: AgentEntry) -> (Int, Int, Int, String) {
        (model.isPinned(agent.identityKey) ? 0 : 1, Self.activityRank(agent.activity), agent.lastActiveSeconds ?? .max, agent.identityKey)
    }

    static func activityRank(_ activity: AgentActivity) -> Int {
        if activity.needsAttention { return 0 }
        return activity == .working ? 1 : 2
    }

    nonisolated static func statusBucket(_ activity: AgentActivity) -> (id: String, label: String) {
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
        } else if !query.isEmpty {
            text = "No matches"
        } else if filter == .attention {
            text = "No agents need attention"
        } else if filter == .active {
            text = "No active agents"
        } else {
            text = "No agents found"
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

private struct RenameSheet: View {
    let current: String
    let placeholder: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Agent").font(.headline)
            TextField("Name", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = current }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

// MARK: - Rows

private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let entry: AgentEntry
    let showDevice: Bool
    let showServer: Bool
    let showProject: Bool

    var body: some View {
        HStack(spacing: 8) {
            agentIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                // No per-row pin glyph: pinned agents live under the "Pinned"
                // section header, so marking each row too is redundant.
                Text(model.customName(entry.identityKey) ?? entry.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.configLabel)
                    if showProject {
                        HStack(spacing: 3) {
                            Image(systemName: "folder").imageScale(.small).frame(width: 11)
                            Text(entry.spaceLabel)
                        }
                    }
                    if showServer {
                        HStack(spacing: 3) {
                            Image(systemName: "server.rack").imageScale(.small).frame(width: 11)
                            Text(entry.device.server)
                        }
                    }
                    if showDevice {
                        HStack(spacing: 3) {
                            Image(systemName: "shippingbox").imageScale(.small).frame(width: 11)
                            Text(entry.device.name)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Marks agents whose mirror is currently open in the app.
            if model.poppedOut.contains(entry.ref) {
                Image(systemName: "macwindow.on.rectangle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Open in its own window")
            } else if model.terminal(for: entry.ref) != nil {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 6, height: 6)
                    .help("Open")
            }
            // While working, the spinner already says "active now"; the time
            // would be redundant. A waiting auto-continue shows its ring.
            if let pending = model.pendingNudges[entry.ref] {
                NudgeRing(start: pending.start, fireAt: pending.fireAt)
            } else if entry.activity != .working, let active = RelativeTime.short(entry.lastActiveSeconds) {
                Text(active)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            AgentStatusGlyph(activity: entry.activity, fault: entry.fault, retrying: entry.isRetrying)
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
/// Comfortable hit area + hover highlight for a sidebar-footer icon button, so
/// two adjacent icons read as distinct buttons instead of cramped glyphs.
private struct StatusFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            // The fleet summary doubles as a shortcut to the dashboard.
            Button { model.selection = nil } label: {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .hoverBackground()
            }
            .buttonStyle(.plain)
            .help("Show the dashboard")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button { openWindow(id: "sessions") } label: {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 12.5))
                }
                .buttonStyle(.hover)
                .help("Manage tmux sessions")
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 12.5))
                }
                .buttonStyle(.hover)
                .help("Settings")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .statusStripChrome()
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
