# Stream reader memory lifetime

Date: 2026-11-17

## Evidence

An AgentMux 0.4.4 process running for about 23 hours had a physical footprint of
about 5.7 GiB. Its RSS was only a few hundred MiB because most writable pages
were compressed or swapped out. `vmmap` reported about 5.0 GiB of live malloc
allocations with only 8% allocator fragmentation. The dominant allocation type
was roughly 304,000 16 KiB `NSConcreteData` byte buffers, about 4.6 GiB total.
GPU-related categories were approximately 270 MiB across four terminal surfaces.

Content-free autorelease-pool inspection found the read buffers on four
long-lived threads. A stack sample mapped those same threads to the stdout
read loop in `ControlClient.start`, blocked inside `FileHandle.availableData`.
Terminal history, renderer allocations and inventory dictionaries did not
account for the dominant data-buffer allocation.

A controlled 128 MiB synthetic pipe reproduced the lifetime problem with the
reader thread deliberately kept alive after consuming all bytes. The unpooled
reader grew its physical footprint by 135,922,048 bytes; a per-read pool reduced
that growth to 442,432 bytes. Letting the thread exit before measuring would
drain its outer pool and hide the bug.

## Decision

Use an internal `PipeReader.readAvailable(from:)` that wraps the Foundation
read in an `autoreleasepool`. Swift `Data` keeps ownership after returning,
including when it is captured by an asynchronous consumer. Temporary Objective-C
references from the read are released immediately rather than at thread exit.

Apply the same lifetime boundary to control stdout/stderr, remote file watches
and command-runner pipes. The PTY transport already uses POSIX `read` and does
not share this Foundation autorelease issue. Data limits, ordering, terminal
history and view-retention policy remain as before.

The regression test streams 128 MiB through the production helper while its
reader thread stays alive. It checks delivered bytes and a generous 64 MiB
footprint-growth bound. It failed before the pool with 135,037,120 bytes of
growth and passes with the fix. A second test verifies that returned data stays
valid after the read pool drains and that EOF is preserved.

## Verification limits

Live diagnosis uses allocation types, thread stacks and memory counters without
reading or saving agent conversation content. A restart clears existing pools;
the controlled reproduction establishes which growth mechanism was removed.

After installing the optimized local build and restoring the selected agent,
three heap samples over approximately seven minutes each reported 275
`NSConcreteData` objects occupying 9 KiB, with no recurrence of the large read
buffer category. Total footprint grew from about 168 MiB at 40 seconds to
284 MiB at ten minutes, so this is not evidence of a stable long-term plateau.
The restarted app had one terminal surface, whereas the old app had four;
the entire footprint difference must not be attributed to the pool fix.

The remaining growth was primarily non-object allocations, including paired
2 KiB and 2.5 KiB blocks. Two sampled 2.5 KiB blocks were retained through the
same CFDictionary referenced by AttributeGraph data. This does not establish
the allocation site's cause or whether the cache is bounded, and is a separate
follow-up from the verified pipe-buffer retention. Renderer caches, SwiftUI
bookkeeping and transport backlog need their own evidence before changing
history retention or delivery behavior.

## Follow-up observation

At approximately 29 minutes, the same fixed process was still running with one
terminal surface and the selected agent's SSH connection. Its measured footprint
had fallen to 215.8 MiB, below the earlier ten-minute measurement; the recorded
process peak was 323.6 MiB. Live malloc allocations fell from 138.0 MiB at about
seven minutes to 61.9 MiB, and non-object allocations fell from 104.3 MiB to
26.4 MiB. The read-buffer objects still occupied only 9 KiB (285 objects).
The main window was confirmed to show the original selected agent.
A further 13 samples taken ten seconds apart over two minutes measured
214.77–220.19 MiB of footprint, ending at 220.19 MiB.

This demonstrates reclamation of the previously growing allocation category in
this run, rather than continued monotonic retention. It does not identify an
exact cache policy or prove a multi-day bound under every workload. The
synthetic stream regression remains the evidence for the pipe fix itself.

Validation passed all 277 Swift tests, 53 Python tests (four additional opt-in
tests skipped), an optimized app build and the three packaged-resource smoke
scenarios.
