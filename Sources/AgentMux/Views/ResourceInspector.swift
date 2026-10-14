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
                    if let agent = model.agentResources(for: ref) {
                        agentSection(agent)
                    }
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

    /// The selected agent's own process, distinct from the container aggregate.
    /// CPU is `ps`'s lifetime average (no 0…1 meaning, so no bar); the workspace
    /// filesystem is a real fraction and gets one.
    @ViewBuilder
    private func agentSection(_ agent: AgentResources) -> some View {
        InspectorSection(title: "Agent", icon: "terminal.fill") {
            MetricRow(icon: "cpu", title: "CPU", value: String(format: "%.1f", agent.cpuPercent), unit: "% avg")
            MetricRow(icon: "memorychip", title: "Memory", value: memText(agent.rssKB))
            MetricRow(icon: "clock", title: "Uptime", value: uptimeText(agent.uptimeSeconds))
            if agent.hasDisk {
                MetricRow(icon: "internaldrive", title: "Workspace",
                          value: "\(Int(agent.diskPercent.rounded()))%", unit: gbPair(agent.diskUsedKB, agent.diskTotalKB, perMB: false),
                          fraction: agent.diskPercent / 100)
            }
        }
    }

    @ViewBuilder
    private func containerSection(_ container: ContainerResources, cores: Int) -> some View {
        InspectorSection(title: container.name, icon: "shippingbox.fill") {
            MetricRow(icon: "cpu", title: "CPU",
                      value: cores > 0 ? String(format: "%.1f", container.cpuPercent / 100) : "\(Int(container.cpuPercent.rounded()))",
                      unit: cores > 0 ? "/ \(cores) cores" : "%",
                      fraction: cores > 0 ? container.cpuPercent / Double(cores * 100) : container.cpuPercent / 100)
            MetricRow(icon: "memorychip", title: "Memory",
                      value: "\(Int(container.memPercent.rounded()))%", unit: compactPair(container.memText),
                      fraction: container.memPercent / 100)
            ioRow(icon: "network", title: "Net I/O", cumulative: container.netText, rate: container.netRateBytesPerSec)
            ioRow(icon: "externaldrive.badge.timemachine", title: "Block I/O", cumulative: container.blockText, rate: container.blockRateBytesPerSec)
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
            if host.swapTotalMB > 0 {
                MetricRow(icon: "memorychip.fill", title: "Swap",
                          value: "\(Int(host.swapPercent.rounded()))%", unit: gbPair(host.swapUsedMB, host.swapTotalMB, perMB: true),
                          fraction: host.swapPercent / 100)
            }
            ForEach(topDisks(host.disks)) { disk in
                MetricRow(icon: "internaldrive", title: "Disk \(disk.mount)",
                          value: "\(Int(disk.percent.rounded()))%", unit: gbPair(disk.usedKB, disk.totalKB, perMB: false),
                          fraction: disk.percent / 100)
            }
            ForEach(host.gpus) { gpu in
                MetricRow(icon: "cpu.fill", title: "GPU \(gpu.index)",
                          value: "\(Int(gpu.utilizationPercent.rounded()))%", unit: "\(gpu.memUsedMB / 1024) / \(gpu.memTotalMB / 1024) GB",
                          fraction: gpu.utilizationPercent / 100)
            }
            if host.uptimeSeconds > 0 {
                MetricRow(icon: "clock", title: "Uptime", value: uptimeText(host.uptimeSeconds))
            }
        }
    }

    /// Net / Block I/O: the live rate is the headline (so "busy or not" reads at
    /// a glance), with Docker's cumulative total as the secondary unit. Before
    /// the first delta the rate is unknown, so the cumulative stands alone.
    private func ioRow(icon: String, title: String, cumulative: String, rate: Double?) -> MetricRow {
        if let rate {
            return MetricRow(icon: icon, title: title, value: byteRate(rate), unit: "Σ \(compactPair(cumulative))")
        }
        return MetricRow(icon: icon, title: title, pair: compactPair(cumulative))
    }

    /// The largest few filesystems, so a crowded `df` stays legible.
    private func topDisks(_ disks: [DiskUsage]) -> [DiskUsage] {
        Array(disks.sorted { $0.totalKB > $1.totalKB }.prefix(3))
    }

    /// Drops the redundant unit from the numerator of a Docker "a UNIT / b UNIT"
    /// pair when both sides share it ("9.137GiB / 125.5GiB" → "9.137 / 125.5
    /// GiB"), matching how the host-side figures are written. Left unchanged
    /// when the two units differ.
    private func compactPair(_ pair: String) -> String {
        let halves = pair.components(separatedBy: " / ")
        guard halves.count == 2 else { return pair }
        func unit(of s: String) -> Substring { s[s.prefix { $0.isNumber || $0 == "." }.endIndex...] }
        let leftUnit = unit(of: halves[0])
        guard !leftUnit.isEmpty, leftUnit == unit(of: halves[1]) else { return pair }
        return "\(halves[0].dropLast(leftUnit.count)) / \(halves[1])"
    }

    private func memText(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// `used`/`total` are MB when `perMB`, else KB. Scales to TB past 1024 GB so
    /// the figure stays short enough not to truncate in the narrow inspector.
    private func gbPair(_ used: Int, _ total: Int, perMB: Bool) -> String {
        let toGB = perMB ? 1024.0 : 1024.0 * 1024.0
        let usedGB = Double(used) / toGB, totalGB = Double(total) / toGB
        if totalGB >= 1024 {
            return String(format: "%.1f / %.1f TB", usedGB / 1024, totalGB / 1024)
        }
        return String(format: "%.1f / %.1f GB", usedGB, totalGB)
    }

    private func byteRate(_ bytesPerSec: Double) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = max(0, bytesPerSec), i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        let num = (i == 0 || value >= 100) ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(num) \(units[i])/s"
    }

    private func uptimeText(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// A titled card holding a set of uniform metric rows.
private struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline.weight(.semibold)).frame(width: 18)
                Text(title).font(.subheadline.weight(.semibold))
            }
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
            // Inline while it fits (compact, like a normal readout); when the
            // unit would be clipped in the narrow inspector, drop it to its own
            // right-aligned line below the value instead of truncating it.
            if let unit {
                ViewThatFits(in: .horizontal) {
                    inlineRow(unit)
                    stackedRow(unit)
                }
            } else {
                inlineRow(nil)
            }
            if let fraction {
                ThinBar(fraction: fraction)
            }
        }
    }

    private var valueText: some View {
        Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(Theme.text)
            .contentTransition(.numericText())
    }

    private var label: some View {
        // A fixed-width icon column so every row's title starts at the same x —
        // SF Symbols have different intrinsic widths, which `Label` would leave
        // ragged.
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).frame(width: 15)
            Text(title).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func inlineRow(_ unit: String?) -> some View {
        HStack(spacing: 6) {
            label
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                valueText
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .animation(.easeOut(duration: 0.25), value: value)
        }
    }

    @ViewBuilder private func stackedRow(_ unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                label
                Spacer(minLength: 8)
                valueText.animation(.easeOut(duration: 0.25), value: value)
            }
            Text(unit).font(.caption).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
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
