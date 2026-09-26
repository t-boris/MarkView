# Risks and Tech Debt Register

These findings come from the 2026-09-26 documentation audit of `85b6f8d` (2.17.0). **None of them
are fixed by the doc set.** Each one needs its own reproduction, approval and fix (CLAUDE.md: no
quick fixes).

**Verification**: *code-checked* means the cited lines were re-read and match the description.
*audit* means a module analysis traced it statically, but it hasn't been re-checked or reproduced.
Nothing here has been reproduced at runtime.

## 1. Correctness and data loss (fix first)

| ID | Finding | Evidence | Verification | Module |
|---|---|---|---|---|
| R1 | The editor's `init()` never runs and `ready` never reaches Swift. `markview-d3-mermaid.js` references `init` before `markview-init.js` (loaded after it) defines it, which throws a ReferenceError. Startup only works because `didFinish` does the same job | `markview-d3-mermaid.js:393-397`, `markview-init.js:62`, `index.html:1592-1593` | code-checked | [editor](./modules/editor-and-bridge.md) |
| R2 | Suspected file corruption: opening Markdown with relative images inlines them as base64. The render then posts that text back as tab content, so saving may write data URIs into the file | `EditorView.swift:370-373`, `markview-render.js:205`, `WorkspaceManager.swift:2748,2763-2768` | audit, **reproduce first** | editor |
| R3 | WYSIWYG edits are silently not saved when offline: Turndown loads from jsDelivr | `index.html:1539-1544`, `markview-edit.js:130-131` | code-checked (CDN tags) | editor |
| R4 | `ImageViewerView` requires `@EnvironmentObject WorkspaceManager`, but `ContentView` doesn't inject it, so a drop or "Source" on an image tab likely crashes | `ImageViewerView.swift:10`, `ContentView.swift:63` | code-checked | [app-shell](./modules/app-shell-and-workspace.md) |
| R5 | `git push`/`pull` treat `fatal:` failures as success: they only check for "rejected"/"error". Commit failures are ignored | `GitClient.swift:155-178` | code-checked | [git](./modules/git-github-terminal-lifecycle-usage.md) |
| R6 | "Save" in the close-tab prompt removes the tab even if the write failed; `saveFile` only logs | `WorkspaceManager.swift:1540-1616,2742-2756` | audit | app-shell |
| R7 | Opening another folder drops modified tabs without a prompt. Close Others/Right/All skip the prompt and leave shells running | `WorkspaceManager.swift:454,1619-1631` | audit | app-shell |
| R8 | Insight `retrySection` output is dropped: `appendSectionDelta` accepts only `.streamingContent`, but the node stays `.ready` | `InsightSession.swift:408,1330-1335` | code-checked (guard) | [semantic](./modules/semantic-index-and-insight.md) |
| R9 | The semantic index goes stale: deleted files are never removed; symbols and relations for changed files pile up; two docId schemes collide (`IncrementalCompiler` uses the bare file name) | see module | audit | semantic |
| R10 | Feature workflow: a duplicate epic is filed on retry, a bug-ID race has no overwrite guard, and non-ASCII titles produce `feature` / `BUG-nnn-.md` slugs | see module | audit | [feature](./modules/feature-workflow.md) |
| R11 | `ArchitectureStore.reset()` doesn't cancel a scan or clear `busy`, so a mid-scan workspace switch can commit old results and silently refuse the new scan | see module | audit | [X-Ray](./modules/architecture-and-xray.md) |

## 2. Security

S1–S14 are in [security §3](./security.md#3-known-weaknesses). Highest priority:

| ID | Finding | Verification |
|---|---|---|
| S1 | Document HTML runs in the bridge-owning page (`html: true`, inline-script CSP) | code-checked (`markview-state.js:53`) |
| S2 | Insight iframe gets `allow-same-origin` at runtime | code-checked (`markview-insight-handlers.js:132`) |
| S4 | AI terminal runs `claude --dangerously-skip-permissions` while untrusted GitHub text is pasted in | code-checked (`WorkspaceManager.swift:3100`) |
| S5 | OpenAI key in plaintext UserDefaults | audit |
| S7 | "Open in Terminal.app" AppleScript command injection through folder names | audit |

## 3. Concurrency and performance

See [concurrency §4–5](./concurrency.md#4-known-main-thread-hazards). Top items:

- All SQLite on main, with `busy_timeout` 5 s against the indexer process.
- `git show` with `waitUntilExit` on main (`ArchitectureStore.prFileURL`).
- `InsightArchiveExporter` never reads zip's stdout pipe, so it can deadlock.
- `TerminalSession.terminate()` leaves zombie children: it cancels the exit source, whose handler
  is the only `waitpid` call (`TerminalSession.swift:264,305-312`, code-checked).
- A new 1 s timer per window appearance, never invalidated.

## 4. Integration policy drift

| Finding | Notes |
|---|---|
| Terminal PR picker runs `gh pr list` even when GitHub is disabled (`TerminalView.swift:342-346`) | Violates "silent when off" |
| Agent-usage polling calls vendor endpoints by default | Accepted decision (DEC-005/DEC-012), but inconsistent with the GitHub opt-in model |
| CDN scripts (d3, dagre, turndown, gfm plugin) | Violates CLAUDE.md "never load from a CDN". Vendor them through `tools/web-vendor` |
| Mermaid 10.6.1, KaTeX 0.16.9, Prism 1.29.0 have published CVEs | `vendor/MANIFEST.txt` assumes `html:false`, which is no longer true |

## 5. Dead code and structural debt

- **Dead code**:
  - `MarkViewApplication` (`Info.plist` uses `NSApplication`), `MarkdownDocument`,
    `MarkViewApp.openFolder`/`newWindow`/`pendingFolderURL`
  - `EmbeddingClient`, with no callers; the `cache/embeddings` folder is never written
  - About 20 never-populated tables and 17 unused DB helpers; the `SemanticModel.swift` stub
  - `BridgeMessage`/`AnyCodable`, the `textChanged` message, and the `requestHTML` /
    `preparePrintLayout` / `restoreEditLayout` commands
  - `IncrementalCompiler` / `DependencyGraphScheduler`, which are mostly vestigial
  - `FileNode.children`, which is never rendered
- **Oversized types**: `WorkspaceManager` (3766 lines: tabs, bridge dispatch, translation, Insight
  export, GitHub glue) and `ArchitectureStore` (3136 lines; ~1350 are PR review, a natural split).
- **Duplicated model and key plumbing** across three settings views, so adding an AI tool touches
  all of them.
- A hard-coded Russian UI string in Swift (`WorkspaceManager.swift:1661`), against the English-only
  rule.

## 6. Build, release, docs

- `tools/importance-check.sh` is broken: it reads the deleted `AIConsoleEngine.swift` and uses a
  stale `ImportanceRater.request` signature.
- `project.yml` and the checked-in pbxproj disagree on the resources phase. Diff them after any
  `xcodegen generate`.
- Four stale scaffold docs ship inside the app bundle: `MarkView/BUILD_NOTES.md`, `MANIFEST.md`,
  `FILES_CREATED.txt`, `README.md`.
- CI replaces the `latest` release with an ad-hoc-signed zip on every push to main, and runs no
  tests.
- `install.sh` runs `pkill -9 MarkView`. See the memory rule: never kill the running app.
- Stale statements are in `QUICKSTART.md`, `EDITOR_IMPLEMENTATION.md`, `README.md:162-175`, the
  `CLAUDE.md` web-vendor line (omits xterm.js) and `tasks/lessons.md:173-175`. Full table:
  [build-release-testing §13](./modules/build-release-testing.md).

## 7. Suggested order of work

1. R2 (reproduce), R4 and R5: user-visible data integrity.
2. S1/S2/S3: one sanitisation decision for rendered HTML, which needs architecture approval.
3. R3 plus the CDN items: vendor d3, dagre and turndown.
4. R1, R6, R7, R8.
5. Main-thread SQLite: move `SemanticDatabase` to a dedicated actor (architecture change).
6. Dead-code removal and splitting `WorkspaceManager` / `ArchitectureStore`.
