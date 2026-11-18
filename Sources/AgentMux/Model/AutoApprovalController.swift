import AgentMuxCore
import Foundation
import Observation

@MainActor @Observable
final class AutoApprovalController {
    struct Entry: Equatable {
        let id = UUID()
        var countdown: ApprovalCountdown
        var approving = false
        var needsManualApproval = false
        var message: String?
    }
    private(set) var entries: [PaneRef: Entry] = [:]
    @ObservationIgnored private var tasks: [PaneRef: Task<Void, Never>] = [:]
    var enabledRefs: Set<PaneRef> { Set(entries.keys) }

    func canEnable(_ ref: PaneRef, model: AppModel) -> Bool {
        guard let state = model.state(ref.targetID), state.lastFailure == nil,
              state.target.access.allowsAttach, state.ref(for: ref.paneID) == ref,
              let d = state.detections[ref.paneID], d.kind.isAgent,
              let pid = d.pid, pid > 0, let ticks = d.startTicks, ticks > 0 else { return false }
        return true
    }

    func setEnabled(_ enabled: Bool, for ref: PaneRef, model: AppModel) {
        tasks.removeValue(forKey: ref)?.cancel()
        entries[ref] = nil
        guard enabled, canEnable(ref, model: model), let state = model.state(ref.targetID),
              let d = state.detections[ref.paneID], let pid = d.pid, let ticks = d.startTicks else { return }
        entries[ref] = Entry(countdown: ApprovalCountdown(agent: .init(pid: pid, startTicks: ticks)))
        state.refreshRequested = true
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

    func reconcile(_ state: TargetState, model: AppModel) {
        for ref in entries.keys.filter({ $0.targetID == state.id }) {
            guard var entry = entries[ref] else { continue }
            let identity = entry.countdown.agent
            guard canEnable(ref, model: model), let d = state.detections[ref.paneID],
                  identity.pid == d.pid, identity.startTicks == d.startTicks else {
                setEnabled(false, for: ref, model: model)
                continue
            }
            guard !entry.approving else { continue }
            let old = entry.countdown
            entry.countdown.observe(state.snapshot?.approvals[ref.paneID], now: Date())
            guard old != entry.countdown else { continue }
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
        guard canEnable(ref, model: model), let state = model.state(ref.targetID),
              state.detections[ref.paneID]?.pid == entry.countdown.agent.pid,
              state.detections[ref.paneID]?.startTicks == entry.countdown.agent.startTicks,
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
