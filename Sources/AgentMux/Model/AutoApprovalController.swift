import AgentMuxCore
import Foundation
import Observation

@MainActor @Observable
final class AutoApprovalController {
    struct Entry: Equatable {
        let id = UUID()
        var countdown: ApprovalCountdown
        var awaitingFirstProbe = false
        var approving = false
        var needsManualApproval = false
        var message: String?
    }

    /// The user's opt-in belongs to one process in one target generation.
    /// The pane and tmux server identity are the dictionary key.
    private struct OptIn: Codable, Equatable {
        let destination: String
        let containerID: String?
        let containerStartedAt: String?
        let socketPath: String
        let kind: String
        let agent: AgentApproval.Agent
    }

    private static let preferencesKey = "autoApprovalOptIns"
    @ObservationIgnored private var saved: [PaneRef: OptIn] = {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else { return [:] }
        return (try? JSONDecoder().decode([PaneRef: OptIn].self, from: data)) ?? [:]
    }() {
        didSet {
            guard saved != oldValue, let data = try? JSONEncoder().encode(saved) else { return }
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        }
    }

    private(set) var entries: [PaneRef: Entry] = [:]
    @ObservationIgnored private var tasks: [PaneRef: Task<Void, Never>] = [:]
    var enabledRefs: Set<PaneRef> { Set(entries.keys) }

    func canEnable(_ ref: PaneRef, model: AppModel) -> Bool {
        guard let state = model.state(ref.targetID) else { return false }
        return currentOptIn(for: ref, in: state) != nil
    }

    private func currentOptIn(for ref: PaneRef, in state: TargetState) -> OptIn? {
        guard state.lastFailure == nil, state.snapshotDestination == state.host.sshDestination,
              let snapshot = state.snapshot, snapshot.failure == nil, snapshot.processTableAvailable,
              let server = snapshot.server, snapshot.hasRealSession(ref.paneID),
              state.target.kind != .docker || snapshot.container != nil,
              state.target.access.allowsAttach, state.ref(for: ref.paneID) == ref,
              let d = state.detections[ref.paneID], d.kind.supportsApproval,
              let pid = d.pid, pid > 0, let ticks = d.startTicks, ticks > 0 else { return nil }
        return OptIn(destination: state.host.sshDestination, containerID: snapshot.container?.id,
                     containerStartedAt: snapshot.container?.startedAt, socketPath: server.socketPath,
                     kind: d.kind.rawValue, agent: .init(pid: pid, startTicks: ticks))
    }

    func setEnabled(_ enabled: Bool, for ref: PaneRef, model: AppModel) {
        guard enabled else { forget(ref); return }
        guard let state = model.state(ref.targetID), let optIn = currentOptIn(for: ref, in: state) else { return }
        tasks.removeValue(forKey: ref)?.cancel()
        saved[ref] = optIn
        entries[ref] = Entry(countdown: ApprovalCountdown(agent: optIn.agent))
        state.refreshRequested = true
    }

    private func forget(_ ref: PaneRef) {
        tasks.removeValue(forKey: ref)?.cancel()
        entries[ref] = nil
        saved[ref] = nil
    }

    func forgetTarget(_ targetID: String) {
        for ref in Array(saved.keys) where ref.targetID == targetID { forget(ref) }
    }

    func cancel(_ ref: PaneRef, source: String = "button") {
        guard var entry = entries[ref], !entry.approving, entry.countdown.pending != nil else { return }
        tasks.removeValue(forKey: ref)?.cancel()
        entry.countdown.cancel()
        entry.message = source == "button" ? "Cancelled for this request" : "Cancelled after terminal input"
        entry.needsManualApproval = true
        entries[ref] = entry
        CommandLog.log("auto", ref.targetID, "pane=\(ref.paneID) cancelled-by=\(source)")
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        entries.removeAll()
    }

    func pause(_ targetID: String) {
        for ref in entries.keys.filter({ $0.targetID == targetID }) {
            guard var entry = entries[ref], !entry.approving else { continue }
            tasks.removeValue(forKey: ref)?.cancel()
            entry.countdown.observe(nil, now: Date())
            entry.message = "Waiting for a fresh connection"
            entries[ref] = entry
        }
    }

    func reconcile(_ state: TargetState, probedAgents: [String: AgentApproval.Agent], model: AppModel) {
        guard let snapshot = state.snapshot, snapshot.failure == nil, snapshot.processTableAvailable,
              state.target.kind != .docker || snapshot.container != nil else {
            pause(state.id)
            return
        }
        for ref in Array(saved.keys) where ref.targetID == state.id {
            guard let optIn = saved[ref], currentOptIn(for: ref, in: state) == optIn else {
                forget(ref)
                continue
            }
            guard var entry = entries[ref] else {
                entries[ref] = Entry(countdown: ApprovalCountdown(agent: optIn.agent), awaitingFirstProbe: true)
                state.refreshRequested = true
                continue
            }
            guard !entry.approving else { continue }
            let request = snapshot.approvals[ref.paneID]
            if entry.awaitingFirstProbe {
                guard probedAgents[ref.paneID] == optIn.agent else { continue }
                // Restoring the switch does not consent to an approval already on screen.
                entry.awaitingFirstProbe = false
                entry.countdown.observe(request, now: Date())
                entry.needsManualApproval = entry.countdown.pending != nil
                entry.countdown.cancel()
                entries[ref] = entry
                continue
            }
            let old = entry.countdown
            entry.countdown.observe(request, now: Date())
            guard old != entry.countdown else {
                if request == nil && entry.needsManualApproval {
                    entry.needsManualApproval = false
                    entry.message = nil
                    entries[ref] = entry
                }
                continue
            }
            tasks.removeValue(forKey: ref)?.cancel()
            entry.message = nil
            entry.needsManualApproval = false
            entries[ref] = entry
            guard entry.countdown.pending != nil else { continue }
            CommandLog.log("auto", ref.targetID, "pane=\(ref.paneID) countdown=5s")
            let id = entry.id
            tasks[ref] = Task { [weak self, weak model] in
                try? await Task.sleep(for: .seconds(ApprovalCountdown.delay))
                guard !Task.isCancelled, let self, let model else { return }
                await self.fire(ref, id: id, model: model)
            }
        }
    }

    private func fire(_ ref: PaneRef, id: UUID, model: AppModel) async {
        guard var entry = entries[ref], entry.id == id else { return }
        if let typed = model.terminals[ref]?.lastInputAt, let started = entry.countdown.startedAt, typed >= started {
            cancel(ref, source: "recent-input")
            return
        }
        guard let state = model.state(ref.targetID), let optIn = saved[ref],
              currentOptIn(for: ref, in: state) == optIn, optIn.agent == entry.countdown.agent,
              let request = entry.countdown.takeDue(now: Date()) else {
            pause(ref.targetID)
            return
        }
        entry.approving = true
        entries[ref] = entry
        let result = await AgentApproval.approve(request, host: state.host, target: state.target,
                                                pane: ref.paneID, serverPID: ref.serverPID, serverStart: ref.serverStart)
        guard var current = entries[ref], current.id == id else { return }
        current.approving = false
        let verdict = (try? result.get()) ?? "UNAVAILABLE"
        CommandLog.log("auto", ref.targetID, "pane=\(ref.paneID) result=\(verdict)")
        switch result {
        case .success("APPROVED"): current.message = "Approved this request"
        case .success("CHANGED"):
            current.message = "Request changed; check manually"
            current.needsManualApproval = true
        default:
            current.message = "Could not verify this request; check manually"
            current.needsManualApproval = true
        }
        entries[ref] = current
        tasks[ref] = nil
        state.refreshRequested = true
    }
}
