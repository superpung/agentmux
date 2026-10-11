import AgentMuxCore
import Foundation

/// A configured target as the sidebar shows it ("device" in a Mac agent console's terms).
struct DeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var subtitle: String
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
    var id: PaneRef { ref }
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
        return DeviceInfo(id: target.id, name: name, subtitle: parts.joined(separator: " · "), osID: snapshot?.osID)
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
                      let ref = state.ref(for: pane.id) else { return nil }
                let window = windowName(of: pane.id, in: snapshot)
                let title = AgentTitle.from(paneTitle: pane.title, kind: detection.kind)
                    ?? window.flatMap { $0 == detection.kind.label ? nil : $0 }
                    ?? SpaceLabel.label(pane.currentPath)
                let evidence = detection.pid.flatMap { snapshot.agents[$0] }
                let activity = ActivityDetector.resolve(
                    kind: detection.kind,
                    logEvent: evidence?.logEvent,
                    logAgeSeconds: evidence?.logAgeSeconds,
                    screenState: snapshot.screenStates[pane.id],
                    logState: snapshot.logStates[pane.id]
                ).activity
                return AgentEntry(
                    ref: ref,
                    title: title,
                    kind: detection.kind,
                    activity: activity,
                    space: SpaceKey(targetID: state.id, path: pane.currentPath),
                    spaceLabel: SpaceLabel.label(pane.currentPath),
                    device: device,
                    location: location(of: pane.id, in: snapshot)
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
                guard let ref = state.ref(for: pane.id) else { return nil }
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

    static func strongest(_ activities: [AgentActivity]) -> AgentActivity? {
        if activities.contains(where: \.needsAttention) { return .waitingInput }
        if activities.contains(.working) { return .working }
        return nil
    }
}
