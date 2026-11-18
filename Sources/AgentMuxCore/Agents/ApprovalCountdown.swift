import Foundation

/// One explicit opt-in for one process lifetime; no persisted global switch.
public struct ApprovalCountdown: Sendable, Equatable {
    public static let delay: TimeInterval = 5
    public let agent: AgentApproval.Agent
    public private(set) var pending: AgentApproval.Request?
    public private(set) var startedAt: Date?
    private var handled: [String] = []

    public init(agent: AgentApproval.Agent) { self.agent = agent }

    public mutating func observe(_ request: AgentApproval.Request?, now: Date) {
        guard let request, request.agent == agent, !handled.contains(request.dialogID) else {
            pending = nil; startedAt = nil
            return
        }
        if pending != request { pending = request; startedAt = now }
    }

    public mutating func cancel() {
        if let pending {
            // Cursor movement or keyboard activity changes the execution token,
            // but must not revive a dialog the user already cancelled.
            handled.append(pending.dialogID)
            if handled.count > 256 { handled.removeFirst() }
        }
        pending = nil; startedAt = nil
    }

    public mutating func takeDue(now: Date) -> AgentApproval.Request? {
        guard let request = pending, let startedAt, now.timeIntervalSince(startedAt) >= Self.delay else { return nil }
        cancel()
        return request
    }
}
