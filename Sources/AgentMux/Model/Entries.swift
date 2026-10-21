import AgentMuxCore
import Foundation

/// A configured target as the sidebar shows it ("device" in a Mac agent console's terms).
struct DeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var subtitle: String
    /// The SSH host this device is on (display name).
    var server: String
    var osID: String?
}

/// A working directory on one target. Agents are grouped by it.
struct SpaceKey: Hashable {
    var targetID: String
    var path: String
}

struct SpaceEntry: Identifiable, Hashable {
    var key: SpaceKey
    var label: String
    var device: DeviceInfo
    var agentCount: Int
    var attention: AgentActivity?
    var id: SpaceKey { key }
}

/// A pane running a detected agent.
struct AgentEntry: Identifiable, Hashable {
    var ref: PaneRef
    var title: String
    var kind: AgentKind
    var activity: AgentActivity
    var space: SpaceKey
    var spaceLabel: String
    var device: DeviceInfo
    var location: String
    /// The agent's tmux session name (for grouping).
    var session: String
    /// The agent's tmux window id (e.g. "@27") in its real session. Unique per
    /// agent, so it anchors the identity key; session/path do not, because two
    /// same-kind agents can share them.
    var windowID: String
    /// Seconds since the agent last wrote its session log (nil if unknown).
    var lastActiveSeconds: Int?
    /// CLAUDE_CONFIG_DIR / CODEX_HOME for this agent, if set (else the default).
    var configDir: String?
    /// The agent CLI version (e.g. "0.159.3"), when detected.
    var version: String?
    /// The model id the agent is currently using (e.g. "claude-opus-5-5"),
    /// detected from the session log; nil when unknown.
    var model: String?
    /// The reasoning effort ("medium"/"high"/"xhigh"), when known.
    var effort: String?
    /// Non-secret account identity for dedup ("claude:<uuid>" / "codex:<id>"),
    /// when a readable account id exists; nil falls back to container + dir.
    var accountKey: String?
    var id: PaneRef { ref }

    /// The config dir shown in place of the generic kind label, e.g.
    /// ".claude-2" or ".codex" — identifies which account an agent uses.
    var configLabel: String {
        if let dir = configDir, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        switch kind {
        case .claudeCode: return ".claude"
        case .codex: return ".codex"
        default: return kind.label
        }
    }

    /// The model prettified for display, with effort when known ("Opus 5.5 ·
    /// medium", "GPT-6 Astra · xhigh"); nil when the model is unknown.
    var modelLabel: String? {
        guard let model, !model.isEmpty else { return nil }
        let base = AgentModelName.pretty(model)
        if let effort, !effort.isEmpty { return "\(base) · \(effort)" }
        return base
    }

    /// A stable identity for user labels (pin / rename): the container, the
    /// tmux window, and the agent kind. The window id is what makes it unique —
    /// two agents of the same kind can share a session name AND working
    /// directory (e.g. two Codex panes both in a "demo" session under
    /// /srv/app/demo), which made the old session+path key collide so
    /// that pinning or renaming one hit both. It also survives pane-id changes
    /// and the agent cd-ing elsewhere (unlike the mutable current path).
    var identityKey: String {
        let anchor = windowID.isEmpty ? "\(session)|\(space.path)" : windowID
        return "\(space.targetID)|\(anchor)|\(kind)"
    }
}

/// The chips the bottom status bar can show, in display order. Version defaults
/// off (it is always available in the hover tooltip); the rest default on.
enum StatusBarField: String, CaseIterable, Sendable {
    case model, account, version, server, container, folder, usage

    var label: String {
        switch self {
        case .account: return "Account"
        case .model: return "Model"
        case .version: return "Version"
        case .server: return "Server"
        case .container: return "Container"
        case .folder: return "Folder"
        case .usage: return "Usage"
        }
    }

    static var defaultVisible: Set<StatusBarField> {
        [.account, .model, .server, .container, .folder, .usage]
    }
}

/// Prettifies a raw model id for the status bar ("claude-opus-5-5" -> "Opus
/// 5.5", "gpt-6-astra" -> "GPT-6 Astra"). Unknown shapes pass through unchanged.
enum AgentModelName {
    static func pretty(_ id: String) -> String {
        let s = id.lowercased()
        if s.hasPrefix("claude-") {
            let parts = s.dropFirst("claude-".count).split(separator: "-").map(String.init)
            let families = ["opus", "sonnet", "haiku"]
            guard let family = parts.first(where: { families.contains($0) }) else { return id }
            let version = parts.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
        }
        if s.hasPrefix("gpt") {
            let rest = s.dropFirst(3).drop(while: { $0 == "-" })
            let parts = rest.split(separator: "-").map(String.init)
            guard let version = parts.first else { return "GPT" }
            let codename = parts.dropFirst().map { $0.capitalized }.joined(separator: " ")
            return codename.isEmpty ? "GPT-\(version)" : "GPT-\(version) \(codename)"
        }
        return id
    }
}

/// Any other pane: shells, file managers, experiments.
struct PaneEntry: Identifiable, Hashable {
    var ref: PaneRef
    var title: String
    var command: String
    var space: SpaceKey
    var spaceLabel: String
    var device: DeviceInfo
    var location: String
    var id: PaneRef { ref }
}

extension TargetState {
    var device: DeviceInfo {
        var name = target.displayName ?? target.container ?? host.displayName
        if target.displayName == nil, target.access == .test { name += " · test" }
        var parts = [host.sshDestination]
        if let container = target.container { parts.append(container) }
        switch target.tmuxSocket.mode {
        case .default: break
        case .name: parts.append("-L \(target.tmuxSocket.value ?? "")")
        case .path: parts.append("-S \(target.tmuxSocket.value ?? "")")
        }
        let server = host.displayName.isEmpty ? host.sshDestination : host.displayName
        return DeviceInfo(id: target.id, name: name, subtitle: parts.joined(separator: " · "), server: server, osID: snapshot?.osID)
    }

    var isOnline: Bool { lastSuccess != nil && lastFailure == nil }
}

enum SpaceLabel {
    static func label(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

extension AppModel {
    var devices: [DeviceInfo] { targets.map(\.device) }

    private var scopedTargets: [TargetState] {
        targets.filter { deviceFilter == nil || $0.id == deviceFilter }
    }

    /// Agents in the current device / space scope, in tmux order so rows do
    /// not jump around when state changes.
    var agentEntries: [AgentEntry] {
        allAgentEntries.filter { spaceFilter == nil || $0.space == spaceFilter }
    }

    var allAgentEntries: [AgentEntry] {
        scopedTargets.flatMap { state -> [AgentEntry] in
            guard let snapshot = state.snapshot else { return [] }
            let device = state.device
            return snapshot.panes.compactMap { pane in
                guard let detection = state.detections[pane.id],
                      detection.kind == .codex || detection.kind == .claudeCode,
                      snapshot.hasRealSession(pane.id),
                      let ref = state.ref(for: pane.id) else { return nil }
                let window = windowName(of: pane.id, in: snapshot)
                let title = AgentTitle.from(paneTitle: pane.title, kind: detection.kind)
                    ?? window.flatMap { $0 == detection.kind.label ? nil : $0 }
                    ?? SpaceLabel.label(pane.currentPath)
                let activity = state.activities[pane.id] ?? .unknown
                return AgentEntry(
                    ref: ref,
                    title: title,
                    kind: detection.kind,
                    activity: activity,
                    space: SpaceKey(targetID: state.id, path: pane.currentPath),
                    spaceLabel: SpaceLabel.label(pane.currentPath),
                    device: device,
                    location: location(of: pane.id, in: snapshot),
                    session: sessionName(of: pane.id, in: snapshot),
                    windowID: snapshot.primaryMembership(of: pane.id)?.windowID ?? "",
                    lastActiveSeconds: snapshot.lastActiveSeconds[pane.id],
                    configDir: detection.configDirectory,
                    version: detection.version,
                    model: snapshot.models[pane.id],
                    effort: snapshot.efforts[pane.id],
                    accountKey: snapshot.accounts[pane.id]
                )
            }
        }
    }

    var paneEntries: [PaneEntry] {
        scopedTargets.flatMap { state -> [PaneEntry] in
            guard let snapshot = state.snapshot else { return [] }
            let device = state.device
            return snapshot.panes.compactMap { pane in
                if let kind = state.detections[pane.id]?.kind, kind == .codex || kind == .claudeCode { return nil }
                guard snapshot.hasRealSession(pane.id), let ref = state.ref(for: pane.id) else { return nil }
                return PaneEntry(
                    ref: ref,
                    title: windowName(of: pane.id, in: snapshot) ?? pane.currentCommand,
                    command: pane.currentCommand,
                    space: SpaceKey(targetID: state.id, path: pane.currentPath),
                    spaceLabel: SpaceLabel.label(pane.currentPath),
                    device: device,
                    location: location(of: pane.id, in: snapshot)
                )
            }
        }
        .filter { spaceFilter == nil || $0.space == spaceFilter }
    }

    var spaceEntries: [SpaceEntry] {
        var order: [SpaceKey] = []
        var grouped: [SpaceKey: [AgentEntry]] = [:]
        for entry in allAgentEntries {
            if grouped[entry.space] == nil { order.append(entry.space) }
            grouped[entry.space, default: []].append(entry)
        }
        return order.map { key in
            let entries = grouped[key] ?? []
            return SpaceEntry(
                key: key,
                label: SpaceLabel.label(key.path),
                device: entries[0].device,
                agentCount: entries.count,
                attention: Self.strongest(entries.map(\.activity))
            )
        }
    }

    var scopeAgentCount: Int { allAgentEntries.count }

    /// The device name is shown on a row only when that kind of row actually
    /// spans more than one device; otherwise it is noise on every row.
    var showsAgentDeviceBadge: Bool {
        deviceFilter == nil && Set(allAgentEntries.map(\.device.name)).count > 1
    }

    /// Show the server on a row only when agents span more than one server.
    var showsAgentServerBadge: Bool {
        deviceFilter == nil && Set(allAgentEntries.map(\.device.server)).count > 1
    }

    var showsPaneDeviceBadge: Bool {
        deviceFilter == nil && Set(paneEntries.map(\.device.name)).count > 1
    }

    func agentEntry(_ ref: PaneRef) -> AgentEntry? {
        allAgentEntries.first { $0.ref == ref }
    }

    func paneEntry(_ ref: PaneRef) -> PaneEntry? {
        paneEntries.first { $0.ref == ref }
    }

    private func windowName(of paneID: String, in snapshot: InventorySnapshot) -> String? {
        guard let row = snapshot.memberships.first(where: { $0.paneID == paneID }) else { return nil }
        return snapshot.windows.first { $0.id == row.windowID }?.name
    }

    private func sessionName(of paneID: String, in snapshot: InventorySnapshot) -> String {
        guard let row = snapshot.primaryMembership(of: paneID) else { return "" }
        return snapshot.sessions.first { $0.id == row.sessionID }?.name ?? row.sessionID
    }

    static func strongest(_ activities: [AgentActivity]) -> AgentActivity? {
        if activities.contains(where: \.needsAttention) { return .waitingInput }
        if activities.contains(.working) { return .working }
        return nil
    }
}
