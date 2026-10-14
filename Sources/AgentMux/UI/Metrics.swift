import AgentMuxCore
import Charts
import SwiftUI

/// A compact, labelled status pill (e.g. "Working", "Needs input"). Renders
/// nothing for `.unknown` so a guess is never shown. The colour is the shared
/// semantic ramp; the label carries the meaning so hue is only a reinforcement.
struct StatusChip: View {
    let activity: AgentActivity
    var compact = false
    /// In a list, idle on every row is noise, so it's hidden by default. A
    /// single focal status (e.g. the detail titlebar) can opt in to show it.
    var showsIdle = false

    var body: some View {
        // Only working / needs-input / needs-approval / exited earn a chip in a
        // list; idle is shown only where `showsIdle` is set.
        if (showsIdle || activity != .idle), let label = Theme.activityLabel(activity) {
            let tint = Theme.activityColor(activity)
            HStack(spacing: 4) {
                if activity == .working {
                    SpinnerView(color: tint).frame(width: 8, height: 8)
                } else {
                    Circle().fill(tint).frame(width: 6, height: 6)
                }
                if !compact {
                    Text(label).font(.caption2.weight(.medium)).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .help(label)
        }
    }
}

/// A tiny axis-less line+area chart for a rolling metric history.
struct Sparkline: View {
    let values: [Double]
    /// Fixed upper bound for the Y domain (e.g. 100 for a percentage). When nil
    /// the chart auto-scales to the data with a little headroom.
    var ceiling: Double?
    var tint: Color = Theme.accent

    var body: some View {
        let hi = max(ceiling ?? ((values.max() ?? 1) * 1.15), 0.0001)
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0 ... hi)
        .chartLegend(.hidden)
        .allowsHitTesting(false)
        // Morph the line/area to the new sample instead of snapping each poll.
        .animation(.easeInOut(duration: 0.4), value: values)
    }
}

/// A mole-style metric card: icon + title (with an optional trailing chip), a
/// big value with a small unit, an optional sparkline (preferred) or bar, and a
/// muted caption. Used for dashboard KPIs, container cards and the inspector.
struct MetricCard: View {
    let icon: String
    let title: String
    var chip: String?
    var chipTint: Color = Theme.textSecondary
    let value: String
    var unit: String?
    var valueTint: Color = Theme.text
    var caption: String?
    /// Rolling history → sparkline. Takes precedence over `fraction`.
    var history: [Double]?
    /// Fixed Y ceiling for the sparkline (e.g. 100 for a percentage).
    var ceiling: Double?
    /// 0…1 fill for a bar when there is no history.
    var fraction: Double?
    var tint: Color = Theme.accent
    /// Stretch to the tallest sibling in a grid row (keeps a KPI row even).
    var fillHeight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let chip {
                    Text(chip)
                        .font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(chipTint)
                        .rollingNumber(chip)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(chipTint.opacity(0.12), in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit().foregroundStyle(valueTint)
                    .rollingNumber(value)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            chart
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var chart: some View {
        if let history, history.count >= 2 {
            Sparkline(values: history, ceiling: ceiling, tint: tint).frame(height: 26)
        } else if let fraction {
            ProgressView(value: min(1, max(0, fraction)))
                .tint(Theme.meterColor(fraction))
        }
    }
}
