import AgentMuxCore
import SwiftUI

/// Right-hand inspector: live CPU / memory / network / disk for the selected
/// agent's container and host (read-only `docker stats` + `/proc`).
struct ResourceInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let ref = model.selection, let state = model.state(ref.targetID) {
                    let host = model.resources[state.host.id]
                    if let container = host?.containers[state.target.container ?? ""] {
                        ContainerCard(container: container, cores: host?.cores ?? 0)
                    }
                    if let host {
                        HostCard(server: state.host.displayName.isEmpty ? state.host.sshDestination : state.host.displayName, host: host)
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading resources…").foregroundStyle(.secondary) }
                    }
                } else {
                    Text("Select an agent to see its container and host resources.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }
}

private struct ContainerCard: View {
    let container: ContainerResources
    let cores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(container.name, systemImage: "shippingbox.fill").font(.headline)
            StatMeter(icon: "cpu", title: "CPU", value: cpuValue,
                      fraction: cores > 0 ? container.cpuPercent / Double(cores * 100) : nil)
            StatMeter(icon: "memorychip", title: "Memory", value: "\(Int(container.memPercent.rounded()))% · \(container.memText)",
                      fraction: container.memPercent / 100)
            StatLine(icon: "network", title: "Net I/O", value: container.netText)
            StatLine(icon: "externaldrive.badge.timemachine", title: "Block I/O", value: container.blockText)
            StatLine(icon: "number", title: "Processes", value: "\(container.pids)")
        }
    }

    private var cpuValue: String {
        cores > 0 ? "\(String(format: "%.1f", container.cpuPercent / 100)) / \(cores) cores" : "\(Int(container.cpuPercent.rounded()))%"
    }
}

private struct HostCard: View {
    let server: String
    let host: HostResources

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(server, systemImage: "server.rack").font(.headline)
            StatMeter(icon: "gauge.with.dots.needle.bottom.50percent", title: "Load (1m)",
                      value: "\(String(format: "%.2f", host.load1)) · \(host.cores) cores",
                      fraction: host.cores > 0 ? host.load1 / Double(host.cores) : nil)
            StatMeter(icon: "memorychip", title: "Memory",
                      value: "\(Int(host.memPercent.rounded()))% · \(host.memUsedMB / 1024)/\(host.memTotalMB / 1024) GB",
                      fraction: host.memPercent / 100)
            Text("Load avg \(fmt(host.load1)) / \(fmt(host.load5)) / \(fmt(host.load15))")
                .font(.caption2).foregroundStyle(.tertiary)
            ForEach(host.gpus) { gpu in
                StatMeter(icon: "cpu.fill", title: "GPU \(gpu.index)",
                          value: "\(Int(gpu.utilizationPercent.rounded()))% · \(gpu.memUsedMB / 1024)/\(gpu.memTotalMB / 1024) GB",
                          fraction: gpu.utilizationPercent / 100)
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// A labelled bar with a value, used for CPU / memory / load / GPU.
struct StatMeter: View {
    let icon: String
    let title: String
    let value: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(color(fraction))
            }
        }
    }

    private func color(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

private struct StatLine: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
