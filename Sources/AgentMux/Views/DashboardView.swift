import AgentMuxCore
import SwiftUI

/// Overview shown in the detail pane when no agent is selected: fleet totals,
/// the agents that need you, who's working, and a per-container resource card.
/// Selecting any row jumps straight to that agent. Read-only throughout.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summary
                if !attention.isEmpty {
                    AgentListSection(title: "Needs attention", systemImage: "exclamationmark.circle.fill", tint: Theme.warning, agents: attention)
                }
                if !working.isEmpty {
                    AgentListSection(title: "Working now", systemImage: "circle.dotted", tint: Theme.working, agents: working)
                }
                containersSection
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }

    // MARK: Derived

    private var agents: [AgentEntry] { model.allAgentEntries }
    private var working: [AgentEntry] { agents.filter { $0.activity == .working } }
    private var attention: [AgentEntry] { agents.filter { $0.activity.needsAttention } }
    private var serverCount: Int { Set(model.targets.map(\.host.id)).count }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fleet").font(.largeTitle.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.targets.contains(where: { $0.lastFailure != nil }) {
                Label("Some targets offline", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var subtitle: String {
        let servers = serverCount
        let containers = model.targets.count
        return "\(servers) server\(servers == 1 ? "" : "s") · \(containers) container\(containers == 1 ? "" : "s") · \(agents.count) agent\(agents.count == 1 ? "" : "s")"
    }

    private var summary: some View {
        HStack(spacing: 12) {
            SummaryCard(icon: "circle.dotted", value: working.count, label: "Working", tint: Theme.working)
            SummaryCard(icon: "exclamationmark.circle.fill", value: attention.count, label: "Need attention", tint: Theme.warning)
            SummaryCard(icon: "checkmark.circle", value: idleCount, label: "Idle", tint: Theme.success)
        }
    }

    private var idleCount: Int { agents.filter { $0.activity == .idle }.count }

    @ViewBuilder private var containersSection: some View {
        if !model.targets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Servers & containers", systemImage: "server.rack")
                    .font(.headline).foregroundStyle(.secondary)
                ForEach(model.targets) { state in
                    ContainerSummaryCard(state: state, agents: agents.filter { $0.ref.targetID == state.id })
                }
            }
        }
    }
}

/// One big number with an icon and caption.
private struct SummaryCard: View {
    let icon: String
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text("\(value)").font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A titled list of agents; each row jumps to that agent when clicked.
private struct AgentListSection: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    let tint: Color
    let agents: [AgentEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline).foregroundStyle(tint)
            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider() }
                    DashAgentRow(agent: agent)
                }
            }
            .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct DashAgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentEntry

    var body: some View {
        Button { model.select(agent.ref) } label: {
            HStack(spacing: 8) {
                brandIcon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.customName(agent.identityKey) ?? agent.title).lineLimit(1)
                    Text("\(agent.configLabel) · \(agent.device.name) · \(agent.spaceLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if agent.activity != .working, let active = RelativeTime.short(agent.lastActiveSeconds) {
                    Text(active).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                AgentStatusGlyph(activity: agent.activity)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var brandIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: agent.kind) {
            BrandIcon(resource: resource, size: 15)
        } else {
            Image(systemName: "terminal")
        }
    }
}

/// A container with its agent status breakdown and (when available) live CPU /
/// memory meters.
private struct ContainerSummaryCard: View {
    @Environment(AppModel.self) private var model
    let state: TargetState
    let agents: [AgentEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                Text(state.device.name).font(.headline)
                HStack(spacing: 3) {
                    Image(systemName: "server.rack").imageScale(.small)
                    Text(state.device.server)
                }.font(.caption).foregroundStyle(.tertiary)
                Spacer()
                statusPills
            }
            if let resources = model.resources[state.host.id] {
                if let container = resources.containers[state.target.container ?? ""] {
                    StatMeter(icon: "cpu", title: "CPU",
                              value: resources.cores > 0 ? "\(String(format: "%.1f", container.cpuPercent / 100)) / \(resources.cores) cores" : "\(Int(container.cpuPercent.rounded()))%",
                              fraction: resources.cores > 0 ? container.cpuPercent / Double(resources.cores * 100) : nil)
                    StatMeter(icon: "memorychip", title: "Memory",
                              value: "\(Int(container.memPercent.rounded()))% · \(container.memText)",
                              fraction: container.memPercent / 100)
                }
            } else if state.isOnline {
                Text("Resources loading…").font(.caption2).foregroundStyle(.tertiary)
            }
            if let failure = state.lastFailure, state.snapshot == nil {
                Label(failure.kind.rawValue, systemImage: "wifi.slash").font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(14)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusPills: some View {
        HStack(spacing: 10) {
            pill(count: agents.filter { $0.activity == .working }.count, color: Theme.working, label: "working")
            pill(count: agents.filter { $0.activity.needsAttention }.count, color: Theme.warning, label: "attention")
            Text("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func pill(count: Int, color: Color, label: String) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .help("\(count) \(label)")
        }
    }
}
