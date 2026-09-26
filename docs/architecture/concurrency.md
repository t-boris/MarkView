# Concurrency Model

## 1. Rules (from CLAUDE.md)

- UI state is mutated only on `@MainActor`.
- File, database, network and child-process work runs off the main thread.
- Never call `Process.waitUntilExit()` on the main thread. Drain pipes before or while waiting.
- For a hang, run `/usr/bin/sample <pid> 3` and inspect thread 0 ([runbook](./operations-runbook.md)).

## 2. Actual isolation map

| Component | Isolation | Off-main work |
|---|---|---|
| `WorkspaceManager`, `ArchitectureStore`, `FeatureStore`, `FeatureAssistant`, `InsightSession`, `CodeExplainStore`, `WhisperClient`, `DictationController`, `GitHubStore`, `AgentUsageTracker` | `@MainActor ObservableObject` | `Task.detached` for tree builds, scans and parsing |
| `SemanticDatabase` | `@MainActor` (**all SQL runs on main**) | none; `busy_timeout=5000` against the indexer child process |
| `ArchitectureScanner`, `XRayDigest/Cluster/Content/Search` | not isolated, pure | runs detached |
| `CLICompletion` `Invocation` | own queue; callbacks on background threads | stdout via `readabilityHandler`, stdin written on a global queue |
| `TerminalSession` | main plus `DispatchSource` read on the PTY fd | `forkpty`, non-blocking writes |
| Structural indexer | **separate process** (`--dde-index`) | stderr streamed, never `waitUntilExit` |
| `EditorView.Coordinator`, `WebViewBridge` | not annotated; hops with `Task { @MainActor }` | none |

## 3. Process-spawning patterns

| Pattern | Used by | Status |
|---|---|---|
| `readabilityHandler` + `terminationHandler`, timeout → SIGTERM | `CLICompletion`, indexer | Good, but there is no SIGKILL escalation, so a CLI that ignores SIGTERM hangs the request |
| `waitUntilExit` on a background thread | `CLIToolLocator.run` (polls with `usleep`), `ArchitectureScanner.runTool` | Acceptable off main; `runTool` has no timeout |
| `waitUntilExit` **on main** | `ArchitectureStore.prFileURL` (`git show`) | Violates the rule |
| Stdout pipe never read | `InsightArchiveExporter` (`zip -r`) | Can deadlock when the pipe fills; `terminationHandler` is set after `run()` |

## 4. Known main-thread hazards

These are ranked by likely user impact. All come from code reading; confirm with `sample` before
fixing.

1. Every SQL statement runs on main, including X-Ray commits that delete and reinsert the whole
   architecture. A write can wait up to 5 s on `busy_timeout` while the indexer writes.
2. `GraphRAG` and Insight prompt builders read whole files with `String(contentsOf:)` on main;
   `InsightCache.init` copies the whole vendor tree synchronously.
3. `EditorView` reads and base64-encodes every referenced image on each Markdown load.
4. `FeatureStore` writes and reloads on main: a 3 s poll walks all feature and bug trees,
   consolidation writes hundreds of files, and cleanup moves files to the Trash synchronously.
5. `hasMarkdownFiles` walks the whole folder recursively while the AI Tools menu renders;
   `FileTreeView` re-lists the directory on every body evaluation; `GraphCreatorSheet` walks the
   workspace several times per render.
6. `WhisperClient.transcribe` builds recordings of up to ~19 MB into an upload body on main.
7. `prFileNotes` builds an LCS table of up to 8 million cells on main.
8. A 2 s timer re-reads every open tab's attributes and contents
   (`WorkspaceManager.swift:3483-3506`).
9. `debugLog` and the Insight diag log do synchronous file appends per call or per bridge message.

## 5. Lifecycle and cancellation gaps

- `openFolder` tasks are never cancelled, so opening two folders quickly can mix their state.
  `ArchitectureStore.reset()` doesn't cancel a running scan or clear `busy`.
- Explain and rate tasks aren't stored, so results from the previous folder can land in the new
  one.
- Insight `retrySection` and the archive export run outside `activeTask`, so tab close doesn't
  cancel them.
- `TerminalSession.terminate()` cancels the exit source, whose handler is the only `waitpid` call,
  which leaves zombies.
  The PTY write stops at the first `EAGAIN`, which truncates large pastes.
- A new 1 s `Timer` starts on every window `onAppear` and is never invalidated.
- `PDFExporter` keeps its off-screen view in statics, so a second export drops the first.
- `LifecycleLog` has no cross-process lock, so two running app instances both record events.

## 6. Guidance for new code

- Put new blocking I/O behind `Task.detached` or an actor, and publish results with
  `await MainActor.run`.
- Store every long-running `Task` and cancel it from `reset()`, tab close and folder switch.
- For subprocesses, reuse `CLICompletion`'s pattern (drain → terminate → finish) rather than
  writing a new one.
- A future `SemanticDatabase` refactor should move it to its own actor or serial queue. That is an
  architecture change, so get approval first.
