// Titlebar strip adapted from a Mac agent console's DetailView
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var sidebarCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ZStack {
                Theme.terminalBackground
                // Every open terminal stays mounted so its screen survives
                // switching; only the selected one is visible and live.
                ForEach(Array(model.terminals.values), id: \.ref) { terminal in
                    let selected = terminal.ref == model.selection
                    TerminalSurfaceView(context: terminal.state)
                        .padding(.leading, 6)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                }
                if let ref = model.selection {
                    if model.terminal(for: ref) == nil {
                        PanePlaceholderView(ref: ref)
                    }
                } else {
                    EmptyStateView()
                }
            }
            StatusBarView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
    }

    // MARK: Titlebar strip

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", help: "Show Sidebar (⌘B)") {
                    sidebarCollapsed = false
                }
            }
            Group {
                if let ref = model.selection, let agent = model.agentEntry(ref) {
                    AgentStatusGlyph(activity: agent.activity)
                    Text(verbatim: agent.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    AgentKindBadge(kind: agent.kind)
                    dot
                    Text(verbatim: agent.spaceLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    DeviceChip(device: agent.device)
                    ActivityPill(activity: agent.activity)
                } else if let ref = model.selection, let pane = model.paneEntry(ref) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: pane.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    Text(verbatim: pane.spaceLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    DeviceChip(device: pane.device)
                } else {
                    Text("No terminal selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
        .windowTitlebarInteraction()
    }

    private var dot: some View {
        Text("·")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textGhost)
    }
}

/// One line at the bottom: connection, freshness, and how the agent was
/// identified.
private struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                if let ref = model.selection, let state = model.state(ref.targetID) {
                    Circle()
                        .fill(state.lastFailure != nil ? Theme.danger : state.isOnline ? Theme.success : Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(verbatim: connectionText(state, now: context.date))
                    if let detection = state.detections[ref.paneID], detection.kind != .none {
                        Text(verbatim: evidenceText(detection))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(Text(verbatim: detection.evidence.joined(separator: "\n")))
                    }
                    Spacer(minLength: 8)
                    if let terminal = model.terminal(for: ref) {
                        Text(verbatim: terminal.phaseText)
                        Button("Disconnect View") { model.closeTerminal(ref) }
                            .buttonStyle(.link)
                            .help("Releases this app's tmux client. The pane and its programs keep running.")
                    }
                } else {
                    Spacer()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Theme.contentBackground)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private func connectionText(_ state: TargetState, now: Date) -> String {
        let verified = state.lastSuccess.map { "verified \(Self.ago($0, now: now))" } ?? "connecting"
        if let failure = state.lastFailure {
            return "\(failure.kind.rawValue) · last \(verified)"
        }
        return "online · \(verified)"
    }

    private func evidenceText(_ detection: AgentDetection) -> String {
        var parts = ["\(detection.kind.label) \(detection.version ?? "")".trimmingCharacters(in: .whitespaces)]
        if let directory = detection.configDirectory { parts.append("config \(directory)") }
        parts.append("\(detection.confidence.rawValue) confidence")
        if !detection.children.isEmpty { parts.append("\(detection.children.count) child agent(s)") }
        return parts.joined(separator: " · ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }
}

/// Shown for a selected pane without an open terminal.
private struct PanePlaceholderView: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        VStack(spacing: 12) {
            if let state = model.state(ref.targetID) {
                if state.target.access.allowsAttach {
                    Button("Open Terminal") {
                        model.openTerminal(ref)
                        model.terminal(for: ref)?.setActive(true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(state.snapshot?.pane(ref.paneID) == nil)
                    Text("Attaching makes this pane the current pane of its window (and its window the current window of the session) for every tmux client.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                } else {
                    Text("View only").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Text("This target is configured as observe-only.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.configError {
                Text("No target configuration").font(.headline)
                Text(verbatim: model.configPath ?? "").font(.caption).textSelection(.enabled)
                Text(verbatim: error).font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Text("Select an agent").foregroundStyle(Theme.textTertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
