@testable import AgentMuxCore
import Testing

/// Screens faithful to real captures (2026-10-11); working samples use the
/// "esc to interrupt" hint both CLIs show while a turn runs.
@Suite struct ActivityDetectorTests {
    // Real Codex idle tail.
    let codexIdle = [
        "  保留必要的流程图、产物表和实验结果表。",
        "─ Worked for 4m 44s ──────────────────────────────────────────",
        "› Write tests for @filename",
        "  gpt-5.6-sol xhigh · Ready · Context 60% left · weekly 56% left",
    ]
    // Real Claude idle tail.
    let claudeIdle = [
        "✻ Brewed for 24m 29s · done 4:24 PM",
        "                          new task? /clear to save 290.6k tokens",
        "──────────────────────────────────────────────── demo-dev-v6 ─",
        "❯ ",
        "──────────────────────────────────────────────────────────────────",
        "    [Opus 5.5] ██░░░░ 29% | demo-pkg git:(main) | 4 hooks",
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
    ]

    @Test func codexReadyIsIdle() {
        let result = ActivityDetector.detect(kind: .codex, screen: codexIdle)
        #expect(result.activity == .idle)
        #expect(result.confidence == .high)
    }

    @Test func claudeInputBoxIsIdle() {
        let result = ActivityDetector.detect(kind: .claudeCode, screen: claudeIdle)
        #expect(result.activity == .idle)
    }

    @Test func claudeWorkingFromInterruptHint() {
        let working = [
            "✻ Thinking… (5s · esc to interrupt)",
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        #expect(ActivityDetector.detect(kind: .claudeCode, screen: working).activity == .working)
    }

    @Test func codexWorkingFromInterruptHint() {
        let working = [
            "• Running tool…",
            "  Esc to interrupt · gpt-5.6 high · Context 60% left",
        ]
        #expect(ActivityDetector.detect(kind: .codex, screen: working).activity == .working)
    }

    @Test func idleScreensAreNotMistakenForWorking() {
        // "shift+tab to cycle" and "Ready" must not trip the interrupt rule.
        #expect(ActivityDetector.detect(kind: .claudeCode, screen: claudeIdle).activity != .working)
        #expect(ActivityDetector.detect(kind: .codex, screen: codexIdle).activity != .working)
    }

    @Test func emptyAndUnrecognizedAreUnknown() {
        #expect(ActivityDetector.detect(kind: .codex, screen: []).activity == .unknown)
        #expect(ActivityDetector.detect(kind: .claudeCode, screen: ["$ ls", "file.txt"]).activity == .unknown)
    }

    @Test func activityNeedsAttentionMapping() {
        #expect(AgentActivity.waitingInput.needsAttention)
        #expect(AgentActivity.waitingApproval.needsAttention)
        #expect(!AgentActivity.idle.needsAttention)
        #expect(!AgentActivity.working.needsAttention)
    }
}
