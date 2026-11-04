# 0018 — Job progress separates execution, reporting and results

Date: 2026-11-04

Status: accepted

## Problem

A quiet pytest process was labeled Stalled after 90 seconds without a parseable
counter. A wrapped synchronizer repeated two other jobs' counters as its own,
reused an old ETA, and attributed its start time to a much older experiment.
A phase's completed-group count also concealed assertions advancing inside
unfinished groups.

## Decision

- Keep execution state, reporting heartbeat and source/progress timestamps
  separate. Reporting silence means Stale; only the producer can assert execution
  state. The standard wrapper emits heartbeats even without output.
- Accept real start/finish times and PID incarnation metadata. Omit unknown
  starts; freeze terminal durations, falling back to the final report for old
  records. Represent preparing, queued, paused and an exited unknown outcome.
- Give each job a stable id; reports can explicitly supersede raw worker records
  when they describe the same job. Preserve active ordering across heartbeats.
- Counts determine the fraction before an optional percentage. Phase changes and
  new runs clear incompatible values. Unknown totals remain indeterminate.
- Task bars use execution/completion colors rather than a resource-capacity
  threshold: accent while running, green when done, red on failure. Subtask bars
  use accent until complete, then green.
- Keep per-group counts as structured details with units; the full status text
  is available under a native disclosure. Terminal jobs have a separate folded
  group. Timers refresh every five seconds rather than driving continuous text
  animations on every frame.
- Estimate ETA from observed increments, not time since attaching a reporter.
  Refresh the estimate as work advances, timestamp it independently, expire it
  after 90 seconds, and hide an exhausted estimate. Show sub-minute durations in
  seconds.
- Document PTY stream merging/newline conversion and offer pipe mode for separate
  byte streams. Synchronizers call report directly, once per actual job.

## Compatibility and verification

Schema 1 records remain readable. Old wrapper processes keep their already-loaded
code until completion; deployment replaces files atomically and preserves backups.
No experiment restart is needed to replace its separate progress synchronizer.
Python subprocess tests exercise quiet heartbeats, stream preservation, parser
chunk boundaries, exit codes, signals and telemetry failures. Swift tests cover
fraction precedence, staleness, frozen elapsed time, ETA expiry, details, stable
ordering and superseded workers.

## Remaining duration and estimated finish (2026-11-04)

Custom reports opt in with `report --estimate`. Numeric observations are saved
with the job, scoped to run, phase, unit and total, in a rolling 30-minute window.
Time without a count increment is retained; process attachment age is not used
as a rate. Resets and pauses clear the sampling window. Repeated report commands
and monitor restarts retain comparable observations.

The inspector pairs Remaining (rounded, marked approximate) with Est. finish
(local date/time, Today/Tomorrow or an explicit date). Both derive from the same
sample timestamp and duration, so the finish clock does not drift between new
estimates. Stale, paused and terminal jobs omit the pair; a live counter waiting
for a rate shows Estimating. This extends both generic reports and the custom
progress adapter without restarting the experiment itself.
