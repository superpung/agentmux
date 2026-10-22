import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var pendingSwitch: PendingSwitch?
    @State private var switchError: String?

    /// A requested account switch awaiting confirmation (it stops and relaunches
    /// the agent, so it is confirmed first).
    private struct PendingSwitch: Identifiable {
        let ref: PaneRef
        let account: String
        var id: String { account }
        var label: String { (account as NSString).lastPathComponent }
    }

    /// The terminal palette, so the letterbox margins behind it match; the
    /// dashboard / empty state just follows the system.
    private var backgroundTheme: TerminalThemePreference {
        if let ref = model.selection, model.terminal(for: ref) != nil {
            return model.terminalTheme
        }
        return .system
    }

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackground(for: backgroundTheme)
            // Every open terminal stays mounted so its screen survives
            // switching; only the selected one is visible and live. A mirror
            // shown in its own window is not rendered here, so its single
            // surface never lives in two hierarchies.
            ForEach(Array(model.terminals.values), id: \.ref) { terminal in
                if !model.poppedOut.contains(terminal.ref) {
                    MirroredSurfaceView(terminal: terminal)
                        .opacity(terminal.ref == model.selection ? 1 : 0)
                        .allowsHitTesting(terminal.ref == model.selection)
                }
            }
            if let ref = model.selection {
                if model.poppedOut.contains(ref) {
                    PoppedInfoView()
                } else if model.terminal(for: ref) == nil {
                    PanePlaceholderView(ref: ref)
                }
            } else if model.configError != nil || model.hosts.isEmpty {
                EmptyStateView()
            } else {
                DashboardView()
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.selection)
        .navigationTitle(title)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.selection != nil { StatusBar() }
        }
        .alert(
            pendingSwitch.map { "Switch to \($0.label)?" } ?? "",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { pending in
            Button("Switch", role: .destructive) { performSwitch(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("The running Claude will be stopped and relaunched under \(pending.label), resuming this conversation. Any in-progress turn is lost.")
        }
        .alert(
            "Couldn't switch account",
            isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: { Text(switchError ?? "") }
    }

    private func performSwitch(_ pending: PendingSwitch) {
        let ref = pending.ref
        let account = pending.account
        Task { if let error = await model.switchAccount(ref, to: account) { switchError = error } }
    }

    private var title: String {
        guard let ref = model.selection else { return "AgentMux" }
        if let agent = model.agentEntry(ref) { return agent.title }
        if let pane = model.paneEntry(ref) { return pane.title }
        return "AgentMux"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let ref = model.selection, let agent = model.agentEntry(ref), agent.activity != .unknown {
            ToolbarItem(placement: .navigation) {
                StatusChip(activity: agent.activity, showsIdle: true)
            }
        }
        if let ref = model.selection, let terminal = model.terminal(for: ref) {
            ToolbarItem {
                Menu {
                    if !model.poppedOut.contains(ref) {
                        Button {
                            model.popOut(ref)
                            openWindow(value: ref)
                        } label: {
                            Label("Open in New Window", systemImage: "macwindow.on.rectangle")
                        }
                    }
                    Button {
                        terminal.resync()
                    } label: {
                        Label("Redraw", systemImage: "arrow.triangle.2.circlepath")
                    }
                    let switchable = model.switchableAccounts(for: ref)
                    if !switchable.isEmpty {
                        Menu {
                            ForEach(switchable, id: \.self) { account in
                                Button((account as NSString).lastPathComponent) {
                                    pendingSwitch = PendingSwitch(ref: ref, account: account)
                                }
                            }
                        } label: {
                            Label("Switch Account", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(model.agentEntry(ref)?.activity == .working)
                    }
                    Divider()
                    Button {
                        model.closeTerminal(ref)
                        model.selection = nil
                    } label: {
                        Label("Close View", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("Open in a new window, redraw, or close this view")
            }
        }
    }
}

/// The Ghostty surface filling the detail pane. The terminal scales its font
/// so the whole remote grid fits, so the surface is never larger than this
/// area (a Metal layer ignores SwiftUI clipping, so it must not overflow).
private struct MirroredSurfaceView: View {
    let terminal: PaneTerminal

    var body: some View {
        // The surface fills the detail pane at a fixed font; its grid size
        // drives the remote window size (see PaneTerminal), so the pane
        // reflows to fill the view like a normal terminal.
        TerminalSurfaceView(context: terminal.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Minimal footer for the selected pane: token usage when known, and a problem
/// indicator only when something is wrong. Detection details and freshness are
/// kept in the tooltip rather than on screen.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.selection {
            let state = model.state(ref.targetID)
            let content = state.flatMap { content(ref, $0) }
            HStack(spacing: 10) {
                metadata(ref)
                Spacer(minLength: 8)
                if let problem = content?.problem {
                    Circle().fill(problem.color).frame(width: 7, height: 7)
                    Text(problem.text).lineLimit(1).layoutPriority(1)
                }
                if model.showsStatusField(.usage), let usage = content?.usage {
                    UsageView(usage: usage).layoutPriority(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .statusStripChrome()
            .help(content?.tooltip ?? "")
        }
    }

    /// The agent's identity (was its own bar above the terminal, now folded in
    /// here): account, server, container and working directory.
    @ViewBuilder private func metadata(_ ref: PaneRef) -> some View {
        HStack(spacing: 10) {
            if let agent = model.agentEntry(ref) {
                if model.showsStatusField(.model), let label = agent.modelLabel { chip(brandIcon(agent.kind), label) }
                if model.showsStatusField(.account) { chip(icon("person.crop.circle"), agent.configLabel) }
                if model.showsStatusField(.version), let version = agent.version { chip(icon("tag"), version) }
                if model.showsStatusField(.server) { chip(icon("server.rack"), agent.device.server) }
                if model.showsStatusField(.container) { chip(icon("shippingbox"), agent.device.name) }
                if model.showsStatusField(.folder) { chip(icon("folder"), agent.space.path) }
            } else if let pane = model.paneEntry(ref) {
                chip(icon("terminal"), pane.command)
                chip(icon("shippingbox"), pane.device.name)
                chip(icon("folder"), pane.space.path)
            }
        }
    }

    // A fixed icon box keeps the differently-shaped SF Symbols the same size.
    private func chip(_ icon: some View, _ text: String) -> some View {
        HStack(spacing: 4) {
            icon.frame(width: 15, height: 12)
            Text(text).truncationMode(.middle)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    @ViewBuilder private func brandIcon(_ kind: AgentKind) -> some View {
        if let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 12)
        } else {
            icon("terminal")
        }
    }

    private struct Problem { var color: Color; var text: String }
    private struct Content { var problem: Problem?; var usage: InventorySnapshot.AgentUsage?; var tooltip: String }

    /// Returns nil when there is nothing worth showing (healthy, no usage).
    private func content(_ ref: PaneRef, _ state: TargetState) -> Content? {
        let problem: Problem?
        if state.lastFailure != nil, state.snapshot == nil {
            problem = Problem(color: .red, text: "offline · \(state.lastFailure!.kind.rawValue)")
        } else if state.lastFailure != nil {
            problem = Problem(color: .orange, text: "stale")
        } else if let terminal = model.terminal(for: ref), terminal.isTrouble {
            problem = Problem(color: .orange, text: terminal.phaseText)
        } else {
            problem = nil
        }
        let usage = state.snapshot?.usage[ref.paneID]?.withInferredWindow()
        guard problem != nil || usage != nil else { return nil }
        return Content(problem: problem, usage: usage, tooltip: tooltip(ref, state))
    }

    /// The detail that used to crowd the bar, now hover-only.
    private func tooltip(_ ref: PaneRef, _ state: TargetState) -> String {
        var lines: [String] = []
        if let detection = state.detections[ref.paneID], detection.kind != .none {
            var parts = ["\(detection.kind.label) \(detection.version ?? "")".trimmingCharacters(in: .whitespaces)]
            if let directory = detection.configDirectory { parts.append(directory) }
            parts.append("\(detection.confidence.rawValue) confidence")
            lines.append(parts.joined(separator: " · "))
        }
        if let success = state.lastSuccess {
            lines.append("updated \(Int(max(0, Date().timeIntervalSince(success))))s ago")
        }
        if let terminal = model.terminal(for: ref), let geometry = terminal.geometry {
            lines.append("\(geometry.columns)×\(geometry.rows) · \(terminal.phaseText)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Mostly-graphical usage readout: a labelled bar + percent for context fill
/// and, when the status line reports them, the 5-hour and 7-day (weekly) limit
/// windows. When only an absolute context size is known (no window / percent),
/// it shows that number instead.
private struct UsageView: View {
    let usage: InventorySnapshot.AgentUsage

    var body: some View {
        HStack(spacing: 12) {
            if let fraction = usage.contextUsedFraction {
                Meter(label: "ctx", fraction: fraction, tooltip: contextTooltip)
            } else if let context = usage.contextTokens {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill").imageScale(.medium).foregroundStyle(.secondary)
                    Text(Self.short(context)).rollingNumber(context)
                }
                .font(.footnote).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .help("Context: \(context) tokens (the model's window is not in the log)")
            }
            if let h5 = usage.fiveHourPercent {
                Meter(label: "5h", fraction: h5 / 100, tooltip: "5-hour limit used: \(Int(h5.rounded()))%", resetsAt: usage.fiveHourResetsAt)
            }
            if let d7 = usage.sevenDayPercent {
                Meter(label: "7d", fraction: d7 / 100, tooltip: "Weekly (7-day) limit used: \(Int(d7.rounded()))%", resetsAt: usage.sevenDayResetsAt)
            }
            if usage.fiveHourPercent == nil, usage.sevenDayPercent == nil, let rate = usage.rateLimitPercent {
                Meter(label: "rate", fraction: rate / 100, tooltip: "Rate limit used: \(Int(rate.rounded()))%")
            }
        }
    }

    private var contextTooltip: String {
        if let t = usage.contextTokens, let w = usage.contextWindow {
            return "Context: \(Self.short(t)) / \(Self.short(w)) tokens"
        }
        if let p = usage.contextPercent { return "Context used: \(Int(p.rounded()))%" }
        return "Context"
    }

    static func short(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// A short text label, a bar, and a trailing percentage.
private struct Meter: View {
    let label: String
    let fraction: Double
    let tooltip: String
    var resetsAt: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Capsule().fill(.quaternary)
                .frame(width: 44, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: 44 * max(0, min(1, fraction)), height: 6)
                }
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.footnote).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .rollingNumber(Int((fraction * 100).rounded()))
            if let reset = Self.resetText(resetsAt) {
                Text(reset).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .help(Self.resetText(resetsAt).map { "\(tooltip) · resets in \($0)" } ?? tooltip)
    }

    /// Compact time until the limit resets ("2d5h", "3h12m", "45m"); nil if
    /// unknown or already past.
    static func resetText(_ resetsAt: Int?) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt - Int(Date().timeIntervalSince1970)
        guard remaining > 0 else { return nil }
        let d = remaining / 86400, h = (remaining % 86400) / 3600, m = (remaining % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    private var color: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// Shown in its own window; renders the same single mirror surface, which the
/// main detail pane releases while this window is open.
struct PoppedTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackgroundColor
            if let terminal = model.terminal(for: ref) {
                MirroredSurfaceView(terminal: terminal)
            } else {
                Text("This agent is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.agentEntry(ref)?.title ?? "Agent")
        .onAppear { model.terminal(for: ref)?.setActive(true) }
        .onDisappear { model.returnFromWindow(ref) }
    }
}

/// A throwaway shell window (a direct pty, not in tmux). Closing it ends the
/// shell and its ssh connection, leaving nothing behind on the remote.
struct EphemeralTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let spec: EphemeralTerminalSpec

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackgroundColor
            if let terminal = model.ephemeralTerminal(for: spec) {
                EphemeralSurfaceView(terminal: terminal)
            } else {
                Text("Could not open a terminal here.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Terminal: \(spec.label)")
        .onAppear { model.ephemeralTerminal(for: spec)?.setActive(true) }
        .onDisappear { model.closeEphemeral(spec.id) }
    }
}

private struct EphemeralSurfaceView: View {
    let terminal: EphemeralTerminal

    var body: some View {
        TerminalSurfaceView(context: terminal.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PoppedInfoView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Open in a separate window").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PanePlaceholderView: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        VStack(spacing: 10) {
            if let state = model.state(ref.targetID) {
                if state.target.access.allowsAttach {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "eye")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("View only")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.configError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Settings problem").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                SettingsLink { Text("Open Settings…") }
                    .padding(.top, 2)
            } else if model.hosts.isEmpty {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No hosts yet").font(.headline)
                SettingsLink { Text("Open Settings…") }
                    .padding(.top, 2)
            } else {
                Image(systemName: "terminal")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select an agent").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
