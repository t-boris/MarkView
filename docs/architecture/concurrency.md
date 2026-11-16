# Concurrency Model

Checked against the code at `ac3001ba` (2026-11-15). Statements that come from reading the code and were not run say so.

## 1. Rules (from CLAUDE.md)

- UI state is mutated only on `@MainActor` (`SWIFT_STRICT_CONCURRENCY = targeted`).
- File, database, network and child-process work runs off the main thread.
- Never call `Process.waitUntilExit()` on the main thread. Use `MarkViewCore.Subprocess` for child processes: it drains the pipes
  while waiting and bounds the run by a timeout and an output cap.
- For a hang, run `/usr/bin/sample <pid> 3` and inspect thread 0 ([runbook](./operations-runbook.md)).

The structural rules are lint rules, not conventions: `tools/lint/architecture-lint.sh` has `process` (a `Process()` outside
`Subprocess`), `clicompletion` (a `CLICompletion.run` outside `AIOperation`), `unowned-task`, `unchecked-sendable` and the
`build-warnings` ratchet. Counts for 2026-11-15 are in
[architecture-review-2026-11-followup §13](./architecture-review-2026-11-followup.md).

## 2. Actual isolation map

| Component | Isolation | Off-main work |
|---|---|---|
| `WorkspaceManager`, `WindowComposition`, `TabsController`, `ProjectContext`, `CodeAndXRayCoordinator`, `InsightCoordinator`, `ArchitectureStore`, `FeatureStore`, `InsightSession`, `CodeExplainStore`, `DictationController`, `GitHubStore`, `AgentUsageTracker`, `TerminalSession` | `@MainActor` classes | `Task.detached` for tree builds, scans and parsing; `Subprocess` for children |
| `SemanticDatabase` | an `actor` (`AR-37`): every SQL statement runs off the main thread | `busy_timeout` of 5000 ms against the indexer child |
| `ArchitectureScanner`, `XRayDigest/Cluster/Content/Search` | not isolated, pure | run detached |
| `CLICompletion` `Invocation` | own queue; callbacks on background threads | stdout and stderr through `Subprocess.start` |
| `TerminalSession` | `@MainActor` plus `DispatchSource` read on the PTY fd | `forkpty`; the child is stopped and reaped by `TerminalChildProcess.stopAndReap` |
| Structural indexer | a separate process (`--dde-index`), started with `Subprocess.start` | stderr streamed, never `waitUntilExit` |
| `EditorView.Coordinator`, `WebViewBridge`, `TypedWebBridge` | hop with `Task { @MainActor }` | none |

## 3. Ownership of background work (`AR-19`)

| Mechanism | Where | What it does |
|---|---|---|
| `TaskBag` | `Packages/MarkViewCore` (`TaskBag.swift`) | A set of keyed cancellable tasks: `store(_:for:)` cancels the previous task of that key, `cancel(key:)`, `cancelAll()`. A window owns one (`WindowComposition.taskBag`); 18 instances exist in the app target at `ac3001ba` |
| `PollingScheduler` | `Packages/MarkViewCore` (`PollingScheduler.swift`) | The one place that polls: keyed jobs (`every(_:key:...)`, `stop(key:)`, `stopAll()`) that run only while the app is active and, for a window's scheduler, while the window is on screen. `PollingScheduler.app` is the app's own, used for what has no window (`FinderOpenRequests`) |
| `Subprocess` | `Packages/MarkViewCore` (`Subprocess.swift`) | `run`, `runBlocking` and `start` over a `SubprocessSpec` (timeout, output cap, routing, SIGTERM then SIGKILL after `terminationGrace`, merged environment with `settings.cli.extraPATH`) |

The window's `close()` stops its polls and cancels its task bag. A `Timer` is no longer used anywhere (`task-ownership.sh`: 0), and
every remaining `asyncAfter` carries a one-line `// task:` reason (21 sites).

Not finished: 263 unowned `Task {}` and `Task.detached` sites in 70 files remain, listed in `tools/lint/unowned-task-allowlist.txt`
and kept from growing by the ratchet. By area: SwiftUI button actions in `Views/` (162), X-Ray stores (37), UI Studio (19),
Cockpit (8), project operations (8) and the rest (29), by directory in the 2026-11-15 `--counts` output.

## 4. Process-spawning patterns

| Pattern | Used by | Status |
|---|---|---|
| `Subprocess.run` / `start` | `GitClient`, `GitHubClient`, `ChangeSource`, `ArchitectureScanner`, `ArchiveSupport`, `InsightArchiveExporter`, `CLICompletion.Invocation`, the structural index, deployments, Cockpit | Standard. Pipes are drained concurrently; the timeout ends the child's process group (SIGTERM, then SIGKILL) |
| `forkpty` | `TerminalSession` | Interactive shells; the exit source and the reaper are in `TerminalChildProcess` |
| `Process()` | nothing outside `Subprocess` | Lint `process`: 0 (2026-11-15) |

Resolved since the 2.17.0 audit: `ArchitectureStore.prFileURL` no longer runs `git show` (it is a synchronous cache lookup in
`ChangeReviewStore`; the copy is made by `ChangeSource.materialize`), `InsightArchiveExporter` reads its pipes through
`Subprocess.run`, and the CLI runs of `CLICompletion` go through `Subprocess.start`, which escalates from SIGTERM to SIGKILL after `terminationGrace`.

## 5. Known main-thread hazards

Ranked by likely user impact. The list is from the 2.17.0 audit, re-read against the code; confirm with `sample` before fixing.

| # | Hazard | Status at `ac3001ba` |
|---|---|---|
| 1 | Every SQL statement on main | Fixed: `SemanticDatabase` is an actor |
| 2 | `GraphRAG` and Insight prompt builders read whole files on main; `InsightCache.init` copies the vendor tree | Not re-checked |
| 3 | The editor reads and base64-encodes every referenced image on each load | Superseded: pictures next to a document are served by the `markview-doc:///` scheme (`DocumentFileSchemeHandler`, `DocumentFiles`); not re-measured |
| 4 | `FeatureStore` writes and reloads on main, with a 3 s poll | The poll is now a `PollingScheduler` job in `FeatureStore`; the writes on main were not re-checked |
| 5 | `hasMarkdownFiles` walked the folder while a menu rendered | Fixed: a stored flag set by a background walk (`AR-42`) |
| 6 | `WhisperClient.transcribe` builds a large upload body on main | Not re-checked |
| 7 | `prFileNotes` builds an LCS table of up to 8 million cells on main | Not re-checked |
| 8 | A 2 s timer re-reads every open tab | Reworked: the 2 s open-files poll is a `PollingScheduler` job (`TabsController.startWatchingOpenFiles`); `BackgroundFileScans` holds the off-main reads for it. How much of the poll still runs on main was not traced |
| 9 | `debugLog` and the Insight diag log append synchronously | Fixed: `debugLog` forwards to `AppLog.workspace.debug`; `WebViewBridge.logInsightDiag` no longer writes a file (it logs through `AppLog.insight` in a Debug build and deletes an old `/tmp/markview-insight-diag.log`) |

Still on the main thread by reading: `NSAlert.runModal` / `NSOpenPanel.runModal` (welcome screen, file tree, close folder, remove
metadata), `FileTransfer` copies and moves, and `FilterSearch.scoreFiles` (a caller must call it off the main thread).

## 6. Lifecycle and cancellation gaps

| Gap (2.17.0) | Status at `ac3001ba` |
|---|---|
| `openFolder` tasks are never cancelled | Fixed: stored in the window's `TaskBag` under `openFolder`; `beginOpening` and `taskBag.cancelAll()` cancel the previous folder's work |
| `ArchitectureStore.reset()` does not cancel a running scan or clear `busy` | Fixed (R11 of the risks register: it cancels the scan, analysis and refresh tasks and moves a run token) |
| Explain and rate tasks are not stored | Not re-checked |
| Insight `retrySection` and the archive export run outside `activeTask` | Not re-checked; Insight work now starts in `InsightCoordinator`, which holds the window's task bag |
| `TerminalSession.terminate()` leaves zombies | Fixed by reading: `terminate()` calls `TerminalChildProcess.stopAndReap`, which calls `waitpid` |
| A new 1 s `Timer` per window `onAppear` | Fixed: one app-wide `PollingScheduler` job (`FinderOpenRequests`) |
| `PDFExporter` keeps its off-screen view in statics | Not re-checked |
| `LifecycleLog` has no cross-process lock | Not re-checked |

## 7. Guidance for new code

- Put new blocking I/O behind `Task.detached` or an actor, and publish results on the main actor.
- Give every long-running `Task` an owner: store it in the window's `TaskBag` under a key (the next task of that key cancels the old
  one), or run it as a `PollingScheduler` job. A task that needs no owner carries a `// task: <reason>` comment; a new unowned
  site fails the `unowned-task` ratchet.
- For a child process use `Subprocess` and a `SubprocessSpec` (timeout, output cap); a `Process()` anywhere else fails lint.
- For an AI call use `AIOperation` (`CLICompletion.run` outside it fails lint).
- A new `@unchecked Sendable` or `nonisolated(unsafe)` needs a justification on the line (lint `unchecked-sendable`: 40 sites, each
  justified, at `ac3001ba`; the lint exits 0).
