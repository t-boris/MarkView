---
type: bug
id: BUG-082
title: UI Studio redacts the server log on the main thread for every output chunk
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio redacts the server log on the main thread for every output chunk

## Summary

Each chunk a UI Studio dev server prints calls `refreshServerLog()` on the main actor, which runs every `StudioRedactor` regular expression over the last 12,000 characters of the output. With a chatty server (here 30 rebuild lines a second) the main thread spent ~90% of its time in ICU regex matching, so MarkView stuttered and macOS filed cpu_resource reports (68–89% CPU over 100–130 s).

## Steps to reproduce

1. Run a UI Studio session whose dev server prints many lines per second
2. Sample MarkView: `/usr/bin/sample <pid> 3`
3. Thread 0 is in StudioSession.refreshServerLog → StudioRedactor.redact(text:)

## Expected

The visible server log is redacted off the main thread and at most a few times a second, however fast the server prints.

## Actual

1,366 of 1,480 main-thread samples in StudioRedactor.redact(text:); the redaction runs once per output chunk.

## Environment

MarkView 5.25.0, macOS 27.0.1; DiagnosticReports MarkView_2026-11-04-120435 and -122954 cpu_resource.diag
