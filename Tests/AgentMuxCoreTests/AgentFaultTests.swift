@testable import AgentMuxCore
import Foundation
import Testing

/// A turn that stopped on a usage limit or an error, as the probe reports it
/// (fields captured from real Claude transcripts and Codex screens, 2026-10),
/// and the tracker that reports each occurrence once.
@Suite struct AgentFaultTests {
    private func fault(_ line: String) -> AgentFault? {
        AgentFault.parse(line.split(separator: " "))
    }

    @Test func claudeQuotaRejectionIsAUsageLimit() throws {
        let f = try #require(fault("claude rate_limit rejected 1791700800 five_hour 1791690000"))
        #expect(f.kind == .usageLimit)
        #expect(f.resetsAt == 1_791_700_800)
        #expect(f.summary == "5-hour limit")
        #expect(!f.isRetryable)
    }

    @Test func claudeConnectionAndServerErrorsAreRetryable() throws {
        // "API Error: EPROTO: The TLS handshake failed" / "Connection lost mid-response".
        let tls = try #require(fault("claude unknown - - - 1791690000"))
        #expect(tls.kind == .error && tls.isRetryable && tls.summary == "Connection error")
        #expect(tls.occurredAt == 1_791_690_000)
        let lost = try #require(fault("claude server_error - - - -"))
        #expect(lost.kind == .error && lost.isRetryable)
        // A 429 without a rejected quota is a transient rate limit.
        #expect(fault("claude rate_limit - - - -")?.isRetryable == true)
    }

    @Test func claudeAuthAndBadRequestsAreNotRetried() {
        #expect(fault("claude authentication_failed - - - -")?.isRetryable == false)
        #expect(fault("claude invalid_request - - - -")?.isRetryable == false)
        #expect(fault("claude billing_error - - - -")?.isRetryable == false)
    }

    @Test func codexClasses() {
        #expect(fault("codex usage_limit - - - -")?.kind == .usageLimit)
        #expect(fault("codex error - - - -")?.isRetryable == true)
        #expect(fault("codex fatal - - - -")?.isRetryable == false)
        #expect(fault("other error") == nil)
        #expect(fault("claude") == nil)
    }

    @Test func probeLineParses() throws {
        let out = """
        @@begin 1 n0nce
        @@uid 0
        @@tmux tmux 3.4
        @@server 1 2 /tmp/tmux-0/default
        @@section agents
        @@fault %14 claude unknown - - - 1791690000
        @@fault %6 codex error - - - -
        @@fault bad codex error - - - -
        @@end n0nce
        """
        let s = try InventoryProbe.parse(out, nonce: "n0nce")
        #expect(s.faults["%14"]?.code == "unknown")
        #expect(s.faults["%6"]?.kind == .error)
        #expect(s.faults.count == 2)
    }

    @Test func trackerReportsEachOccurrenceOnce() throws {
        var tracker = FaultTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = try #require(fault("claude unknown - - - 100"))
        // A target's first poll only records what is already there.
        #expect(tracker.update(["%1": first], now: t0, report: false).isEmpty)
        #expect(tracker.update(["%1": first], now: t0 + 5).isEmpty)
        // A new error record is a new occurrence.
        let second = try #require(fault("claude unknown - - - 200"))
        #expect(tracker.update(["%1": second], now: t0 + 10)["%1"] == second)
        // Cleared, then back: reported again.
        #expect(tracker.update([:], now: t0 + 15).isEmpty)
        #expect(tracker.update(["%1": second], now: t0 + 20).count == 1)
    }

    @Test func trackerTreatsAFaultSurvivingANudgeAsNew() throws {
        var tracker = FaultTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let codex = try #require(fault("codex error - - - -"))
        #expect(tracker.update(["%6": codex], now: t0).count == 1)
        #expect(!tracker.isHandled("%6"))
        tracker.noteNudge("%6", at: t0 + 1)
        #expect(tracker.update(["%6": codex], now: t0 + 60).isEmpty)
        #expect(tracker.isHandled("%6"))
        #expect(tracker.update(["%6": codex], now: t0 + 1 + FaultTracker.renudgeAfter).count == 1)
        #expect(tracker.update(["%6": codex], now: t0 + 200).isEmpty)
    }

    @Test func abandonedFaultStaysHandledUntilItClears() throws {
        var tracker = FaultTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let codex = try #require(fault("codex error - - - -"))
        _ = tracker.update(["%6": codex], now: t0)
        tracker.abandon("%6")
        #expect(tracker.update(["%6": codex], now: t0 + 1000).isEmpty)
        #expect(tracker.isHandled("%6"))
        _ = tracker.update([:], now: t0 + 1010)
        #expect(tracker.update(["%6": codex], now: t0 + 1020).count == 1)
        #expect(!tracker.isHandled("%6"))
    }
}
