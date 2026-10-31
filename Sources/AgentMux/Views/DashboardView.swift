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
                    MetricCard(icon: "checkmark.circle", title: "Done", value: "\(done.count)",
                               valueTint: done.isEmpty ? Theme.textTertiary : Theme.done, fillHeight: true)
                }
                containersSection
                if !accounts.isEmpty { AccountsSection(accounts: accounts) }
                if !actionableAgents.isEmpty {
                    AgentListSection(title: "Active", systemImage: "bolt.fill",
                                     agents: actionableAgents)
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { model.beginResourceMonitoring() }
        .onDisappear { model.endResourceMonitoring() }
    }

    // MARK: Derived

    private var agents: [AgentEntry] { model.allAgentEntries }
    private var working: [AgentEntry] { agents.filter { $0.activity == .working } }
    private var attention: [AgentEntry] { agents.filter { $0.activity.needsAttention } }
    private var done: [AgentEntry] { agents.filter(\.isDone) }
    private var serverCount: Int { Set(model.targets.map(\.host.id)).count }

    /// Urgency first (needs-attention, done, working), then most-recently active.
    private var sortedAgents: [AgentEntry] {
        agents.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let la = a.lastActiveSeconds ?? .max, lb = b.lastActiveSeconds ?? .max
            if la != lb { return la < lb }
            return a.identityKey < b.identityKey   // stable tiebreaker: no reshuffle on refresh
        }
    }

    private func rank(_ agent: AgentEntry) -> Int {
        agent.activity.needsAttention ? 0 : agent.isDone ? 1 : agent.activity == .working ? 2 : 3
    }

    /// The actionable subset for the overview: agents that need attention, are
    /// done or working. The full roster is the sidebar's job; re-listing every
    /// idle agent here only duplicated it.
    private var actionableAgents: [AgentEntry] {
        sortedAgents.filter { $0.activity.needsAttention || $0.isDone || $0.activity == .working }
    }

    /// Rate limits are per-account (one login, shared by every agent on it), not
    /// per-agent, so roll them up by account. The key includes the container
    /// because the same dir name on two containers is two different accounts.
    /// 5h/7d take the max across the account's agents — usage only climbs within
    /// a window, so the highest reading is the freshest.
    private var accounts: [AccountUsage] {
        var order: [String] = []
        var map: [String: AccountUsage] = [:]
        for agent in sortedAgents {
            // Merge by the real login when its id is readable; otherwise keep
            // per container + dir (same dir name on two containers stays split).
            let key = agent.accountKey ?? "\(agent.ref.targetID)|\(agent.kind)|\(agent.configLabel)"
            if map[key] == nil { order.append(key) }
            var acc = map[key] ?? AccountUsage(id: key, label: agent.configLabel,
                                               kind: agent.kind, containers: [],
                                               fiveHour: nil, sevenDay: nil,
                                               fiveHourResetsAt: nil, sevenDayResetsAt: nil,
                                               agentCount: 0, lastActiveSeconds: nil)
            let usage = model.usage(for: agent.ref)
            acc.agentCount += 1
            acc.containers.insert(agent.device.name)
            acc.fiveHour = maxOpt(acc.fiveHour, usage?.fiveHourPercent)
            acc.sevenDay = maxOpt(acc.sevenDay, usage?.sevenDayPercent)
            acc.fiveHourResetsAt = acc.fiveHourResetsAt ?? usage?.fiveHourResetsAt
            acc.sevenDayResetsAt = acc.sevenDayResetsAt ?? usage?.sevenDayResetsAt
            acc.lastActiveSeconds = minOpt(acc.lastActiveSeconds, agent.lastActiveSeconds)
            map[key] = acc
        }
        return order.compactMap { map[$0] }   // every in-use account, even without rate data
    }

    private func maxOpt(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, _): return b
        case (_, nil): return a
        case let (x?, y?): return Swift.max(x, y)
        }
    }

    private func minOpt(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, _): return b
        case (_, nil): return a
        case let (x?, y?): return Swift.min(x, y)
        }
    }

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
                SectionHeader(title: "Servers & containers", systemImage: "server.rack")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                    ForEach(model.targets) { state in
                        ContainerSummaryCard(state: state, agents: agents.filter { $0.ref.targetID == state.id })
                    }
                }
            }
        }
    }
}

/// A lightweight section header: a fixed-width icon box (so every section's
/// title starts at the same x and the icons line up down the page) plus a
/// smaller, less heavy title than the old bold headline.
private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
                .frame(width: 16, alignment: .center)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)   // icon + title share one balanced tone, not pale-icon/dark-text
    }
}

/// A titled list of agents; each row jumps to that agent when clicked.
private struct AgentListSection: View {
    let title: String
    let systemImage: String
    let agents: [AgentEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, systemImage: systemImage)
            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider() }
                    DashAgentRow(agent: agent)
                }
            }
            .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 10))
            .animation(Motion.list, value: agents.map(\.id))
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
                if let usage = model.usage(for: agent.ref) {
                    UsageBadges(usage: usage)
                }
                // One line, the time last in a fixed width: times and the
                // chips before them line up.
                StatusChip(activity: agent.activity, retrying: agent.isRetrying, done: agent.isDone)
                ActivityTime(entry: agent, fixedWidth: true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.row)
    }

    @ViewBuilder private var brandIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: agent.kind) {
            BrandIcon(resource: resource, size: 15)
        } else {
            Image(systemName: "terminal")
        }
    }
}

/// Compact context and (Codex) rate-limit usage as small coloured rings — fill
/// and colour, not numbers — so the one or two agents near a limit stand out
/// across the fleet without a wall of percentages. Exact values are in the help.
private struct UsageBadges: View {
    let usage: InventorySnapshot.AgentUsage

    var body: some View {
        // Text labels, not icons: two differently-shaped SF Symbols can't be
        // made to look the same size, but same-font labels always match and
        // say what each ring is. The ring (fill + colour) carries the value, so
        // there is no wall of percentages; the exact figure is in the tooltip.
        HStack(spacing: 9) {
            if let fraction = usage.contextUsedFraction {
                gauge("Ctx", fraction, help: "Context used: \(percent(fraction))")
            }
            if let h5 = usage.fiveHourPercent {
                gauge("5h", h5 / 100, help: "5-hour limit used: \(percent(h5 / 100))")
            }
            if let d7 = usage.sevenDayPercent {
                gauge("7d", d7 / 100, help: "Weekly limit used: \(percent(d7 / 100))")
            }
            if usage.fiveHourPercent == nil, usage.sevenDayPercent == nil, let rate = usage.rateLimitPercent {
                gauge("Rate", rate / 100, help: "Rate limit used: \(percent(rate / 100))")
            }
        }
    }

    private func gauge(_ label: String, _ fraction: Double, help: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            UsageRing(fraction: fraction)
        }
        .help(help)
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

/// A small progress ring: a faint track plus a colour-ramped arc from the top.
private struct UsageRing: View {
    let fraction: Double

    var body: some View {
        let f = min(1, max(0, fraction))
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2.5)
            Circle().trim(from: 0, to: f)
                .stroke(Theme.meterColor(f), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.3), value: f)
    }
}

/// A per-account usage rollup for the dashboard. Rate limits belong to the
/// account (login), not the individual agent, so every agent that shares a
/// (container + config dir) is merged into one entry.
private struct AccountUsage: Identifiable {
    let id: String
    let label: String
    let kind: AgentKind
    var containers: Set<String>
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourResetsAt: Int?
    var sevenDayResetsAt: Int?
    var agentCount: Int
    var lastActiveSeconds: Int?

    /// One container's name, or "N containers" when a login spans several.
    var containerText: String {
        containers.count == 1 ? (containers.first ?? "") : "\(containers.count) containers"
    }
}

/// Per-account rate-limit rollup, as a grid of compact cards: the 5-hour and
/// weekly windows every agent on a login shares, so an account near its cap
/// stands out without repeating the figures on each agent.
private struct AccountsSection: View {
    let accounts: [AccountUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Accounts", systemImage: "person.2.badge.key")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(accounts) { AccountCard(account: $0) }
            }
        }
    }
}

/// A compact account card: identity + agent count and last-active, then a short
/// 5-hour and weekly bar, each with its reset countdown.
private struct AccountCard: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                brandIcon.frame(width: 15)
                Text(account.label).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(account.containerText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .help(account.containers.sorted().joined(separator: ", "))
            }
            HStack(spacing: 5) {
                (Text("\(account.agentCount)").monospacedDigit()
                    + Text(account.agentCount == 1 ? " agent" : " agents"))
                if let active = RelativeTime.short(account.lastActiveSeconds) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(active).monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            LimitBar(label: "5h", percent: account.fiveHour, resetsAt: account.fiveHourResetsAt)
            LimitBar(label: "7d", percent: account.sevenDay, resetsAt: account.sevenDayResetsAt)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var brandIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: account.kind) {
            BrandIcon(resource: resource, size: 14)
        } else {
            Image(systemName: "person.crop.circle")
        }
    }
}

/// A short labelled usage bar: name, a colour-ramped fill, the percent, and a
/// reset countdown. An empty track (no words) when the window has no reading.
private struct LimitBar: View {
    let label: String
    let percent: Double?
    let resetsAt: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            Capsule().fill(Color.primary.opacity(0.08))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    if let percent {
                        GeometryReader { geo in
                            Capsule().fill(Theme.meterColor(min(1, max(0, percent / 100))))
                                .frame(width: geo.size.width * min(1, max(0, percent / 100)))
                        }
                    }
                }
            if let percent {
                Text("\(Int(percent.rounded()))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            if let reset = resetText {
                Text(reset).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
        }
        .help(helpText)
    }

    private var resetText: String? {
        guard let resetsAt else { return nil }
        let delta = resetsAt - Int(Date().timeIntervalSince1970)
        guard delta > 0 else { return nil }
        if delta < 3600 { return "\(max(1, delta / 60))m" }
        if delta < 86400 { return "\(delta / 3600)h" }
        return "\(delta / 86400)d"
    }

    private var helpText: String {
        guard let percent else { return "\(label): no reading yet" }
        var text = "\(label): \(Int(percent.rounded()))% used"
        if let reset = resetText { text += ", resets in \(reset)" }
        return text
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
            pill(count: agents.filter(\.isDone).count, color: Theme.done, label: "done")
            (Text("\(agents.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                + Text(" agent\(agents.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary))
                .rollingNumber(agents.count)
        }
    }

    @ViewBuilder private func pill(count: Int, color: Color, label: String) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .rollingNumber(count)
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
                    .rollingNumber(value)
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
