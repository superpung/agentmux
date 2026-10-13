import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackgroundColor
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.selection != nil { ContextBar() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.selection != nil { StatusBar() }
        }
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

/// A slim identity strip under the toolbar: the old subtitle, but with the same
/// brand / server / container / folder icons the sidebar uses.
private struct ContextBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.selection {
            HStack(spacing: 12) {
                if let agent = model.agentEntry(ref) {
                    chip(brandIcon(agent.kind), agent.configLabel)
                    chip(icon("server.rack"), agent.device.server)
                    chip(icon("shippingbox"), agent.device.name)
                    chip(icon("folder"), agent.space.path)
                } else if let pane = model.paneEntry(ref) {
                    chip(icon("terminal"), pane.command)
                    chip(icon("shippingbox"), pane.device.name)
                    chip(icon("folder"), pane.space.path)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func chip(_ icon: some View, _ text: String) -> some View {
        HStack(spacing: 4) {
            icon
            Text(text).truncationMode(.middle)
        }
        .layoutPriority(1)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).imageScale(.small).foregroundStyle(.tertiary)
    }

    @ViewBuilder private func brandIcon(_ kind: AgentKind) -> some View {
        if let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 12)
        } else {
            icon("terminal")
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
        if let ref = model.selection, let state = model.state(ref.targetID), let content = content(ref, state) {
            HStack(spacing: 10) {
                if let problem = content.problem {
                    Circle().fill(problem.color).frame(width: 7, height: 7)
                    Text(problem.text)
                }
                Spacer(minLength: 8)
                if let usage = content.usage {
                    UsageView(usage: usage)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .help(content.tooltip)
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

/// Mostly-graphical usage readout: a context meter and (Codex) a rate-limit
/// meter, each a bar + percent. Claude's log records neither the window nor a
/// rate limit, so it shows the absolute context size instead.
private struct UsageView: View {
    let usage: InventorySnapshot.AgentUsage

    var body: some View {
        HStack(spacing: 14) {
            if let fraction = usage.contextFraction {
                Meter(systemImage: "square.stack.3d.up.fill", fraction: fraction,
                      tooltip: "Context: \(short(usage.contextTokens)) / \(short(usage.contextWindow)) tokens")
            } else if let context = usage.contextTokens {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill").imageScale(.medium).foregroundStyle(.secondary)
                    Text(Self.short(context))
                }
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                .help("Context: \(context) tokens (the model's window is not in the log)")
            }
            if let rate = usage.rateLimitPercent {
                Meter(systemImage: "hourglass", fraction: rate / 100, tooltip: "Rate limit used: \(rate)%")
            }
        }
    }

    private func short(_ n: Int?) -> String { n.map(Self.short) ?? "?" }

    static func short(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// An icon, a bar, and a trailing percentage.
private struct Meter: View {
    let systemImage: String
    let fraction: Double
    let tooltip: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.medium).foregroundStyle(.secondary)
            Capsule().fill(.quaternary)
                .frame(width: 56, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: 56 * max(0, min(1, fraction)), height: 6)
                }
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(tooltip)
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

private struct PoppedInfoView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Open in a separate window").font(.headline)
            Text("Close that window to bring this agent back here.")
                .font(.caption).foregroundStyle(.secondary)
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
                    Text("This target is configured as observe-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("Add an SSH host in Settings to discover its containers.")
                    .font(.caption).foregroundStyle(.secondary)
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
