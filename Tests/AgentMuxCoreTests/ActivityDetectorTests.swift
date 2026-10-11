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
        let result = ActivityDetector.screenVerdict(kind: .codex, screen: codexIdle)
        #expect(result.activity == .idle)
        #expect(result.confidence == .high)
    }

    @Test func claudeInputBoxIsIdle() {
        let result = ActivityDetector.screenVerdict(kind: .claudeCode, screen: claudeIdle)
        #expect(result.activity == .idle)
    }

    @Test func claudeWorkingFromRealSpinner() {
        // Real capture (2026-10-11): spinner + elapsed, input box also present.
        let working = [
            "✽ Topsy-turvying… (23m 36s · ↓ 7.6k tokens)",
            "─────────────────────────────── tcad-dev-v2 ─",
            "❯ ",
            "  ⏵⏵ auto mode on · 2 shells · ← for agents",
        ]
        #expect(ActivityDetector.screenVerdict(kind: .claudeCode, screen: working).activity == .working)
    }

    @Test func runningToolElapsedIsWorking() {
        let working = ["  cd /data; .venv/bin/… (8m 1s)", "❯ "]
        #expect(ActivityDetector.screenVerdict(kind: .claudeCode, screen: working).activity == .working)
    }

    @Test func codexWorkingFromInterruptHint() {
        let working = [
            "• Running tool…",
            "  Esc to interrupt · gpt-5.6 high · Context 60% left",
        ]
        #expect(ActivityDetector.screenVerdict(kind: .codex, screen: working).activity == .working)
    }

    @Test func idleScreensAreNotMistakenForWorking() {
        // "shift+tab to cycle" and "Ready" must not trip the interrupt rule.
        #expect(ActivityDetector.screenVerdict(kind: .claudeCode, screen: claudeIdle).activity != .working)
        #expect(ActivityDetector.screenVerdict(kind: .codex, screen: codexIdle).activity != .working)
    }

    @Test func emptyAndUnrecognizedAreUnknown() {
        #expect(ActivityDetector.screenVerdict(kind: .codex, screen: []).activity == .unknown)
        #expect(ActivityDetector.screenVerdict(kind: .claudeCode, screen: ["$ ls", "file.txt"]).activity == .unknown)
    }

    @Test func logTurnDurationIsIdle() {
        let r = ActivityDetector.resolve(kind: .claudeCode, logEvent: "system/turn_duration", screenState: "working")
        #expect(r.activity == .idle) // log wins over screen
    }

    @Test func logMidTurnIsWorking() {
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "assistant/", screenState: nil).activity == .working)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: "idle").activity == .working)
    }

    @Test func screenStateFallbackWhenNoLog() {
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working").activity == .working)
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "idle").activity == .idle)
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: nil).activity == .unknown)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: nil, screenState: "unknown").activity == .unknown)
    }

    @Test func activityNeedsAttentionMapping() {
        #expect(AgentActivity.waitingInput.needsAttention)
        #expect(AgentActivity.waitingApproval.needsAttention)
        #expect(!AgentActivity.idle.needsAttention)
        #expect(!AgentActivity.working.needsAttention)
    }
}
