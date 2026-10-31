import AppKit
import AgentMuxCore
import SwiftUI

/// The always-on menu-bar item. Its glyph reflects the most urgent state, with
/// a count; the popover lists the agents that need you, are done or working,
/// and clicking one brings AgentMux forward on that agent.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let agents = model.allAgentEntries
        let attention = agents.filter { $0.activity.needsAttention }.count
        let done = agents.filter(\.isDone).count
        let working = agents.filter { $0.activity == .working }.count
        HStack(spacing: 3) {
            if attention > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                Text("\(attention)")
            } else if done > 0 {
                Image(systemName: "checkmark.circle.fill")
                Text("\(done)")
            } else if working > 0 {
                Image(systemName: "bolt.fill")
                Text("\(working)")
            } else {
                Image(systemName: "terminal")
            }
        }
    }
}

struct MenuBarContent: View {
    let model: AppModel

    private var agents: [AgentEntry] { model.allAgentEntries }
    private var attention: [AgentEntry] { agents.filter { $0.activity.needsAttention } }
    private var working: [AgentEntry] { agents.filter { $0.activity == .working } }
    /// Most recently finished first.
    private var done: [AgentEntry] {
        agents.filter(\.isDone).sorted { ($0.lastActiveSeconds ?? .max) < ($1.lastActiveSeconds ?? .max) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AgentMux").font(.headline)
                Spacer()
                Text(countsText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
            fleetSummary
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if agents.isEmpty {
                        Text(model.hosts.isEmpty ? "No hosts configured." : "No agents found.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(14)
                    }
                    section("Needs attention", attention)
                    section("Done", done) {
                        Button("Clear") { model.markAllDoneSeen() }
                            .buttonStyle(.hover)
                            .font(.caption2)
                    }
                    section("Working", working)
                }
                .animation(Motion.list, value: (attention + done + working).map(\.id))
            }
            .frame(maxHeight: 300)

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }

    private var countsText: String {
        "\(working.count) working · \(attention.count) need you · \(done.count) done"
    }

    // A condensed fleet dashboard: KPI counts + per-container live meters.
    private var fleetSummary: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                kpi("Working", working.count, working.isEmpty ? Theme.textTertiary : Theme.working)
                kpi("Attention", attention.count, attention.isEmpty ? Theme.textTertiary : Theme.warning)
                kpi("Done", done.count, done.isEmpty ? Theme.textTertiary : Theme.done)
            }
            ForEach(model.targets) { state in containerLine(state) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func kpi(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit().foregroundStyle(tint)
                .rollingNumber(value)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func containerLine(_ state: TargetState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").imageScale(.small).foregroundStyle(.tertiary)
            Text(state.device.name).font(.caption).lineLimit(1)
            Spacer(minLength: 6)
            if let resources = model.resources[state.host.id],
               let name = state.target.container, let container = resources.containers[name] {
                miniMeter("CPU", resources.cores > 0 ? container.cpuPercent / Double(resources.cores * 100) : container.cpuPercent / 100)
                miniMeter("MEM", container.memPercent / 100)
            } else if state.isOnline {
                Text("…").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func miniMeter(_ label: String, _ fraction: Double) -> some View {
        let f = min(1, max(0, fraction))
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).fixedSize()
            ProgressView(value: f).frame(width: 30).tint(Theme.meterColor(f))
            Text("\(Int((f * 100).rounded()))%").font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                .rollingNumber(Int((f * 100).rounded()))
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [AgentEntry],
                                      @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        if !list.isEmpty {
            HStack {
                Text(title.uppercased())
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            ForEach(list) { agent in
                Button { jump(to: agent.ref) } label: {
                    HStack(spacing: 8) {
                        brandIcon(agent.kind).frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.customName(agent.identityKey) ?? agent.title).lineLimit(1)
                            Text(agent.device.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        // One line, the time last in a fixed width: times and the
                        // chips before them line up.
                        StatusChip(activity: agent.activity, retrying: agent.isRetrying, done: agent.isDone)
                        ActivityTime(entry: agent, fixedWidth: true)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.row)
                .padding(.horizontal, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open AgentMux") { activate() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.hover)
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 5)
    }

    @ViewBuilder private func brandIcon(_ kind: AgentKind) -> some View {
        if let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 14)
        } else {
            Image(systemName: "terminal")
        }
    }

    private func jump(to ref: PaneRef) {
        activate()
        model.select(ref)
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain && window.title != "Sessions" {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
