---
type: bug
id: BUG-039
title: Operation terminals append a debug trace to /tmp/markview-ops-debug.log on every output chunk
status: done
branch: fix/bug-039-operation-debug-trace
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Operation terminals append a debug trace to /tmp/markview-ops-debug.log on every output chunk

## Summary

`TerminalSession.trace(_:)` opens `/tmp/markview-ops-debug.log`, seeks to the end, writes one line and closes the file, synchronously, for every delivered or flushed chunk of an operation session (and on ready, write errors and exit). The log has no rotation and no switch to turn it off. It looks like leftover debugging; it adds file I/O to the output path (REQ-015: stay responsive under high-volume output) and leaves a growing file in `/tmp`. The lines carry byte counts and error descriptions, not terminal output. Found by a read-only audit.

## Steps to reproduce

1. Run any project operation that prints a lot of output (for example a build).
2. Watch `/tmp/markview-ops-debug.log` with `tail -f`.

## Expected

No per-chunk file I/O in release behaviour; debug tracing is off or goes through the normal logging facility.

## Actual

One open, seek, write and close per chunk, each producing a log line; the file keeps growing across runs.

## Environment

MarkView current main (ade7910), MarkView/Models/TerminalSession.swift `trace` (line 650) and its callers at lines 185, 594, 617, 630 and 646; code reading only.

## Cause

`TerminalSession.trace(_:)` was added together with the rest of the operation terminal in the single commit
`bb91412` (Project operations, 3.6.0). Its call sites sit exactly on the points where an operation session hands
output to the page: the page's `ready` message, `deliver` (PTY bytes arrive), `flush` (a chunk goes to
`mvWrite`), the completion of `mvWrite` and the completion of `mvExited`. That is the shape of a temporary probe
for the ordering of page readiness, buffered output and the exit marker (`exitMarkerPending`,
`outputEvaluationsInFlight`). It was never removed once that ordering worked.

Nothing refers to it: no requirement, decision, finding, architecture page, README entry, script or test in the
repository mentions `/tmp/markview-ops-debug.log`, and a search of the history for that string finds only the
commit that added it and the commit that filed this report. So there is no documented purpose to keep.

Every call opened the file, seeked to the end, wrote one line and closed it, on the main actor, with no size
limit. `deliver` runs for each read from the PTY and `flush` for each chunk of at most 32 KiB, so a noisy build
wrote thousands of lines. When this was fixed, the file on Boris's machine was about 250 MB.

## Resolution

The tracing is removed from the output path; no replacement switch was added.

- `TerminalSession.trace(_:)` and its five call sites are deleted.
- The two `evaluateJavaScript` completion handlers that existed only to feed the trace are reduced to what they
  still do: the `mvWrite` handler keeps decrementing `outputEvaluationsInFlight` and calling
  `finishOutputDisplayIfReady()`; the `mvExited` call no longer has a handler.

An opt-in debug switch was considered and rejected: nothing needs the trace, and a future probe can be added
for the occasion without leaving file I/O in the shipping output path.

## Not changed

- Terminal behaviour: buffering, the 16 MB / 8 MB cap with the dropped marker, the 16 ms flush cadence, the
  exit-marker ordering and the startup-command handling are untouched.
- `/tmp/markview-ops-debug.log` files already on a machine are not deleted by the app. A user can remove the
  file; the app no longer creates or appends to it.
- Other diagnostic logs (`/tmp/markview-insight-diag.log`, `WorkspaceManager.debugLog`) are outside this change.

## Verification

- Debug build with `xcodebuild` (see CLAUDE.md) passes. The string `markview-ops-debug` no longer appears in the
  built `MarkView.debug.dylib`.
- `bash tools/tests/terminal-child-tests.sh` passes. `bash tools/tests/pty-writer-tests.sh` passes.
- `bash tools/tests/terminal-layout-tests.sh` (WKWebView, shipping xterm bundle, live PTY, compiled with the
  changed `TerminalSession.swift`): 61 checks, 0 failures.
- `bash tools/tests/terminal-link-tests.sh`: 82 checks, 1 failure ("unsupported file uses default app",
  `archive.iso`). The same single failure occurs with the unmodified `TerminalSession.swift`, so it predates this
  change and was not investigated here.
- Not exercised by a run: an actual project operation in the app (Deploy / Install / Restart), a high-volume
  output run, or a check that no `/tmp/markview-ops-debug.log` is created or grown while one runs. None of the
  scripts above creates an operation session (`operationCommand` is nil there), so they cover the shared
  deliver/flush/exit path but not the removed operation-only branches. Their absence is established by the build
  and by reading the diff.
