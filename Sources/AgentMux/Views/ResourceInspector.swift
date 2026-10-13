import AgentMuxCore
import SwiftUI

/// Right-hand inspector: live CPU / memory / network / disk for the selected
/// agent's container and host (read-only `docker stats` + `/proc`), shown as
/// mole-style metric cards with rolling sparklines.
struct ResourceInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let ref = model.selection, let state = model.state(ref.targetID) {
                    let hostID = state.host.id
                    let host = model.resources[hostID]
                    if let name = state.target.container, let container = host?.containers[name] {
                        containerSection(container, cores: host?.cores ?? 0, hostID: hostID, name: name)
                    }
                    if let host {
                        hostSection(server: state.host.displayName.isEmpty ? state.host.sshDestination : state.host.displayName,
                                    host: host, hostID: hostID)
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading resources…").foregroundStyle(.secondary) }
                            .font(.caption)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "sidebar.right").font(.title3).foregroundStyle(.tertiary)
                        Text("Select an agent to see its container and host resources.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }

    // MARK: Container

    @ViewBuilder
    private func containerSection(_ container: ContainerResources, cores: Int, hostID: String, name: String) -> some View {
        sectionHeader(container.name, icon: "shippingbox.fill")
        MetricCard(icon: "cpu", title: "CPU",
                   chip: cores > 0 ? "of \(cores)" : nil, chipTint: Theme.textSecondary,
                   value: cores > 0 ? String(format: "%.1f", container.cpuPercent / 100) : "\(Int(container.cpuPercent.rounded()))",
                   unit: cores > 0 ? "cores" : "%",
                   history: model.history(hostID, "container.\(name).cpu"), tint: Theme.working)
        MetricCard(icon: "memorychip", title: "Memory",
                   chip: "\(Int(container.memPercent.rounded()))%", chipTint: Theme.meterColor(container.memPercent / 100),
                   value: container.memText,
                   caption: nil,
                   history: model.history(hostID, "container.\(name).mem"), tint: Theme.accent)
        StatGroup(rows: [
            ("network", "Net I/O", container.netText),
            ("externaldrive.badge.timemachine", "Block I/O", container.blockText),
            ("number", "Processes", "\(container.pids)"),
        ])
    }

    // MARK: Host

    @ViewBuilder
    private func hostSection(server: String, host: HostResources, hostID: String) -> some View {
        sectionHeader(server, icon: "server.rack")
        MetricCard(icon: "gauge.with.dots.needle.bottom.50percent", title: "Load (1m)",
                   chip: "\(host.cores) cores", chipTint: Theme.textSecondary,
                   value: String(format: "%.2f", host.load1),
                   caption: "avg \(fmt(host.load1)) · \(fmt(host.load5)) · \(fmt(host.load15))",
                   history: model.history(hostID, "host.cpu"), tint: Theme.working)
        MetricCard(icon: "memorychip", title: "Memory",
                   chip: "\(Int(host.memPercent.rounded()))%", chipTint: Theme.meterColor(host.memPercent / 100),
                   value: "\(host.memUsedMB / 1024)",
                   unit: "/ \(host.memTotalMB / 1024) GB",
                   history: model.history(hostID, "host.mem"), tint: Theme.accent)
        ForEach(host.gpus) { gpu in
            MetricCard(icon: "cpu.fill", title: "GPU \(gpu.index)",
                       chip: "\(Int(gpu.utilizationPercent.rounded()))%", chipTint: Theme.meterColor(gpu.utilizationPercent / 100),
                       value: "\(gpu.memUsedMB / 1024)",
                       unit: "/ \(gpu.memTotalMB / 1024) GB",
                       history: model.history(hostID, "gpu.\(gpu.index)"), tint: Theme.success)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// A compact card of plain label → value rows (for cumulative figures that have
/// no meaningful instantaneous rate to chart).
struct StatGroup: View {
    let rows: [(icon: String, title: String, value: String)]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Label(row.title, systemImage: row.icon).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }
}
