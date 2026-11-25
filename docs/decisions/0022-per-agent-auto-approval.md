# Per-agent approval countdown

Date: 2026-11-18

## Scope

The user requested an independent switch for each agent and a five-second
countdown, with minimal effects on normal polling. This is separate from the
existing auto-continue setting for retryable errors. Auto mode is an explicit
opt-in to confirming actions, including commands and edits; it starts off and
is not persisted across launches. An opt-in binds to the exact pane/server
generation, agent PID and process start ticks. Account switches, process
replacement and target removal discard it.

On 2026-11-24, the opt-in was made persistent at the user's request. The app
restores it only after verifying the same SSH destination, container generation,
tmux pane and agent process. A recognized prompt on the first approval check
after restoration is skipped and shown for manual handling.

## Evidence and detection

The supplied Claude approval screenshot shows an unnumbered menu whose default
selection is No, followed by Yes and the Esc-to-cancel footer. Existing screen
rules recognize numbered menus; normally Claude's own session state eventually
reports the approval, with a polling delay. A bounded read-only check of visible
or opted-in agents now recognizes an active known question, explicit options,
exactly one selection cursor and its footer. It reports only PID, start ticks
and a SHA-256 fingerprint. A request matching the detected process can mark the
agent as waiting for approval before the session-state sidecar catches up.

The check shares the existing inventory connection and polling interval. One
Python process examines the requested agents; it does not scan all containers
or increase the global polling rate. Other panes retain their existing rules.
Missing Python or ambiguous/partial menus produce no automatic action.

## Execution

The UI exposes one switch in the bottom status bar and an orange sidebar mark. A local timer
shows Yes in 5s with Cancel in the bottom bar. Cancellation or local terminal
input records the dialog as handled, preventing another countdown for it even
if cursor movement or keyboard activity changes the execution fingerprint.
Changed or missing evidence resets the countdown; a replaced process disables
the switch. Completed and skipped tokens are kept in a bounded 256-entry list.

At expiry a separate remote command verifies the tmux server generation, PID
start ticks, foreground process group and ancestry under the exact pane. It
also checks external client keyboard activity. A digest binds the visible
approval content, initial selected option and keyboard-activity timestamp. It only
moves toward the exact one-time Yes option, verifies each cursor movement and
checks the process and request again before Enter. Unknown layouts, changed
actions and recent human input are refused. A confirmation already in progress
cannot be undone; turning the switch off cancels pending countdowns and future
actions.

Approval and error auto-continue use the same `ScheduledActionControls` view,
including the existing `NudgeRing`, hover buttons and cancellation layout.
Their send operations keep their own validation. The bottom Auto switch uses
a subtle neutral selection with the shared hover button style.

The active screen fingerprint excludes scrollback: an isolated real-tmux test
showed that a CSI 2J cursor redraw can add the previous screen to history even
though the request is unchanged. Including that history incorrectly refused
the confirmation. Capturing only the viewport fixes that case while preserving
the proposed-action fingerprint. Raw terminal text is never returned or logged.

Claude's framed auto-mode fallback can keep repainting an unrelated row
above a pending dialog. Live samples of one request alternated between two
viewport fingerprints while the action and options stayed identical. When the
provider notice follows a unique full-width rule above the action preview, the
fingerprint covers the preview through the dialog footer. It preserves action
indentation and ignores cursor markers only on option rows. Other layouts
keep the viewport through the footer. Regression tests cover background
repaints, action changes and a full-width rule embedded in the action itself.

Claude's numbered Bash prompt can also show its own expiry timer between the
closed command preview and the question. On a live pane that timer and an
unrelated background row changed while Yes stayed selected. The remote recheck
rejected successive attempts, and the prompt eventually disappeared. When the
framed Bash heading, preview separators and exact provider notice identify that
layout, only the provider countdown value is normalized. Tests verify that a
timer tick through the final Enter check is allowed and that timer-like text
inside the command still affects the fingerprint.

## Verification

Core tests cover the five-second deadline, unchanged refreshes, changed
requests, per-process identity, cancellation, deduplication and protocol
parsing. Python tests exercise the exact embedded program, including screenshot
and numbered Claude/Codex layouts, foreground/server/PID guards, external input
and fresh checks before Enter. An isolated local tmux session runs a synthetic
interactive menu: it starts at No, receives Down then Enter, records exactly
one Yes, and rejects a repeated confirmation. Linux /proc identity checks use
fixtures. Regression tests send keys only to synthetic panes.

Live integration exposed the container response envelope: `RemoteScript`
returns an `@@container` metadata line before the verdict. Parsing the whole
string as a verdict incorrectly reported manual handling. The approval parser
now handles that envelope like `AgentNudge.parse`, with a regression covering
all three verdicts and ambiguous output. Navigation also waits through a short
blank repaint while still requiring the original process, request and keyboard
activity before Enter. Structural countdown/cancel/result events are logged
without terminal text.

The next live observation recorded cancellation 1.6 seconds into the countdown.
The terminal key callback had counted every keyDown, including Command
shortcuts that do not type into the agent. Command shortcuts now leave the
countdown alone; text paste and image paste still register real input. The Auto
switch stays on the right edge of its control group as countdown controls
appear, keeping Cancel from shifting into the switch's former click position.
Cancellation logs distinguish the Cancel button, local terminal input and the
final recent-input check.
