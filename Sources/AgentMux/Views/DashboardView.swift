import AgentMuxCore
import SwiftUI

/// Fleet overview shown when no agent is selected: KPI cards, per-container
/// resource cards with live sparklines, and the agents that need you or are
/// working. Selecting any row jumps straight to that agent. Read-only throughout.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(icon: "square.stack.3d.up", title: "Agents", value: "\(agents.count)", fillHeight: true)
                    MetricCard(icon: "circle.dotted", title: "Working", value: "\(working.count)",
                               valueTint: working.isEmpty ? Theme.textTertiary : Theme.working, fillHeight: true)
                    MetricCard(icon: "exclamationmark.circle.fill", title: "Needs attention", value: "\(attention.count)",
                               valueTint: attention.isEmpty ? Theme.textTertiary : Theme.warning, fillHeight: true)
                    MetricCard(icon: "checkmark.circle", title: "Idle", value: "\(idleCount)",
                               valueTint: idleCount == 0 ? Theme.textTertiary : Theme.success, fillHeight: true)
                }
                containersSection
                if !attention.isEmpty {
                    AgentListSection(title: "Needs attention", systemImage: "exclamationmark.circle.fill", tint: Theme.warning, agents: attention)
                }
                if !working.isEmpty {
                    AgentListSection(title: "Working now", systemImage: "circle.dotted", tint: Theme.working, agents: working)
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }

    // MARK: Derived

    private var agents: [AgentEntry] { model.allAgentEntries }
    private var working: [AgentEntry] { agents.filter { $0.activity == .working } }
    private var attention: [AgentEntry] { agents.filter { $0.activity.needsAttention } }
    private var idleCount: Int { agents.filter { $0.activity == .idle }.count }
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

    @ViewBuilder private var containersSection: some View {
        if !model.targets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Servers & containers", systemImage: "server.rack")
                    .font(.headline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                    ForEach(model.targets) { state in
                        ContainerSummaryCard(state: state, agents: agents.filter { $0.ref.targetID == state.id })
                    }
                }
            }
        }
    }
}

/// A titled list of agents; each row jumps to that agent when clicked.
private struct AgentListSection: View {
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
                brandIcon.frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.customName(agent.identityKey) ?? agent.title).lineLimit(1)
                    Text("\(agent.configLabel) · \(agent.device.name) · \(agent.spaceLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if agent.activity != .working, let active = RelativeTime.short(agent.lastActiveSeconds) {
                    Text(active).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                StatusChip(activity: agent.activity)
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

/// A container card: name + status breakdown, then live CPU and memory
/// mini-metrics with sparklines.
private struct ContainerSummaryCard: View {
    @Environment(AppModel.self) private var model
    let state: TargetState
    let agents: [AgentEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if let resources = model.resources[state.host.id],
               let name = state.target.container, let container = resources.containers[name] {
                HStack(alignment: .top, spacing: 16) {
                    InlineMetric(title: "CPU",
                                 value: resources.cores > 0 ? String(format: "%.1f", container.cpuPercent / 100) : "\(Int(container.cpuPercent.rounded()))",
                                 unit: resources.cores > 0 ? "/ \(resources.cores) cores" : "%",
                                 history: model.history(state.host.id, "container.\(name).cpu"), tint: Theme.working)
                    InlineMetric(title: "Memory",
                                 value: "\(Int(container.memPercent.rounded()))", unit: "% · \(container.memText)",
                                 history: model.history(state.host.id, "container.\(name).mem"), tint: Theme.accent)
                }
            } else if state.isOnline {
                Text("Resources loading…").font(.caption2).foregroundStyle(.tertiary)
            }
            if let failure = state.lastFailure, state.snapshot == nil {
                Label(failure.kind.rawValue, systemImage: "wifi.slash").font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusPills: some View {
        HStack(spacing: 8) {
            pill(count: agents.filter { $0.activity == .working }.count, color: Theme.working, label: "working")
            pill(count: agents.filter { $0.activity.needsAttention }.count, color: Theme.warning, label: "attention")
            Text("\(agents.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                + Text(" agent\(agents.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
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

/// A borderless metric (title, big value + unit, sparkline) for use inside a card.
private struct InlineMetric: View {
    let title: String
    let value: String
    var unit: String?
    var history: [Double]
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            if history.count >= 2 {
                Sparkline(values: history, tint: tint).frame(height: 22)
            } else {
                Color.clear.frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
