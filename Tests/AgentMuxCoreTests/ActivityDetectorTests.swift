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

    // Real Claude selection/permission prompt (xp01, 2026-10-24): the "❯" cursor
    // sits on a numbered option while it waits for the user to choose. The cursor
    // also starts a plain idle prompt, so the menu must not be read as idle.
    let claudeSelectionPrompt = [
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. No, and tell Claude what to do differently (esc)",
        "──────────────────────────────────────────────── resume ─",
    ]

    @Test func claudeSelectionPromptIsWaitingInput() {
        let r = ActivityDetector.screenVerdict(kind: .claudeCode, screen: claudeSelectionPrompt)
        #expect(r.activity == .waitingInput)
        #expect(r.activity.needsAttention)
        // A plain idle prompt is still idle, not waiting.
        #expect(ActivityDetector.screenVerdict(kind: .claudeCode, screen: claudeIdle).activity == .idle)
    }

    @Test func screenWaitingStateIsWaitingInput() {
        // The server reduces the selection prompt to screenState "waiting"; it
        // outranks a trailing user/assistant log record that looks "in progress".
        let r = ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: "waiting")
        #expect(r.activity == .waitingInput)
        #expect(r.activity.needsAttention)
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
        // With no screen signal, the log's last turn event decides.
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "assistant/", screenState: nil).activity == .working)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: nil).activity == .working)
    }

    @Test func screenIdleOutranksTrailingTurnRecord() {
        // A resumed/paused Claude session can end its log on a tool_result or a
        // plain user/assistant record while sitting idle at the prompt. The "❯"
        // screen verdict (idle) must win over that stale last-line inference, or
        // the pane reads "working" forever (xp01, 2026-10-24).
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: "idle").activity == .idle)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "assistant/", screenState: "idle").activity == .idle)
        // A genuinely running turn still shows the spinner, so screen "working" wins too.
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: "working").activity == .working)
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

    /// Claude's own state (sessions/<pid>.json) wins over the screen. Seen
    /// live 2026-10-28: while Claude waited out an API retry ("Waiting for API
    /// response · will retry in 1m 33s"), the screen read idle (no spinner
    /// marker, empty prompt) and the log ended in an api-request record, but
    /// Claude itself reported busy.
    @Test func claudeOwnStateOutranksTheScreen() {
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "api-request/", screenState: "idle", agentState: "busy").activity == .working)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "assistant/", screenState: "working", agentState: "idle").activity == .idle)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: nil, screenState: "idle", agentState: "waiting-input").activity == .waitingInput)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: nil, screenState: "idle", agentState: "waiting-approval").activity == .waitingApproval)
        // Unknown or absent (older Claude): the existing rules decide.
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: "idle", agentState: "odd").activity == .idle)
        #expect(ActivityDetector.resolve(kind: .claudeCode, logEvent: "user/", screenState: nil).activity == .working)
        // Codex ignores it.
        #expect(ActivityDetector.resolve(kind: .codex, logEvent: nil, screenState: "idle", logState: "idle", agentState: "busy").activity == .idle)
    }
}
