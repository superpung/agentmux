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

    @Test func codexLogStateWinsOverScreen() {
        // task_started/task_complete reduced on the server to a verdict.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "idle", logState: "working").activity == .working)
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working", logState: "idle").activity == .idle)
        // No log verdict falls back to the screen.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working", logState: nil).activity == .working)
    }

    @Test func screenStateFallbackWhenNoLog() {
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working").activity == .working)
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "idle").activity == .idle)
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: nil).activity == .unknown)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: nil, screenState: "unknown").activity == .unknown)
    }

    @Test func codexActionRequiredTitleIsWaitingInput() {
        // Real title captured live (2026-10-14) from a Codex pane blocked on a
        // user prompt. Wins over any log/screen signal, including "working".
        let title = "[ ! ] Action Required | ______________PR | conf-scheduler"
        #expect(ActivityDetector.attentionVerdict(kind: .codex, title: title)?.activity == .waitingInput)
        let r = ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working",
                                         logState: "working", title: title)
        #expect(r.activity == .waitingInput)
        #expect(r.activity.needsAttention)
    }

    @Test func codexWorkingIdleTitlesAreNotAttention() {
        // Sibling panes captured the same moment that are NOT waiting.
        for title in ["________DDL________ | dashboard", "usage-monitor", ""] {
            #expect(ActivityDetector.attentionVerdict(kind: .codex, title: title) == nil)
        }
    }

    @Test func codexWorkingNeedsSpinnerNotJustLog() {
        // Codex animates a Braille spinner in its title while a turn runs.
        #expect(ActivityDetector.codexTitleIsWorking("⠸ demo-dev-v5 | demo"))
        #expect(!ActivityDetector.codexTitleIsWorking("demo-paper-v2 | demo"))
        // A spinner means working even with no log/screen signal.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: nil,
                                         logState: nil, title: "⠸ dev-v5").activity == .working)
        // No spinner + logState "working" → idle: the rollout log can be
        // cross-attributed between codex agents sharing a directory, so it is
        // not trusted to assert working without the per-pane spinner/screen.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: nil,
                                         logState: "working", title: "paper-v2").activity == .idle)
        // A real per-pane screen "working" verdict still counts without a spinner.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "working",
                                         logState: nil, title: "dev-v5").activity == .working)
        // Idle signals → idle.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: nil,
                                         logState: "idle", title: "dev-v5").activity == .idle)
    }

    @Test func claudeTitleNeverClaimsAttention() {
        // No verified Claude title marker: the phrase must not trigger for it.
        #expect(ActivityDetector.attentionVerdict(kind: .claudeCode, title: "Action Required") == nil)
    }

    @Test func activityNeedsAttentionMapping() {
        #expect(AgentActivity.waitingInput.needsAttention)
        #expect(AgentActivity.waitingApproval.needsAttention)
        #expect(!AgentActivity.idle.needsAttention)
        #expect(!AgentActivity.working.needsAttention)
    }
}
