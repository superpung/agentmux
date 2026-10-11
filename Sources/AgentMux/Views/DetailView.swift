import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackgroundColor
            // Every open terminal stays mounted so its screen survives
            // switching; only the selected one is visible and live.
            ForEach(Array(model.terminals.values), id: \.ref) { terminal in
                MirroredSurfaceView(terminal: terminal)
                    .opacity(terminal.ref == model.selection ? 1 : 0)
                    .allowsHitTesting(terminal.ref == model.selection)
            }
            if let ref = model.selection {
                if model.terminal(for: ref) == nil {
                    PanePlaceholderView(ref: ref)
                }
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if model.selection != nil { StatusBar() }
        }
    }

    private var title: String {
        guard let ref = model.selection else { return "AgentMux" }
        if let agent = model.agentEntry(ref) { return agent.title }
        if let pane = model.paneEntry(ref) { return pane.title }
        return "AgentMux"
    }

    private var subtitle: String {
        guard let ref = model.selection else { return "" }
        if let agent = model.agentEntry(ref) {
            return "\(agent.kind.label) · \(agent.space.path)"
        }
        if let pane = model.paneEntry(ref) {
            return pane.space.path
        }
        return ""
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let ref = model.selection, let agent = model.agentEntry(ref), agent.activity != .unknown {
            ToolbarItem(placement: .navigation) {
                ActivityPill(activity: agent.activity)
            }
        }
        if let ref = model.selection, let terminal = model.terminal(for: ref) {
            ToolbarItemGroup {
                Button {
                    terminal.resync()
                } label: {
                    Label("Redraw", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Rebuild this view from the pane's current screen")
                Button {
                    model.closeTerminal(ref)
                } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle")
                }
                .help("Ends this view's tmux client. The pane keeps running.")
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

/// Connection, freshness and detection evidence for the selected pane.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                if let ref = model.selection, let state = model.state(ref.targetID) {
                    Circle()
                        .fill(state.lastFailure != nil ? .red : state.isOnline ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(connectionText(state, now: context.date))
                    if let detection = state.detections[ref.paneID], detection.kind != .none {
                        Text("·").foregroundStyle(.tertiary)
                        Text(evidenceText(detection))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(detection.evidence.joined(separator: "\n"))
                    }
                    Spacer(minLength: 8)
                    if let terminal = model.terminal(for: ref) {
                        if let geometry = terminal.geometry {
                            Text("\(geometry.columns)×\(geometry.rows)")
                        }
                        Text(terminal.phaseText).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func connectionText(_ state: TargetState, now: Date) -> String {
        let verified = state.lastSuccess.map { "updated \(Self.ago($0, now: now))" } ?? "connecting"
        if let failure = state.lastFailure {
            return "\(failure.kind.rawValue) · last \(verified)"
        }
        return "online · \(verified)"
    }

    private func evidenceText(_ detection: AgentDetection) -> String {
        var parts = ["\(detection.kind.label) \(detection.version ?? "")".trimmingCharacters(in: .whitespaces)]
        if let directory = detection.configDirectory { parts.append(directory) }
        parts.append("\(detection.confidence.rawValue) confidence")
        return parts.joined(separator: " · ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
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
            if model.hosts.isEmpty {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No hosts yet").font(.headline)
                Text("Add an SSH host in Settings to discover its containers.")
                    .font(.caption).foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
                    .padding(.top, 2)
            } else if let error = model.configError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Could not save settings").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
