# Risks and Tech Debt Register

These findings come from the 2026-09-26 documentation audit of `85b6f8d` (2.17.0). The doc set does not fix any of them. Each one
needs its own reproduction, approval and fix (CLAUDE.md: no quick fixes).

**Status column (2026-11-15).** Each finding was looked at again in the code at `ac3001ba`: *fixed* means the cited problem is gone
(the check is named); *open* means the code still shows it by reading; *not re-checked* means the 2026-09 text stands unverified.
Nothing was reproduced at runtime. The register is a historical audit record plus these status marks: the Evidence and
Verification columns still describe the 2.17.0 audit.

**Verification**: *code-checked* means the cited lines were re-read and match the description.
*audit* means a module analysis traced it statically, but it hasn't been re-checked or reproduced.
Nothing here has been reproduced at runtime.

## 1. Correctness and data loss (fix first)

| ID | Finding | Evidence | Verification | Module | Status at `ac3001ba` |
|---|---|---|---|---|---|
| R1 | The editor's `init()` never runs and `ready` never reaches Swift. `markview-d3-mermaid.js` references `init` before `markview-init.js` (loaded after it) defines it, which throws a ReferenceError. Startup only works because `didFinish` does the same job | `markview-d3-mermaid.js`, `markview-init.js`, `index.html` | code-checked | [editor](./modules/editor-and-bridge.md) | not re-checked (`markview-d3-mermaid.js` and `markview-init.js` still exist) |
| R2 | Suspected file corruption: opening Markdown with relative images inlines them as base64. The render then posts that text back as tab content, so saving may write data URIs into the file | `EditorView.swift`, `markview-render.js`, `WorkspaceManager.swift` | audit, **reproduce first** | editor | not re-checked |
| R3 | WYSIWYG edits are silently not saved when offline: Turndown loads from jsDelivr | `index.html`, `markview-edit.js` | code-checked (CDN tags) | editor | fixed: Turndown is vendored (`vendor/js/turndown.min.js`) and `index.html` has no CDN reference |
| R4 | `ImageViewerView` requires `@EnvironmentObject WorkspaceManager`, but `ContentView` doesn't inject it, so a drop or "Source" on an image tab likely crashes | `ImageViewerView.swift`, `ContentView.swift` | code-checked | [app-shell](./modules/app-shell-and-workspace.md) | fixed: `ContentView` injects `workspaceManager` into `ImageViewerView` |
| R5 | `git push`/`pull` treat `fatal:` failures as success: they only check for "rejected"/"error". Commit failures are ignored | `GitClient.swift` | code-checked | [git](./modules/git-github-terminal-lifecycle-usage.md) | not re-checked (`GitClient.swift` was rewritten since) |
| R6 | "Save" in the close-tab prompt removes the tab even if the write failed; `saveFile` only logs | `WorkspaceManager.swift` | audit | app-shell | open: `TabsController.closeTab` removes the tab after `saveFile` even when the write failed (`saveFile` only sets `lastSaveError`) |
| R7 | Opening another folder drops modified tabs without a prompt. Close Others/Right/All skip the prompt and leave shells running | `WorkspaceManager.swift` | audit | app-shell | partly fixed: `closeDocuments` asks once and refuses on a failed save (`resolveUnsavedChanges`); `closeAllTabs` and `WorkspaceManager.openFolder` (`tabs.reset()`) have no unsaved-changes check at that level (callers not traced) |
| R8 | Insight `retrySection` output is dropped: `appendSectionDelta` accepts only `.streamingContent`, but the node stays `.ready` | `InsightSession.swift` | code-checked (guard) | [semantic](./modules/semantic-index-and-insight.md) | open: `retrySection` leaves the node `.ready` and `appendSectionDelta` needs `.streamingContent` |
| R9 | The semantic index goes stale: deleted files are never removed; symbols and relations for changed files pile up; two docId schemes collide (`IncrementalCompiler` uses the bare file name) | see module | audit | semantic | partly fixed: `IncrementalCompiler` is deleted, so the two docId schemes no longer collide; deleted files still stay in the index and symbols of changed files still pile up |
| R10 | Feature workflow: a duplicate epic is filed on retry, a bug-ID race has no overwrite guard, and non-ASCII titles produce `feature` / `BUG-nnn-.md` slugs | see module | audit | [feature](./modules/feature-workflow.md) | not re-checked |
| R11 | Resolved with automatic-code-architecture: `ArchitectureStore.reset()` cancels the scan, analysis and refresh tasks, clears `busy` and moves the run token so a cancelled run's cleanup cannot touch the next run; scans and analyses commit nothing once cancelled or moved to another root | see module | code-checked (run token) | [X-Ray](./modules/architecture-and-xray.md) | fixed (as stated) |

## 2. Security

S1–S14 are in [security §3](./security.md#3-known-weaknesses). Highest priority:

| ID | Finding | Verification | Status at `ac3001ba` |
|---|---|---|---|
| S1 | Document HTML runs in the bridge-owning page (`html: true`, inline-script CSP) | code-checked (`markview-state.js`) | partly fixed: markdown output now goes through `mvKit.sanitizeHtml(html, 'markdown')` (`markview-render.js`); `markdownit` still has `html: true` |
| S2 | Insight iframe gets `allow-same-origin` at runtime | code-checked (`markview-insight-handlers.js`) | fixed: the frame is `sandbox="allow-scripts"` with a nonce CSP (`AR-02`) |
| S4 | AI terminal runs `claude --dangerously-skip-permissions` while untrusted GitHub text is pasted in | code-checked (`WorkspaceManager.swift`) | open: `ClaudeProvider` and `AntigravityProvider` still pass `--dangerously-skip-permissions` for full access |
| S5 | OpenAI key in plaintext UserDefaults | audit | fixed: the key is in the Keychain (`AR-10`) |
| S7 | "Open in Terminal.app" AppleScript command injection through folder names | audit | not reproduced: no `NSAppleScript` call is left in `MarkView/` (login helpers write a `.command` file instead) |

## 3. Concurrency and performance

See [concurrency §4–5](./concurrency.md#4-known-main-thread-hazards). Top items:

- All SQLite on main, with `busy_timeout` 5 s against the indexer process. **Fixed**: every call is on the `SemanticDatabase` actor (`AR-37`).
- `git show` with `waitUntilExit` on main (`ArchitectureStore.prFileURL`). **Fixed**: lint `process` counts 0 `Process()` outside `Subprocess`.
- `InsightArchiveExporter` never reads zip's stdout pipe, so it can deadlock. **Fixed**: it runs through `Subprocess.run`.
- `TerminalSession.terminate()` leaves zombie children: it cancels the exit source, whose handler
  is the only `waitpid` call (`TerminalSession.swift`, code-checked). **Not re-checked.**
- A new 1 s timer per window appearance, never invalidated. **Fixed**: no `Timer` is left (`tools/lint/task-ownership.sh`: 0), polls are jobs of `PollingScheduler`.

## 4. Integration policy drift

| Finding | Notes |
|---|---|
| Terminal PR picker runs `gh pr list` even when GitHub is disabled (`TerminalView.swift`) | Violates "silent when off". Not re-checked |
| Agent-usage polling calls vendor endpoints by default | Accepted decision (DEC-005/DEC-012), but inconsistent with the GitHub opt-in model |
| CDN scripts (d3, dagre, turndown, gfm plugin) | Violates CLAUDE.md "never load from a CDN". **Fixed**: `index.html` has no CDN reference and the libraries are under `vendor/js` |
| Mermaid 10.6.1, KaTeX 0.16.9, Prism 1.29.0 have published CVEs | `vendor/MANIFEST.txt` assumes `html:false`, which is no longer true. Not re-checked |

## 5. Dead code and structural debt

Status marks as in the intro (`ac3001ba`).

- **Dead code**:
  - `MarkViewApplication` (`Info.plist` uses `NSApplication`), `MarkdownDocument`,
    `MarkViewApp.openFolder`/`newWindow`/`pendingFolderURL`. *`MarkViewApplication` and `MarkdownDocument` still exist; the rest not re-checked.*
  - `EmbeddingClient`, with no callers; the `cache/embeddings` folder is never written. *Partly: nothing creates an `EmbeddingClient` any
    more, only its key storage is used (by `DDESettingsView`); the folder is still created empty by `ProjectContext.openDatabase`.*
  - About 20 never-populated tables and 17 unused DB helpers; the `SemanticModel.swift` stub. *Tables: 18 of 35 have no writer
    (see the Semantic doc §10); the helpers and the stub are deleted.*
  - `BridgeMessage`/`AnyCodable`, the `textChanged` message, and the `requestHTML` /
    `preparePrintLayout` / `restoreEditLayout` commands. *`BridgeMessage` and `AnyCodable` exist and are used by the typed bridge; the rest not re-checked.*
  - `IncrementalCompiler` / `DependencyGraphScheduler`, which are mostly vestigial. *Deleted.*
  - `FileNode.children`, which is never rendered. *Not re-checked (`FileNode.swift` was rewritten).*
- **Oversized types**: `WorkspaceManager` (3766 lines: tabs, bridge dispatch, translation, Insight
  export, GitHub glue) and `ArchitectureStore` (3136 lines; ~1350 are PR review, a natural split). *`WorkspaceManager.swift` is 730
  lines (lint `file-size`: 0 files over the limit); `ArchitectureStore.swift` is 1889 lines.*
- **Duplicated model and key plumbing** across three settings views, so adding an AI tool touches
  all of them. *Not re-checked; "How to Add" in `CLAUDE.md` lists two places for a new assistant.*
- A hard-coded Russian UI string in Swift (`WorkspaceManager.swift`), against the English-only
  rule. *Not re-checked; `WorkspaceManager.swift` has no Cyrillic text now.*

## 6. Build, release, docs

- Obsolete docs and scaffolding (the importance-check script, the XcodeGen configuration, the setup and install scripts, `EditorWeb/`, the quick-start and editor-implementation notes, and bundled scaffold files) were removed in 6.26.0.
- Unified CI runs via `.github/workflows/ci.yml` (`Packages/MarkViewCore` `swift test`, `./tools/tests/run.sh --tier pure`, and cached Debug `xcodebuild`). Note `release.sh` handles signed DMG publishing cleanly from a clean `origin/main` checkout.

## 7. Suggested order of work

Order proposed in the 2026-09 audit. Since then item 3 (R3 and the CDN items) and item 5 (the `SemanticDatabase` actor) are done, and R4 is fixed.

1. R2 (reproduce), R4 and R5: user-visible data integrity.
2. S1/S2/S3: one sanitisation decision for rendered HTML, which needs architecture approval.
3. R3 plus the CDN items: vendor d3, dagre and turndown.
4. R1, R6, R7, R8.
5. Main-thread SQLite: move `SemanticDatabase` to a dedicated actor (architecture change).
6. Dead-code removal and splitting `WorkspaceManager` / `ArchitectureStore`.
