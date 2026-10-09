import AgentMuxCore
import SwiftUI

/// Location, agent evidence and connection state for the selected pane.
struct PaneHeaderView: View {
    let ref: PaneRef
    let state: TargetState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: breadcrumb)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let pane = state.snapshot?.pane(ref.paneID) {
                Text(verbatim: pane.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let detection = state.detections[ref.paneID] {
                    AgentBadge(kind: detection.kind)
                    Text(verbatim: summary(detection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Text(verbatim: detection.evidence.joined(separator: "\n")))
                }
                Text("Activity: unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Working / waiting detection is not implemented yet.")
                Spacer()
                FreshnessView(state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var breadcrumb: String {
        var parts = [state.host.displayName]
        if let container = state.target.container { parts.append(container) }
        if let snapshot = state.snapshot,
           let row = snapshot.memberships.first(where: { $0.paneID == ref.paneID })
        {
            parts.append(snapshot.sessions.first { $0.id == row.sessionID }?.name ?? row.sessionID)
            parts.append("\(row.windowIndex): \(snapshot.windows.first { $0.id == row.windowID }?.name ?? row.windowID)")
        }
        parts.append(ref.paneID)
        return parts.joined(separator: " › ")
    }

    private func summary(_ detection: AgentDetection) -> String {
        var parts: [String] = []
        if let version = detection.version { parts.append(version) }
        if let directory = detection.configDirectory {
            // A configured directory, not a verified account.
            parts.append("config \(directory)")
        }
        if let pid = detection.pid { parts.append("pid \(pid)") }
        parts.append("\(detection.confidence.rawValue) confidence")
        if !detection.children.isEmpty {
            parts.append("\(detection.children.count) child agent(s)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown for a selected pane without an open terminal.
struct PanePlaceholderView: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        VStack(spacing: 12) {
            if let state = model.state(ref.targetID) {
                if state.target.access == .test {
                    Button("Open Terminal") {
                        model.openTerminal(ref)
                        model.terminal(for: ref)?.setActive(true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.snapshot?.pane(ref.paneID) == nil)
                    Text("Attaching makes this pane the current pane of its window (and its window the current window of the session) for every tmux client, including other terminals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                } else {
                    Text("Observe-only target").font(.headline)
                    Text("Attaching is disabled for this target in the current phase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalFooterView: View {
    @Environment(AppModel.self) private var model
    let terminal: TerminalController

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: phaseText)
                .font(.caption)
                .foregroundStyle(isLive ? Color.secondary : Color.red)
            Spacer()
            Button("Disconnect View") {
                model.closeTerminal(terminal.ref)
            }
            .help("Releases this app's tmux client. The pane and its programs keep running.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var isLive: Bool {
        terminal.phase == .connected || terminal.phase == .connecting
    }

    private var phaseText: String {
        switch terminal.phase {
        case .connecting: "Connecting…"
        case .connected: "Connected · input goes to this pane's window"
        case let .ended(reason): "Disconnected: \(reason) · input disabled"
        case let .stale(reason): "Stale: \(reason) · input disabled"
        }
    }
}
