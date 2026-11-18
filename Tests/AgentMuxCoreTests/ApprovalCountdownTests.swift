@testable import AgentMuxCore
import Foundation
import Testing

@Suite struct ApprovalCountdownTests {
    let agent = AgentApproval.Agent(pid: 42, startTicks: 123)
    let now = Date(timeIntervalSince1970: 100)
    func request(_ token: String = "a") -> AgentApproval.Request {
        .init(agent: agent, fingerprint: String(repeating: token, count: 64))
    }

    @Test func firesAfterFiveSecondsOnce() {
        var c = ApprovalCountdown(agent: agent)
        #expect(c.pending == nil)
        c.observe(request(), now: now)
        #expect(c.takeDue(now: now.addingTimeInterval(4.99)) == nil)
        #expect(c.takeDue(now: now.addingTimeInterval(5)) == request())
        c.observe(request(), now: now.addingTimeInterval(10))
        #expect(c.pending == nil)
        #expect(c.takeDue(now: now.addingTimeInterval(20)) == nil)
    }

    @Test func refreshedRequestKeepsDeadlineButChangedRequestRestartsIt() {
        var c = ApprovalCountdown(agent: agent)
        c.observe(request(), now: now)
        c.observe(request(), now: now.addingTimeInterval(2))
        #expect(c.startedAt == now)
        c.observe(request("b"), now: now.addingTimeInterval(3))
        #expect(c.takeDue(now: now.addingTimeInterval(5)) == nil)
        #expect(c.takeDue(now: now.addingTimeInterval(8)) == request("b"))
    }

    @Test func cancellationSkipsThisRequestButAllowsNewOnes() {
        var c = ApprovalCountdown(agent: agent)
        c.observe(request(), now: now)
        c.cancel()
        c.observe(nil, now: now)
        c.observe(request(), now: now.addingTimeInterval(10))
        #expect(c.pending == nil)
        c.observe(request("b"), now: now.addingTimeInterval(10))
        #expect(c.takeDue(now: now.addingTimeInterval(15)) == request("b"))
    }

    @Test func missingEvidenceOrReplacedProcessCannotFire() {
        var c = ApprovalCountdown(agent: agent)
        c.observe(request(), now: now)
        c.observe(nil, now: now.addingTimeInterval(2))
        #expect(c.takeDue(now: now.addingTimeInterval(6)) == nil)
        c.observe(.init(agent: .init(pid: 42, startTicks: 124), fingerprint: request().fingerprint), now: now)
        #expect(c.pending == nil)
    }

    @Test func humanCursorMovementCannotReviveACancelledDialog() {
        var c = ApprovalCountdown(agent: agent)
        c.observe(request(), now: now)
        c.cancel()
        c.observe(.init(agent: agent, fingerprint: request("b").fingerprint,
                        dialogID: request().dialogID), now: now.addingTimeInterval(2))
        #expect(c.pending == nil)
        #expect(c.takeDue(now: now.addingTimeInterval(10)) == nil)
    }

    @Test func parsesOnlyStructuralEvidence() throws {
        let token = request().fingerprint
        let parsed = try #require(AgentApproval.parse("%3 42 123 \(token) \(token)"))
        #expect(parsed.pane == "%3")
        #expect(parsed.request == request())
        for text in ["bad 42 123 \(token)", "%3 0 123 \(token)", "%3 42 123 nope"] {
            #expect(AgentApproval.parse(text) == nil)
        }
        let snapshot = try InventoryProbe.parse("@@begin 1 test\n@@approval %3 42 123 \(token) \(token)\n@@end test\n", nonce: "test")
        #expect(snapshot.approvals["%3"] == request())
    }

    @Test func unobservedTargetsHaveNoAdditionalApprovalProbe() throws {
        let tmux = try TmuxInvocation(executable: nil, socket: TmuxInvocation.Socket.default)
        #expect(!InventoryProbe.script(tmux: tmux, nonce: "test").contains("__AGENTMUX_APPROVAL__"))
        #expect(InventoryProbe.script(tmux: tmux, nonce: "test", approvalAgents: ["%3": agent]).contains("__AGENTMUX_APPROVAL__"))
    }

    @Test func approvalOutcomesAcceptContainerMetadataAndRejectUnknownOutput() throws {
        for verdict in ["APPROVED", "CHANGED", "UNAVAILABLE"] {
            #expect(try AgentApproval.parseOutcome("@@container abcd running 2026-11-18T00:00:00Z 123\n\(verdict)\n").get() == verdict)
            #expect(try AgentApproval.parseOutcome(verdict).get() == verdict)
        }
        for text in ["", "@@container abcd running", "APPROVED\nCHANGED", "unexpected"] {
            guard case .failure = AgentApproval.parseOutcome(text) else {
                Issue.record("accepted an ambiguous approval outcome"); continue
            }
        }
    }
}
