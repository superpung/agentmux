import AgentMuxCore
import SwiftUI

/// Right-hand inspector: live CPU / memory / network / disk for the selected
/// agent's container and host (read-only `docker stats` + `/proc`). A uniform,
/// precise readout — every metric is the same weight and its value rolls on
/// update, so the cumulative figures read as live as the percentages. Trends
/// live on the dashboard, not here.
struct ResourceInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let ref = model.selection, let state = model.state(ref.targetID) {
                    let host = model.resources[state.host.id]
                    if let name = state.target.container, let container = host?.containers[name] {
                        containerSection(container, cores: host?.cores ?? 0)
                    }
                    if let host {
                        hostSection(server: state.host.displayName.isEmpty ? state.host.sshDestination : state.host.displayName, host: host)
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

    @ViewBuilder
    private func containerSection(_ container: ContainerResources, cores: Int) -> some View {
        InspectorSection(title: container.name, icon: "shippingbox.fill") {
            MetricRow(icon: "cpu", title: "CPU",
                      value: cores > 0 ? String(format: "%.1f", container.cpuPercent / 100) : "\(Int(container.cpuPercent.rounded()))",
                      unit: cores > 0 ? "/ \(cores) cores" : "%",
                      fraction: cores > 0 ? container.cpuPercent / Double(cores * 100) : container.cpuPercent / 100)
            MetricRow(icon: "memorychip", title: "Memory",
                      value: "\(Int(container.memPercent.rounded()))%", unit: container.memText,
                      fraction: container.memPercent / 100)
            MetricRow(icon: "network", title: "Net I/O", pair: container.netText)
            MetricRow(icon: "externaldrive.badge.timemachine", title: "Block I/O", pair: container.blockText)
            MetricRow(icon: "number", title: "Processes", value: "\(container.pids)")
        }
    }

    @ViewBuilder
    private func hostSection(server: String, host: HostResources) -> some View {
        InspectorSection(title: server, icon: "server.rack") {
            MetricRow(icon: "gauge.with.dots.needle.bottom.50percent", title: "Load (1m)",
                      value: String(format: "%.2f", host.load1), unit: "/ \(host.cores) cores",
                      fraction: host.cores > 0 ? host.load1 / Double(host.cores) : nil)
            MetricRow(icon: "chart.bar.xaxis", title: "Load avg",
                      value: String(format: "%.2f", host.load5), unit: String(format: "· %.2f", host.load15))
            MetricRow(icon: "memorychip", title: "Memory",
                      value: "\(Int(host.memPercent.rounded()))%", unit: "\(host.memUsedMB / 1024) / \(host.memTotalMB / 1024) GB",
                      fraction: host.memPercent / 100)
            ForEach(host.gpus) { gpu in
                MetricRow(icon: "cpu.fill", title: "GPU \(gpu.index)",
                          value: "\(Int(gpu.utilizationPercent.rounded()))%", unit: "\(gpu.memUsedMB / 1024) / \(gpu.memTotalMB / 1024) GB",
                          fraction: gpu.utilizationPercent / 100)
            }
        }
    }
}

/// A titled card holding a set of uniform metric rows.
private struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 11) { content }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// One live metric: label on the left, a bold value (+ secondary unit) on the
/// right that rolls when it changes, and a thin bar only when a 0…1 fraction is
/// meaningful. Same weight for every metric, cumulative or not.
struct MetricRow: View {
    let icon: String
    let title: String
    let value: String
    var unit: String?
    var fraction: Double?

    /// Convenience for a Docker "a / b" string: first part is the value, the
    /// rest is the secondary unit.
    init(icon: String, title: String, pair: String) {
        self.icon = icon
        self.title = title
        if let slash = pair.range(of: " / ") {
            value = String(pair[..<slash.lowerBound])
            unit = "/ " + pair[slash.upperBound...]
        } else {
            value = pair
            unit = nil
        }
        fraction = nil
    }

    init(icon: String, title: String, value: String, unit: String? = nil, fraction: Double? = nil) {
        self.icon = icon
        self.title = title
        self.value = value
        self.unit = unit
        self.fraction = fraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: value)
            }
            if let fraction {
                ThinBar(fraction: fraction)
            }
        }
    }
}

/// A 3pt capacity bar coloured by the shared usage ramp.
struct ThinBar: View {
    let fraction: Double

    var body: some View {
        let f = min(1, max(0, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.meterColor(f)).frame(width: geo.size.width * f)
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.25), value: f)
    }
}
