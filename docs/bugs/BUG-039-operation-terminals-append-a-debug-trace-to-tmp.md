---
type: bug
id: BUG-039
title: Operation terminals append a debug trace to /tmp/markview-ops-debug.log on every output chunk
status: open
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
