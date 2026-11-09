---
type: bug
id: BUG-117
title: "MarkView freezes and spins: every tool call and reload reads the whole transition log once per issue, on the main thread"
status: backlog
severity: critical
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
---

# MarkView freezes and spins: every tool call and reload reads the whole transition log once per issue, on the main thread

## Summary

With four windows open MarkView keeps spinning and stalls for seconds (Boris: practically a show-stopper). The system itself reported excessive CPU for MarkView four times since 2026-11-08 (5.47.0, 5.49.0, 5.50.0, 5.51.0), always with the same stack. Cause: the transition log (.dde/lifecycle/transitions.jsonl) is read and JSON-decoded from scratch by every call of FileTransitionStorage.load(), and the lifecycle code calls it once per work item.

## Steps to reproduce

1. Open several projects in MarkView windows; the MarkView project has 32 features, 116 bugs and a 695-record transition log (293 KB)
2. Let an assistant in any window call a markview_* tool (any tool: ProjectToolRunner.run reloads the store first), or change any feature or bug file
3. Watch the app: the main thread is busy for seconds, spinners run, WindowServer and MarkView sit at 50-100% CPU

## Expected

Reading the status of an issue does not cost more than a few milliseconds, and a tool call or a reload never blocks the main thread for seconds, however long the transition log is.

## Actual

ProjectToolRunner.run -> FeatureStore.reloadSync -> IssueLifecycleCoordinator.reconcileLocal -> scheduleProgressCheck evaluates assignedVariantID for each item; each one goes history -> IssueTransitionService.records() -> FileTransitionStorage.load(), which reads the file and decodes every record with ISO8601DateFormatter (ICU loads its date symbols again and again). Measured on this project's real log with the app's own code: one load() = 61 ms, 148 loads in a row (one per item) = 9.1 s. FeatureStore, IssueLifecycleCoordinator and ProjectToolRunner are @MainActor, so this runs on the main thread. The log grows with every transition, so the cost grows with it (quadratic: items x records). macOS wrote cpu_resource reports for 5.47.0 (19:23), 5.49.0 (21:34), 5.50.0 (07:01) and 5.51.0 (10:26) whose heaviest stack is this chain (about a third of all CPU in the 5.51.0 window).

## Environment

MarkView 5.51.0 (also 5.47.0-5.50.0 per the system reports), macOS 27.0.1, four windows: MarkView, broker-fabric, vivaa-platform, product-promotion-desk. Evidence: /Library/Logs/DiagnosticReports/MarkView_2026-11-09-102648_Boris-Studio.cpu_resource.diag and three earlier ones; 8 s sample of pid 11308; benchmark on a copy of .dde/lifecycle/transitions.jsonl.
