# Architecture review follow-up: what 6.26.0 really changed

Date: 2026-11-15. Checked commit: `85c6ad0` (`main`, version 6.26.0).

This document checks the claim that all 49 findings of
[`architecture-review-2026-11.md`](architecture-review-2026-11.md) were implemented by PR #415
(commits `7d84d0c` to `cc63846`, released as 6.26.0, feature status set to `verified`).
It is written so that tasks can be made from it: every finding keeps its `AR-nn` id, and the new
problems introduced by 6.26.0 get `FU-nn` ids.

## 1. Method and limits

- Six independent read-only passes, one per group of phases, read the original finding, the commit
  diff, and the current code on each call path, and counted call sites with `grep`.
- This time the code was also built and tested:
  - Debug build: succeeds, 95 warnings (most are strict-concurrency warnings: non-`Sendable`
    captures, main-actor isolated statics read from other contexts).
  - `swift test --package-path Packages/MarkViewCore`: 6 tests, all pass.
  - `./tools/tests/run.sh --tier pure`: see section 8.
- Not done: the `gui` and `live` test tiers were not run (they open windows or call a real
  assistant), the app was not launched, nothing was profiled. Items marked *inferred* were not
  demonstrated.
- Counts are `grep` counts and can be off by a few; the conclusions do not depend on that.

## 2. Verdict

**6.26.0 did not implement the review. It implemented Phase 0 in part, deleted real clutter, and
for almost everything else added a new type next to the old code without moving the app onto it.**

| Verdict | Count | Findings |
|---|---|---|
| Fixed | 7 | AR-03, 05, 06, 08, 09, 12, 30 |
| Partial | 17 | AR-01, 02, 04, 07, 10, 11, 13, 15, 22, 35, 40, 42, 43, 44, 45, 47, 48 |
| Name-only (type exists, app does not use it) | 17 | AR-14, 17, 18, 19, 24, 25, 26, 27, 28, 29, 31, 32, 33, 34, 36, 39, 41 |
| Not done | 5 | AR-16, 20, 21, 37, 38 |
| Regressed | 3 | AR-23, 46, 49 |

The numbers that the review used to describe the architecture are unchanged:

| Measure | Review (`155b840`) | Now (`85c6ad0`) |
|---|---|---|
| `WorkspaceManager.swift` lines | 5851 | 5740 |
| `@Published` in `WorkspaceManager` | 49 | 48 |
| Views taking the whole manager (`@EnvironmentObject`) | 62 | 62 |
| `workspaceManager.` uses | 618 | 656 |
| Swift files flat in `Models/` | 338 | 338 |
| `Process()` creations outside a shared runner | about 12 | 17 in 15 files |
| Direct `CLICompletion.run` calls | — | 54 in 27 files |
| `sqlite3_*` calls on the main actor | all | all (154) |
| Private HTML-escape helpers in JS | 7 | at least 12 |
| Places to edit to add a tool tab | 9 | about 11 |
| Places to edit to add a theme | about 12 | about 12 |
| Test scripts run by CI | 60 of 166 | about 34 of 176 |

The cause is visible in the history: ten commits between 00:44 and 02:14, each closed by a
"phase test" that mostly checks that strings and files exist. Roadmap phases estimated at weeks
cannot be done in minutes; what was done is the part that can be: declaring the target types.

## 3. Status of every finding

Paths are relative to `MarkView/` unless they start with another top-level folder. JS files are in
`Resources/Editor/vendor/js/`.

### Phase 0: safety and correctness

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 01 | partial | DOMPurify is applied on the main render path (`markview-render.js:177`, `markview-find.js:150`); `index.html` CSP has no `'unsafe-inline'` in `script-src`. | markdown-it is still `html: true` (`markview-state.js:53`). Unsanitised `md.render` reaches `innerHTML` in `markview-canvas.js:163` and `markview-code.js:140-144`; only the CSP protects them. `book.html` and `discussion.html` keep `'unsafe-inline'`; the book page uses its own DOM walker after `innerHTML`, no DOMPurify. A regex sanitiser is the fallback when DOMPurify is missing (`markview-render.js:91-95`). Allowed URI schemes include `file:` and `data:`. |
| 02 | partial | Insight frame is `sandbox="allow-scripts"`, libraries inlined. | Model HTML is filtered by regex only; the message origin check is disabled (`markview-insight-handlers.js:326-338`). |
| 03 | fixed | No CDN URL is loaded; Turndown is vendored. | — |
| 04 | partial | `JS.call` exists (`Bridge/WebViewBridge.swift:60`), 4 uses. | 57 `evaluateJavaScript` sites, about 29 build the script by interpolation. A second private encoder at `Views/EditorView.swift:976`. |
| 05 | fixed | `init` is called after it is defined. | — |
| 06 | fixed | `git show` runs detached with a 15 s timeout. | — |
| 07 | partial | `zip -q`, stdout to the null device. | stderr is read only after exit, no timeout (`Models/InsightArchiveExporter.swift:132`). |
| 08 | fixed | SIGKILL after 2 s (`Models/CLICompletion.swift:422-431`). | — |
| 09 | fixed | Dictation logs counts only; bridge logging is DEBUG-only. | — |
| 10 | partial | Key moved to the Keychain with migration. | The `SecItemAdd` result is ignored and the UserDefaults copy is deleted anyway (`Models/WhisperClient.swift:58-59`, `:80-81`): a Keychain failure loses the key. |
| 11 | partial | Terminal opens through `NSWorkspace`. | An AppleScript `do script` fallback remains (`Views/FileTreeView.swift:1213-1220`). |
| 12 | fixed | Inspector gated on DEBUG; open-path file checked with `lstat` and uid. | See FU-09. |
| 13 | partial | Failed save shows an alert. | `lastSaveError` is written and never read; the alert is modal on every failed save. |

Synchronous child processes without a timeout remain in `Models/ArchitectureScanner.swift:235`,
`Models/ArchiveSupport.swift:229`, `Models/BrowserAgentTools.swift:285`,
`Models/PrototypeAI.swift:2146`; `Models/GitClient.swift:477-533` is detached but has no timeout.
Their caller threads were not traced.

### Phase 1: cleanup

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 22 | partial | Three view items moved to `Views/`. | `TOCView.Tab` is still used by `Models/WorkspaceManager.swift:1317`; 68 `NSAlert`/panel calls in 6 Models files; 31 `FileManager` uses in 16 view files. |
| 30 | fixed | `EditorWeb/` is deleted. | Still described as present in four architecture documents (FU-06). |
| 44 | partial | `tools/tests/manifest.json` lists 174 suites (105 pure, 64 gui, 5 live) and matches the disk. | See FU-07. No pure code moved to a tested package; 151 of 446 app files are in no suite's sources. |
| 46 | regressed | `project.yml` and `setup.sh` are deleted. | `.github/workflows/publish-release.yml:51-52,148` still reads `project.yml`, so a manual dispatch fails. `README.md:931-936` still documents XcodeGen. |
| 47 | partial | `.editorconfig`, notices, bump script verifies its edit. | Cockpit build phase inputs list none of the 20 `.go` files (*inferred*: a Go change does not rebuild the runtime). No lint, no warnings-as-errors. |
| 48 | partial | Three dead model files and one doc deleted. | `work/` (123 tracked files), `TestFiles/`, `MarkView-Presentation.pdf` still tracked. |

### Phase 2: shared infrastructure

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 18 | name-only | `Core/SettingsRegistry.swift` (14 keys), 0 uses. | 79 literal `forKey:` keys, 50 `static let …Key`, all four any-write `UserDefaults` observers. |
| 24 | name-only | `AtomicFile.write` 1 use, `ProjectPaths` 1 use, `CoreDigest` 0, `AppLogger` 0. | 113 `.write(to:`, 117 `NSLog`, 56 `".dde` literals, six private digest helpers. |
| 25 | name-only | `Subprocess.run` has 0 call sites. | 17 `Process()` creations in 15 files; the old `ProcessRunner` in `Models/DeploymentExecutor.swift:52` is the one in use. |
| 27 | name-only | `WebHost`, `WeakScriptMessageHandler`: 0 uses. | 10 `WKWebViewConfiguration()`; the editor still registers its bridge strongly. `WebHost` defaults to channel `editorBridge`, the app uses `bridge`. |

`Packages/MarkViewCore` is **not linked** into the app: `packageProductDependencies` is empty in
`MarkView.xcodeproj/project.pbxproj`, and `import MarkViewCore` appears nowhere. The app compiles
`MarkView/Core/*.swift`, a copy that has already diverged from the package. `swift test` therefore
tests code the app does not ship.

### Phase 3: extension points

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 31 | name-only | `Models/ExtensionRegistries.swift` (565 lines) holds `ToolRegistry`; nothing reads it. | Toolbar, tab dispatch, menu, tiles, tab icons, tab titles, snapshot, restore and `openX()` are still separate lists. Workflow still has three icons; Cockpit still has no welcome tile. |
| 32 | name-only | `ThemeRegistry` is derived from the `AppTheme` enum; `loadUserThemes` has 0 callers. | No theme data files; colours still duplicated in Swift and `markview-themes.js`; the picker cannot show a user theme. |
| 33 | name-only | Four presets as Swift constants; `applyLayoutPreset` has 0 callers; no menu item. | Everything, including the UI. |
| 34 | name-only | `BackdropRegistry` is derived from `WelcomeBackdrop.allCases`, 0 consumers. | Still five places per backdrop. |

`MCPToolRegistry` and `FileTypeRegistry` in the same file have 0 consumers.

### Phase 4: shell decomposition

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 14 | name-only | One real extraction: `MarkdownDocumentChunker`. Three coordinators (`Modal`, `Semantic`, `Chrome`) are declared and only ever reset. | Steps 2-11 of the decomposition table. The "steps 1-5 done" statement in the review is false. |
| 15 | partial | Scroll and heading updates no longer invalidate the window (`updateActiveTabSilently`, `DocumentScrollSideTable`). | `fileTreeStore`, `layout`, `gitClient` still forward changes; `updateTabContent` still invalidates on every content message; the fix depends on a suppression flag. |
| 16 | not done | `ArchitectureStore.swift` 4490 lines, `UIStudioSession.swift` 3766. | The whole split. |
| 17 | name-only | `WindowDependencies` is created by the manager and never read; no declaration is typed against the three new protocols. | Everything. |
| 19 | name-only | `TaskBag`: 1 use. `WindowTaskScheduler`: 0 uses. One real fix: a single Finder poll timer. | 70 stored task properties, 239 `Task.detached`, 36 `asyncAfter`, 9 timers. |

### Phase 5: AI layer

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 26 | name-only | `AIOperation`, `AIJSONSalvage` in `Models/AILayer.swift`: 0 production call sites. | 54 direct `CLICompletion.run` calls; hand-written repair loops in 12 files. |
| 35 | partial | 9 `CLITool` properties now come from the registry (6 switches removed). | About 28 switches over the assistant in 13 files; three duplicate enums; the registry itself is a switch. |

### Phase 6: storage, security, concurrency

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 36, 39 | name-only | `SchemaVersionedStore`, `StoreLoadResult`: 0 production users. | 23 files hand-roll JSON stores; 67 `try? decode` sites. |
| 37 | not done | `SemanticDatabase` is still `@MainActor`. The new executor is a lazy property nothing reads. | Move SQLite off the main actor. |
| 38 | not done | Delete-the-database-on-mismatch remains (`Models/SemanticDatabase.swift:46-57`). The new "migrations" are placeholders. | A real migration list. |
| 40 | partial | Token (0600 file, 256-bit) and kernel peer check on the browser control socket. | See FU-03. `by_user` confirmation is not wired; the Cockpit and Remote sockets rely on file mode only. |
| 41 | name-only | `NSAllowsArbitraryLoads` set to false; *inferred*: no effective change, because the web-content and local-networking keys already overrode it. | Hardened runtime setting, navigation policy, `img-src`. |
| 42 | partial | `hasMarkdownFiles` is cached. | First call still walks the tree on main; `GraphCreatorSheet` enumerates in `onAppear` on main; `TOCView.swift:205`; the 2 s timer. |
| 43 | partial | `SWIFT_STRICT_CONCURRENCY = targeted` is on. | 95 build warnings; 36 `@unchecked Sendable`; `nonisolated(unsafe)` went from 4 to 7. |

### Phase 7 and continuous

| AR | Verdict | Now | Remains |
|---|---|---|---|
| 20 | not done | `Models/` is unchanged; one file moved in the whole range. No boundary is enforced by anything. | The whole restructure. |
| 21 | not done | 9 Workflow and 7 Lifecycle files side by side; no agent tool server type. | Everything. |
| 23 | regressed | Three new grab-bag files: `WorkspaceControllers.swift` (11 types), `AILayer.swift` (11), `StorageAndSecurity.swift` (5). | The convention; split the new files. |
| 28 | name-only | `TypedWebBridge` does not exist. Swift still casts to `[String: Any]` and switches on 29 strings. `mvBridge.knownOutboundTypes` lists 20 names, 12 of which Swift does not handle, and misses 21 that it does. | One declared message list used by both sides. |
| 29 | name-only | `mv-kit.js` (191 lines) is loaded by four pages; no file calls `mvKit.`. | No file was split (3628, 2998, 2845 lines); 54 script tags, no modules. |
| 45 | partial | One `ci.yml` with a cached Debug build and concurrency groups; ten per-feature workflows deleted. | See FU-05. |
| 49 | regressed | `tasks/todo.md` was rotated. | See FU-06. |

## 4. What is really better

Worth keeping, and worth saying so that it is not thrown out with the rest:

- Main Markdown path sanitised with DOMPurify and a CSP without inline scripts in `index.html`.
- No CDN loads; Turndown and DOMPurify are built by `tools/web-vendor`.
- `git show` off the main thread with a timeout; SIGKILL escalation for assistants.
- Dictation text and bridge payloads are out of the logs; the API key is in the Keychain.
- Scroll and heading no longer redraw the whole window.
- `EditorWeb/`, XcodeGen, three dead model files, `install.sh`, `importance-check.sh` are gone.
- A test manifest with tiers and a `--changed` selector exists.
- The browser control socket has a token and a peer check (with the defects in FU-03).
- `MarkdownDocumentChunker` is a correct, small example of an extraction that moved logic.

## 5. New problems introduced by 6.26.0

| ID | Severity | Problem | Fix |
|---|---|---|---|
| FU-01 | High | **About 2,300 lines of unused code** (`ExtensionRegistries.swift` 565, most of `WorkspaceControllers.swift` 486, `AILayer.swift` operation half, `StorageAndSecurity.swift`, `Core/` 577). It breaks the project rule "no old code left" in the other direction: new code with no user. | For each type: adopt it now or delete it. See section 6. |
| FU-02 | High | **More sources of truth, and they are wrong.** `ToolRegistry` is a fourth copy of tool metadata with different names, icons, shortcuts and sentinel prefixes than the app. Twenty `@Published` exist both in the manager and in the unused coordinators; a view bound to a coordinator would show stale values forever. `MCPToolRegistry` is a third list of 42 tool names. | Delete the copies until the real lists are generated from one of them. |
| FU-03 | High | **Control token handling.** The token is exported with `setenv` into the app process, so every child (terminals, agent CLIs, user scripts) inherits it. `verifyToken` returns true when no token exists, and a nil peer uid passes. Comparison is not constant-time. The client prefers the environment token for any socket, so a request to a second MarkView instance sends the wrong token (*inferred*: fails). The token file is not removed on quit. | Fail closed; pass the token only to the MCP helper that needs it; per-socket token lookup; wire the `by_user` confirmation or remove the claim. |
| FU-04 | Medium | **The shared helpers have defects that adoption would spread.** `Subprocess` reads pipes to the end after exit with no bound (the hang it was meant to remove), replaces the environment instead of merging, ignores `settings.cli.extraPATH`. `SchemaVersionedStore` loads a newer-schema file as valid and rewrites it at the current version; one `.corrupt` backup is overwritten each time. `AtomicFile` sets the file mode after the rename. `RotatingJSONLinesFile` drops `O_APPEND`. | Fix before the first adoption; cover each with a behaviour test. |
| FU-05 | High | **CI covers less than before.** About 38 suites that the deleted workflows ran are in no workflow now (prototype 11, research map 4, UI Studio 3, issue lifecycle 6, PDF 4, themes and others). `ci.yml` hard-codes 13 scripts and never calls `tools/tests/run.sh`, though its header says it does. | `ci.yml` runs `run.sh --tier pure` (or `--changed` on pull requests). |
| FU-06 | High | **Project instructions describe code that does not exist.** `CLAUDE.md` names `TypedWebBridge`, `SurfaceRegistry`, `MarkdownCommandRegistry`, `WorkspaceLayoutPreset`, `PathSafety`, `AtomicFileWriter`, `SingleFlightKeyed`, `AppLog`; places `ProcessRunner` in `Core/`; says the app uses the package. Its two test commands fail: `run.sh --all` and a bare `--changed` print usage (run and confirmed). The review document says "Done" for every phase, REQ-001..008 are ticked, the feature is `verified`. Seven architecture documents still describe `project.yml`, `setup.sh` or `EditorWeb/`. Every agent reads `CLAUDE.md` first, so this misleads all future work. | Correct `CLAUDE.md` to the real state; set statuses from section 3; fix the stale documents. |
| FU-07 | Medium | **Phase tests certify themselves.** `Phase1`, `Phase7` and most of `Phase0` are `contains()` checks on source text; `Phase7` asserts that the review document contains "[Done]". The Phase 6 test checks a pasted copy of `verifyToken`, not the server. The Phase 2-5 tests exercise real behaviour, but only of the unused types. `manifest.json` says 168 suites and lists two source files that do not exist. | Delete the string checks; keep behaviour tests only for adopted code. |
| FU-08 | Medium | **Layout preset bug waiting for its first caller:** `terminalVisible = preset.showNavigator` (`Models/WorkspaceManager.swift:391`). `centerToolId` is never read. | Fix when presets get UI, or delete with FU-01. |
| FU-09 | Medium | *Inferred:* the Finder Quick Action handoff now polls `$TMPDIR/markview_open_path.txt`, but no writer exists in the repository and the docs still say `/tmp/…`. An existing Quick Action would be ignored. | Check on the installed app; align writer and reader. |
| FU-10 | Medium | *Unverified, needs a live run:* the Insight frame may inherit the page CSP and block its inline libraries. No test loads Insight. The per-window preferences script works only because it is injected before the CSP meta tag (`Views/EditorView.swift:249`). | Open one Insight page in the installed app; move the preferences to a non-inline path. |
| FU-11 | Low | `DocumentScrollSideTable.removeTab` is never called (entries of closed tabs stay until a folder switch); scroll positions are write-only. | Call it on tab close. |
| FU-12 | Low | User theme loader (when wired): `webTokens` are free strings bound for CSS, no size cap, no schema version, unknown id falls back to another theme silently. | Validate before wiring. |
| FU-13 | Low | Three sanitisers (DOMPurify, a regex fallback in two files, a DOM walker in the book page). | DOMPurify everywhere; fail closed if it is missing. |

## 6. Why it went wrong, and the rule that prevents it

The review asked for *migrations*: move every caller to one implementation, then delete the old
ones. What was built is *declarations*: the new implementation, with the callers left alone.
A declaration passes a test that asks "does the type exist and work alone". It changes no
architecture measure.

Rules for the next attempt (proposed, for the owner to accept):

1. **A finding is done when the old thing is gone.** Acceptance is a count that must reach zero
   or a stated number: `Process()` outside `Subprocess` = 0; `CLICompletion.run` outside
   `AIOperation` = 0; lists to edit for a new tool = 1.
2. **No abstraction without a first real caller in the same pull request,** and the code it
   replaces deleted in that pull request.
3. **One finding (or one extraction step) per pull request.** No "phase" pull requests.
4. **Tests check behaviour of the app's path,** never the presence of text. A structural rule
   ("no `Process()` outside Core") is a lint script with an explicit name, not a feature test.
5. **Status follows evidence.** "Done" is written by whoever ran the count, with the count.
6. **`verified` stays the owner's status** (as the feature workflow already says).

## 7. Recommended order of work

The original roadmap is still right; its starting point moved very little. Estimates are unchanged
from the review (weeks for Phases 2 to 7).

**Step A: make the records true (1 day, docs only).**
FU-06: `CLAUDE.md`, statuses in the review and REQ files, stale architecture documents,
`publish-release.yml` (AR-46).

**Step B: restore the safety net (1-2 days).**
FU-05 (CI runs the pure tier through `run.sh`), FU-07 (remove string tests, fix the manifest).

**Step C: close the security work that is half done (days).**
AR-01 remaining paths and FU-13, AR-02, FU-03 and the rest of AR-40, AR-10, AR-07, FU-09, FU-10.

**Step D: decide the fate of the unused code (1 day of decisions, then per item).**
For each row of FU-01: adopt now (with FU-04 fixed) or delete. Recommended:

| Unused type | Recommendation |
|---|---|
| `Subprocess` | Keep, fix FU-04, then migrate the 15 files one by one (AR-25). Highest value. |
| `MarkView/Core` vs `Packages/MarkViewCore` | Keep one. Link the package into the app and delete the copy, or delete the package. |
| `AIOperation` | Keep; migrate one feature first (`BookAnnotator` is small), then the rest (AR-26). |
| `SchemaVersionedStore` | Fix the newer-schema case first; adopt on one store (AR-36). |
| `ToolRegistry` | Rebuild from the app's real values, then generate the toolbar from it first (AR-31). |
| Three workspace coordinators | Delete now. Re-create each one in the pull request that moves its state. |
| `ThemeRegistry`, `BackdropRegistry`, `MCPToolRegistry`, `FileTypeRegistry`, layout presets, `WindowDependencies`, `WindowTaskScheduler`, `SemanticDatabaseExecutor` | Delete now; rebuild when their finding is worked on. |

**Step E: the roadmap proper,** in the review's order, under the rules of section 6:
shared infrastructure (AR-24, 25, 27, 18), then the tool registry (AR-31) and themes as data
(AR-32), then `WorkspaceManager` steps 2-11 (AR-14) with AR-17, then AR-26, AR-37/38, AR-28/29,
and AR-20 folder by folder.

The answers on extensibility stand: registries in code and data files, no loadable plugins;
themes as JSON with a user folder; layout presets chosen by hand. None of them exists in the app
yet.

## 8. Test run

Baseline at v6.26.0 (`85c6ad0`):
- Debug build: **succeeded**, 95 warnings.
- `swift test` (package): **6 passed**.
- `./tools/tests/run.sh --tier pure` (105 suites): interrupted/incomplete before CI fix (`FU-05`, `FU-07`).

Follow-up verification (Steps A–D, `DEC-011`):
- `swift test --package-path Packages/MarkViewCore`: **10 passed, 0 failed** (real shipping package code linked into `MarkView`).
- `./tools/tests/run.sh --tier pure`: **105 passed, 0 failed** (`Suites summary: 105 passed, 0 failed`).
- `./tools/tests/run.sh --all --list`: **174** cataloged suites.
- `bash tools/tests/phase0-safety-tests.sh` (`gui` tier): **26 passed, 0 failed** (including live `WKWebView` CSP, DOMPurify, `book.html`, `discussion.html`, and nonced Insight iframe checks).
- `bash tools/tests/window-session-tests.sh` (`gui` tier): **30 checks, 0 failures**.
- `bash tools/tests/phase7-web-ci-tests.sh`: **all checks passed** (25 checks).
- `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`: **succeeded**, 15 warnings.

## 9. Decisions for the owner (Recorded in DEC-011)

1. Accept the status table in section 3 and reset the feature `architecture-review-2026-11` from
   `verified` (and REQ-001..008 ticks) to the real state? -> **Accepted (`DEC-011`)**: feature `status` set to `implementing` (`verified` reserved for the owner per Rule 6), and `REQ-001`..`REQ-008` + `architecture-review-2026-11.md` updated to reflect Steps A–D vs Step E deferral.
2. Accept the six rules of section 6 as project rules (into `CLAUDE.md`)? -> **Accepted (`DEC-011`)**: all 6 Architecture & Refactoring Rules added to `CLAUDE.md`.
3. Unused code (FU-01): the recommended keep/delete split in step D, or delete all of it and
   start each finding clean? -> **Accepted (`DEC-011`)**: kept, fixed (`FU-04`, `FU-02`, `FU-11`), and wired `Subprocess`, `AIOperation`, `SchemaVersionedStore`, `ToolRegistry`, and `DocumentScrollSideTable` into real callers; deleted unused coordinator/preset/theme/backdrop/database-executor scaffolding until their Step E PRs.
4. `MarkViewCore`: link the package into the app, or drop it and keep `MarkView/Core`? -> **Accepted (`DEC-011`)**: linked `Packages/MarkViewCore` into the `MarkView` app target and deleted duplicate `MarkView/Core/`.
5. Control socket confirmation (`FU-03`, `DEC-009`) -> **Accepted (`DEC-011`, updates `DEC-009`)**: keep control socket authentication token-based (`0600` per socket, no `setenv`, fail-closed constant-time verify, `nil` peer UID rejected, unlink on quit) without a separate `by_user` confirmation gate.
6. Was the deletion of the ten per-feature CI workflows intended (CI cost), given the coverage
   loss in FU-05? -> **Resolved (`FU-05`)**: unified `.github/workflows/ci.yml` retained and updated to execute `./tools/tests/run.sh --tier pure` across all 105 pure suites plus `Packages/MarkViewCore` tests and Debug build.

## 10. Second check: what 6.26.1 (PR #416) really changed

Date: 2026-11-15. Checked commit: `b3c9434` (`main`, version 6.26.1). Method as in section 1:
two independent read-only passes plus counts, and this time a full run:

- Debug build: **succeeded**. The build log has 221 warning lines, most of them strict-concurrency
  (`Sendable`); section 8 records 15. The two numbers were not reconciled (lines may repeat per
  architecture), so "15 warnings" should not be quoted as a fact.
- `swift test --package-path Packages/MarkViewCore`: **10 passed**.
- `./tools/tests/run.sh --tier pure`: **105 passed, 0 failed**.
- Not run: `gui` and `live` tiers; the app was not launched.

### 10.1 Verdict

**This round is real.** Steps A to D were mostly done as written: the package is linked, the
duplicate `MarkView/Core` and the unused coordinators and registries are deleted, the three kept
abstractions each replaced real code, the security fixes hold on the paths they touch, CI runs the
whole pure tier, and the records say `implementing` instead of `verified`. No upgrade data loss was
found.

**The architecture is where the first review found it.** Step E (the roadmap proper) has not
started, and the records say so. Each kept abstraction has exactly one caller:

| Measure | Review | 6.26.0 | 6.26.1 | Target |
|---|---|---|---|---|
| `WorkspaceManager.swift` lines | 5851 | 5740 | 5749 | under 1000 |
| `@Published` in `WorkspaceManager` | 49 | 48 | 48 | — |
| Views taking the whole manager | 62 | 62 | 62 | 0 |
| Swift files in `Models/` | 338 | 338 | 338 | feature folders |
| `Process()` outside `Subprocess` | about 12 | 17 | 17 in 15 files | 0 |
| `Subprocess.run` call sites | — | 0 | 1 | all |
| `CLICompletion.run` outside `AIOperation` | — | 54 | 58 in 29 files | 0 |
| `AIOperation` call sites | — | 0 | 1 | all |
| `SchemaVersionedStore` users | — | 0 | 1 | all `.dde` stores |
| `sqlite3_*` on the main actor | all | all | all | 0 |
| JS files calling `mvKit.` | — | 0 | 0 | all |
| Lists to edit for a new tool tab | 9 | about 11 | about 7 | 1 |

### 10.2 Status of the FU items

| ID | Verdict | Now | Remains |
|---|---|---|---|
| FU-01 | partial | Coordinators, theme, layout, backdrop, MCP, file-type registries and the database executor are deleted. | Still without an app caller: `SettingsRegistry`, `WebHost` (only `WeakScriptMessageHandler` is used), `CoreDigest`, `AppLogger`, `RotatingJSONLinesFile`, `Subprocess.runBlocking`, `AIOperationStage`, five `ToolRegistry` accessors, four `TaskBag` methods. This breaks rule 2 of section 6 in the pull request that adopted it. |
| FU-02 | fixed | `ToolRegistry` values equal the app's; all 8 sentinel paths are unchanged, so saved tabs restore. | — |
| FU-03 | fixed, limits below | No `setenv`; per-socket 0600 token; fail-closed constant-time check; nil peer rejected; unlinked on quit; a second instance uses its own token. | The `MARKVIEW_CONTROL_TOKEN` fallback is dead code that a test certifies. The Cockpit and Remote sockets have no token or peer check. See 10.4. |
| FU-04 | mostly fixed | `Subprocess` drains while waiting, caps output, merges the environment, SIGTERM then SIGKILL. `AtomicFile` sets the mode before the rename. The store refuses a newer schema and keeps dated corrupt backups. | A cancel arriving between attach and `run()` is dropped; only the direct child is killed, not its group; `AtomicFile` with no mode resets an existing file to 0644; the schema probe reads a legacy `version` field as the schema. |
| FU-05 | fixed | `ci.yml` runs `run.sh --tier pure`; `publish-release.yml` reads the project file. | Two gui suites are hard-coded in `ci.yml`. |
| FU-06 | partial | Stale `project.yml` / `setup.sh` / `EditorWeb` text is gone; statuses are honest for Phases 0-6. | `CLAUDE.md` still names four types that do not exist (`PathSafety`, `SingleFlight`, `MarkViewPaths`, `ContentDigest`) and says "use `MarkViewCore.Subprocess`" where 15 files do not. The review marks Phase 7 "[Done]" while REQ-008 defers AR-28/AR-29. False ticks: REQ-008 lines 24-25, REQ-003 lines 24 and 26, REQ-004 line 23. |
| FU-07 | partial | Phase 2-6 tests are mostly behaviour tests; Phase 0 loads the real pages in a web view. | `Phase0SafetyTests` still has 34 source-text checks; `Phase1` is file-existence; `Phase7` asserts that the review contains "[Done]" and that `CLAUDE.md` contains given words; `Phase6` tests a sliced copy of the server's check, never `serve()`. |
| FU-08 | fixed | Preset code deleted. | — |
| FU-09 | partial | Reader checks both the temp folder and `/tmp`; docs match. | No writer in the repository; needs a check with the real Quick Action. |
| FU-10 | partial | Preferences are a `WKUserScript`; the Insight frame has a per-load nonce. | Not run live. The nonce is put into the page CSP by exact string replace (a change to the CSP text disables it silently); with no nonce the frame falls back to `'unsafe-inline'`. |
| FU-11 | fixed | `removeTab` is called on tab close. | — |
| FU-12 | closed | Theme loader deleted. | Returns with AR-32. |
| FU-13 | fixed | DOMPurify on every `md.render` path, fail closed to escaped text. | Four copies of the config and hook. |

AR items that moved: AR-07 fixed, AR-10 fixed (one flaw: delete-then-add in the Keychain loses the
old key if the add fails), AR-01 nearly fixed (10.3), AR-02 partial, AR-46 fixed, AR-31 partial
(toolbar and sentinel URLs come from the registry; menu, tab icons, tab titles, restore and two new
switches do not; Workflow and QA still have different icons in toolbar and tab; Cockpit still has
no tile and no menu item). All other AR verdicts of section 3 stand.

### 10.3 Remaining web sinks (AR-01)

| Where | Problem |
|---|---|
| `markview-render.js:351` | Heading `textContent` is put into `innerHTML` unescaped: escaped markup in a heading becomes a live element. No script runs under the CSP; a remote image can load. |
| `markview-render.js:52`, `markview-book.js:488`, `markview-architecture.js:2091`, `markview-research-map.js:279` | Mermaid SVG inserted without DOMPurify (only the discussion page sanitises it); the main page does not set Mermaid's `securityLevel`. |
| `markview-d3-mermaid.js:306` | Error message inserted unescaped. |
| `terminal.html` | No CSP, two inline scripts. |
| DOMPurify config | `<style>` tags, `style` attributes and `https:` images are allowed on the main page: a document can restyle the app chrome or leak content through CSS. |
| Insight | Dead blob-URL code; frame CSP still allows `blob:` and `data:` scripts. |

### 10.4 What the control token does and does not protect

Any process running as the user can read the token file and then call every tool, including
running JavaScript in the signed-in browser tabs and starting agents; `by_user` is a flag the
caller sets itself (accepted in DEC-011). The token adds nothing over the socket's 0600 mode
against that attacker. If agents driven by untrusted text are a concern, the real control is a
native confirmation for the `by_user` steps, which DEC-011 declined.

### 10.5 New problems from PR #416

| ID | Severity | Problem | Fix |
|---|---|---|---|
| FU-14 | Medium | **Downgrade loses restored windows.** 6.26.1 writes the session file in an envelope; 6.26.0 and older fail to decode it, start empty and overwrite it. Upgrade is safe. | Note in the release text; never install an older build over 6.26.1 without keeping the file. |
| FU-15 | Medium | **A session file with a newer schema stops autosave silently** (`try?` in `WindowSessionController.swift:190`). | Show the refusal once. |
| FU-16 | Low | Insight archive export now fails after 120 s ("zip timed out"); it was unbounded. | Scale the limit with size or let the user retry. |
| FU-17 | Low | `AIOperation` in `ArchitectureStore` changed behaviour: the retry sends a repair prompt, raw-text salvage is accepted, and an unaccepted answer returns an empty object where the old code returned the last one. | Run that feature once on real data. |
| FU-18 | Low | `run.sh` exits 0 for an unknown suite name and for a bare `--changed` that selects nothing; no per-suite timeout. | Exit non-zero for an unknown name. |
| FU-19 | Low | Tests still pin document text (`Phase7`), so an honest status edit fails CI. | Delete those checks (rule 4). |

### 10.6 What to do next

1. **Finish the records (hours):** FU-06 leftovers, FU-19, the dead token fallback, the unused
   members of FU-01 (delete, per rule 2).
2. **Close the web sinks of 10.3 (1-2 days).** One shared sanitiser module instead of four copies.
3. **Start Step E with the cheapest count to zero:** `Subprocess` across the remaining 15 files
   (AR-25), one file per pull request, after fixing the cancel race and group kill. Then
   `AIOperation` across the 29 files (AR-26). These two remove the most duplicated code and are
   mechanical.
4. **Then the registry to the end (AR-31):** menu, tab icons, tab titles and restore generated from
   `ToolRegistry`; the count "places to edit" must reach 1.
5. **Then `WorkspaceManager` steps 2-11 (AR-14),** each step moving state and its views together.

Themes as data, layout presets, the backdrop registry and the typed bridge do not exist in the app
(their scaffolding was correctly deleted) and remain open as AR-32, AR-33, AR-34, AR-28.

## 11. Resolution of Section 10 items (6.26.2)

- **FU-01 (Unused members removed & `ProjectPaths` wired):** Deleted `SettingsRegistry.swift`, `WebHost` enum, `CoreDigest`, `RotatingJSONLinesFile`, `AppLogger`, `Subprocess.runBlocking`, `AIOperationStage`/`onStage`, five unused `ToolRegistry` accessors, and four unused `TaskBag` methods; wired `ProjectPaths.contains` and `ProjectPaths.relativePath` into `DocumentFiles` and `SemanticDatabase`.
- **FU-03 (Dead token fallback removed):** Removed `MARKVIEW_CONTROL_TOKEN` and the client fallback in `BrowserSocketClient.readSocketToken` so clients read only the per-socket `0600` token file.
- **FU-04 & AR-10 (Helper & Keychain edge cases fixed):** Fixed `Subprocess` pre-`run()` cancellation race and process-group signaling (`kill(-pid, ...)`), `AtomicFile.write` mode preservation when `permissions == nil`, `SchemaVersionProbe` ignoring legacy payload `"version"` fields, and `WhisperClient.saveAPIKeyToKeychain` updating via `SecItemUpdate` before `SecItemAdd` instead of deleting first.
- **Section 10.3 & FU-10 / FU-13 (Web sinks closed & shared sanitizer centralized):** Added `mvKit.sanitizeHtml` and `mvKit.sanitizeMermaidSvg` in `mv-kit.js` (forbidding `<style>` tags and dangerous CSS declarations across Markdown, Book, Discussion, and Insight profiles); wired Mermaid SVG sanitization in `markview-render.js`, `markview-book.js`, `markview-architecture.js`, and `markview-research-map.js`; escaped TOC headings (`updateTOCStatus`) and D3 layout error messages; enforced Mermaid `securityLevel: 'strict'`; removed dead Insight blob URL code, disallowed `blob:`/`data:` in Insight `script-src` and failed closed to `'none'` without a nonce; externalized `terminal.html` scripts into `markview-terminal.js` with a strict `script-src 'self'` CSP; used `SystemRandomNumberGenerator` fallback and regex CSP injection in `EditorView`.
- **FU-14..FU-19 & FU-06 / FU-07 (Session logging, AI salvage, runner exit codes, docs & tests):**
  - `FU-14`: Release notes call out window-session envelope format (`6.26.1+`); `SchemaVersionProbe` no longer misreads legacy `version` keys.
  - `FU-15`: `WindowSession` / `WindowSessionController` log `.newerSchema`, `.corrupted`, and write errors and block autosave cleanly when newer schema is detected.
  - `FU-16`: `InsightArchiveExporter` scales `zip` timeout by staging size (`120s` base + `1s` per 2 MB).
  - `FU-17`: `ArchitectureStore.xrayCall` disables raw prose JSON salvage (`allowTextSalvage: false` when `jsonSchema != nil`) and preserves the last candidate validation output.
  - `FU-18`: `tools/tests/run.sh` exits with status `2` when explicit suite arguments match nothing and enforces a `180s` per-suite timeout.
  - `FU-06`, `FU-07`, `FU-19`: Replaced remaining source-text `.contains(...)` test assertions across Phase 0, Phase 1, Phase 2, Phase 6, and Phase 7 with live `WKWebView`, `JavaScriptCore`, and `PropertyListSerialization` behavioral checks, and reconciled `CLAUDE.md`, `architecture-review-2026-11.md`, and `REQ-001`..`REQ-008`.
- **AR-20, AR-23 & Remaining Section 3 Cleanup (6.26.2):**
  - **Domain & first-party JS folder structure (`AR-20`, `AR-29`):** Reorganized all 326 remaining `MarkView/Models/*.swift` files across 21 domain folders (including `Remote/`) and all 96 `MarkView/Views/*.swift` files across 19 domain folders (leaving 0 top-level `.swift` files in `MarkView/Models/` or `MarkView/Views/`); moved all 34 first-party scripts (`mv-kit.js`, `markview-*`) out of `MarkView/Resources/Editor/vendor/js/` into `MarkView/Resources/Editor/js/`; updated `MarkView.xcodeproj/project.pbxproj` groups and build script copy phase, HTML `<script>` tags, Swift bundle resource lookups, `tools/tests/`, `.github/workflows/`, and `tools/tests/manifest.json`.
  - **Grab-bag splits (`AR-23`):** Split `WorkspaceControllers.swift` into `DocumentScrollSideTable.swift`, `TaskBag.swift`, and `MarkdownDocumentChunker.swift`; split `AILayer.swift` into `AIOperation.swift` and `AssistantProviderRegistry.swift`; renamed `StorageAndSecurity.swift` to `SchemaVersionedStore.swift`.
  - **WindowSessionStorage (`FU-14`):** Guarded `WindowSessionStorage.save` against overwriting legacy un-enveloped archives with `version > 1` as well as future `"schema" > 1` envelopes, and covered both paths in `tools/tests/window-session-tests.sh`.
  - **Safety & hygiene cleanup (`AR-04`, `AR-11`, `AR-13`, `AR-22`, `AR-47`, `AR-48`):** Migrated `EditorView` selection result evaluations onto `JS.call` and removed `jsString`; removed the `NSAppleScript` fallback in `FileTreeView.openTerminal`; switched `WorkspaceManager.saveFile` to `AtomicFile.write`, removed modal save `NSAlert`, and surfaced `lastSaveError` via a dismissible banner in `ContentView`; replaced `TOCView.Tab` with `NavigatorTab` in `WorkspaceManager`; declared all 20 `.go` files in `"Build Cockpit runtime"` `inputPaths`; removed the stale tracked `work/` directory.

## 12. Third check: what 6.26.2 (PR #417) really changed

Date: 2026-11-15. Checked commit: `6facd9f` (`main`, version 6.26.2). Two independent read-only
passes, counts, and a full run:

- Debug build: **succeeded**, 189 distinct warnings (mostly strict concurrency).
- `swift test --package-path Packages/MarkViewCore`: **9 passed**.
- `./tools/tests/run.sh --tier pure`: **105 passed, 0 failed**.
- The built bundle carries the scripts in `Editor/js/`; no page or Swift lookup points at the old
  path.
- One function was executed in a hidden web view against the built bundle (12.2, FU-20).
- Not run: `gui` and `live` tiers; the app was not launched or looked at.

### 12.1 Verdict

**The section 10 items are closed almost completely, and the claims in section 11 are accurate
with a few exceptions. The architecture measures have not moved.** The folder reorganisation is a
clean, byte-identical move (451 renames, project file consistent, 0 broken test paths); it makes
the tree readable, and it changes no dependency.

| Measure | Review | 6.26.1 | 6.26.2 | Target |
|---|---|---|---|---|
| `WorkspaceManager.swift` lines | 5851 | 5749 | 5747 | under 1000 |
| Views taking the whole manager | 62 | 62 | 62 | 0 |
| Flat files in `Models/` and `Views/` | 338 + 96 | same | 0 (21 + 19 folders) | layered folders |
| Mutual dependencies between Models folders | 6 cycles (domains) | — | 28 mutual pairs | 0 |
| `Process()` outside `Subprocess` | about 12 | 17 | 17 in 15 files | 0 |
| `CLICompletion.run` outside `AIOperation` | — | 58 | 55 in 28 files | 0 |
| `SchemaVersionedStore` users | — | 1 | 1 | all `.dde` stores |
| `sqlite3_*` on the main actor | all | all | all | 0 |
| Lists to edit for a new tool tab | 9 | about 7 | about 7 | 1 |
| JS files over 2800 lines | 3 | 3 | 3 | 0 |

### 12.2 New problems from PR #417

| ID | Severity | Problem | Fix |
|---|---|---|---|
| FU-20 | **High** | **Mermaid diagrams lose their stylesheet.** `mvKit.sanitizeMermaidSvg` forbids `<style>` (`js/mv-kit.js:185,288`); Mermaid keeps its whole theme in a `<style>` inside the SVG. Confirmed by running the shipped function in a hidden web view: a styled SVG comes back without the `<style>` element. By reading, the editor (`markview-render.js:52`), book and PDF (`markview-book.js:462`), X-Ray (`markview-architecture.js:2091`), research map (`markview-research-map.js:279`) and discussions all pass their SVG through it. Expected on screen: black fills and wrong text colours; **not looked at in the app.** `Phase0SafetyTests` asserts the strip, so CI is green on it. | Allow `<style>` inside Mermaid SVG (Mermaid's output with `securityLevel: 'strict'` is already sanitised by Mermaid), or scope the stylesheet instead of dropping it. Add a test that renders a real diagram and checks a computed fill. |
| FU-21 | Medium | **Quit can be refused every time.** When the session file is judged "newer" (now also a legacy file with `version > 1`), `saveBeforeTermination` still calls `save`, it throws, and the app shows an error and cancels quit (`WindowSessionController.swift:202-213`, `MarkViewApp.swift:78-85`). The refusal is only logged; FU-15 asked to show it once. | Skip the save on quit when blocked; show one notice. |
| FU-22 | Medium | **The process-group kill never runs.** `Subprocess.swift:197-207` signals the group only if the child leads one, and nothing puts the child in its own group. Grandchildren survive as before. Section 11 states this as fixed. | Spawn with a new process group, or state the limit. |
| FU-23 | Low-Medium | **Saving a document through `AtomicFile`** replaces a symlinked file by a regular file, drops extended attributes and hard links, and creates `.name.tmp-UUID` inside the project folder (seen by watchers and git, left after a crash). The previous write was also atomic through Foundation; whether it kept links was not checked. | Resolve the link before writing; put the temp file in a temp directory on the same volume or use `replaceItemAt`. |
| FU-24 | Low | The CSS filter in `mv-kit.js:220-234` is a regex on raw text; CSS escapes pass it (`position:f\69xed`). `position:absolute` is allowed. No script can run; the effect is restyling. | Parse with `CSSStyleDeclaration` and allow-list properties. |
| FU-25 | Low | Remaining sinks: `markview-canvas.js:497-498` (colour from a `.canvas` file into a `style` attribute unescaped), `markview-insight-srcdoc.js:524` (Mermaid SVG without the shared sanitiser, sandboxed frame). Cached or exported Insight HTML still carries `'unsafe-inline'` (`InsightSession.swift:1648`). | Escape or sanitise. |
| FU-26 | Low | The CSP nonce is injected by regex; a miss is silent and Insight goes blank. The app's own injection path has no test. | Log the miss; test the real path. |
| FU-27 | Low | Test runner: the 180 s limit kills only the shell, not the suite's children, and applies to gui and live suites too. A bare `--changed` that selects nothing exits 0. | Kill the process group; per-tier limits. |
| FU-28 | Low | Tests that are structural rules, not behaviour (rule 4): `Phase1CleanupTests.swift:85-110` pins the 21 + 19 folder names, so adding a shared folder fails CI; `Phase7WebCITests.swift:108` fails when `tasks/todo.md` passes 500 lines, and docs go to `main` untested. | Move both to a named lint script. |
| FU-29 | Low | Dead data again: `ToolSurface.viewMenu`, `.welcomeTile`, `.sessionRestore` are set on every descriptor and read nowhere, while menu, tiles and restore are hand-written. | Delete until used, or use them (AR-31). |
| FU-30 | Process | **Rule 3 broken by its own follow-up:** one squashed commit of 848 files covers about twenty findings and cannot be reverted per finding (for example to undo FU-20 alone). | One finding per pull request. |

Still open from before and not mentioned in section 11: the Cockpit and Remote sockets have no
token or peer check (`CockpitHostBridge.swift:31-44`, `Remote/RemoteToolBridge.swift:17-22`).

### 12.3 The folder structure (AR-20)

Done: folders. Not done: layers, boundaries, lower coupling.

- All 21 Models folders are peers in one module. `Workspace` depends on 19 of the 20 others and
  14 depend on it; `AI` is used by 17. Nothing enforces a boundary (no lint, no access control,
  no package).
- `Workspace/` and `AI/` double as the shared-infrastructure folder. Clear misplacements:
  `FrontMatter` / `YAMLParser` (used by 6 folders), `SchemaVersionedStore`, `TaskBag`,
  `ArchiveSupport`, `TextDiff`, `FilterSearch`, `ListSelection`, `ContentHash` (inside
  `AI/OutputLanguage.swift`, used by 7 folders), `Views/Workspace/WindowStorage.swift` (used by 5
  view folders); `WebClip`, `WebAppPreview`, `ImageAttachments` belong to other features;
  `SystemProbe` and `CommandPolicy` in `AI/` are used only by Deployments.
- `ExtensionRegistries.swift` holds only the tool registry; the name is from the deleted content.

Next step for AR-20: a `Shared` (or the package) home for the items above, then one lint script
with an allowed-dependency table per folder and a count of violations that must go down.

### 12.4 Records

Accurate now: `CLAUDE.md` (one slip: line 8 still says "(`Core/`)"), phase status lines, feature
status `implementing`. Not accurate:

- The review says `docs/architecture/` is synchronised; 140 path references in 12 files there
  point at the old flat paths (914 across all docs, most in historical feature and bug records).
- REQ-008 ticks AR-20 and labels the script move AR-29; the three large JS files are unchanged.
- REQ-006 and the Phase 5 line say `BookAnnotator` uses `AIOperation`; the only caller is
  `ArchitectureStore`.
- Section 11 lists the process-group kill as fixed (FU-22).

Two worktrees hold uncommitted changes at the old flat paths
(`/private/tmp/MarkView-native-qa-attach`, 10 files; `/private/tmp/MarkView-workspace-performance`,
12 files), on bases 160-176 commits behind. If they are live work, carrying them over now depends
on rename detection.

### 12.5 What to do next

1. **FU-20 first** (look at one Mermaid diagram in 6.26.2; fix and release if confirmed), with
   FU-21.
2. Records and small items: 12.4, FU-22, FU-28, FU-29, the two open sockets.
3. **Stop follow-up rounds and start Step E**, one finding per pull request, each with its count:
   `Subprocess` across 15 files (AR-25), `AIOperation` across 28 files (AR-26), registry to the
   end (AR-31), then `WorkspaceManager` (AR-14). Three rounds have cleaned the edges; none has yet
   reduced a count in the table of 12.1 apart from the folders.

## 13. Final check (2026-11-15, branch feat/architecture-review-finish)

Date: 2026-11-15. Checked commit: `ac3001ba` (the merge tip of `feat/architecture-review-finish`, version 6.26.2 plus
151 commits, merges included; 105 of them carry an `AR-` or `FU-` id in the subject). Base for every "6.26.2" column:
`6facd9f` (`main`, version 6.26.2). One read-only documentation pass, counts only:

- Counted with `tools/lint/architecture-lint.sh` (exit 0), `tools/lint/task-ownership.sh`,
  `tools/lint/domain-dependencies.py` and `git grep`, on the merge tip and on `6facd9f`.
- **Not done in this pass:** no build, no `swift test`, no `tools/tests/run.sh`, no build-warnings run, the app was not
  launched, nothing was profiled. Every "by reading" below means the code was read and not run.
- The per-finding results are the `Status (2026-11-15):` lines in
  [`architecture-review-2026-11.md`](architecture-review-2026-11.md); this section is their summary. Nothing here is
  `verified`; that status stays with the owner.

### 13.1 Verdict

**This time counts moved.** Of the ten measures of 12.1, six reached their target (`WorkspaceManager.swift` lines, flat files, `Process()`, `CLICompletion.run`, SQLite on the main actor, large JS files), two came near it (places to edit for a new tool: 2 against 1; `SchemaVersionedStore` users: 14 files, not yet all stores) and two did not (views taking the whole manager: 56 against 0; cycles between `Models/` folders: 22 pairs against 0). Of the
49 findings, 23 are done by their own count or by reading (AR-01 to AR-03, AR-05 to AR-13, AR-25, AR-26, AR-28, AR-30,
AR-32 to AR-35, AR-37, AR-38, AR-46) and 26 are partial (AR-04, AR-14 to AR-24, AR-27, AR-29, AR-31, AR-36, AR-39 to
AR-45, AR-47 to AR-49); none is untouched. The remaining work is mostly the wide, boring part: views that still take
the whole manager, tasks without an owner, cycles between folders, and the sweeps of file writes and JSON stores.

### 13.2 The measures

| Measure | Review | 6.26.2 | Now | Target | Source |
|---|---|---|---|---|---|
| `WorkspaceManager.swift` lines | 5851 | 5747 | **730** (+267 in `WorkspaceManager+AIToolRuns.swift`) | under 1000 | `wc -l` |
| Views taking the whole manager | 62 | 62 | **56** (34 files) | 0 | lint `workspace-manager` |
| Mutual dependencies between `Models/` folders | 6 cycles | 28 mutual pairs | **22 pairs**, 168 type edges, 91 in the back-edges; 19 of 21 domains in one strongly connected group | 0 | `domain-dependencies.py` |
| Type references in cycles, held by a ratchet | - | - | 104 in 29 pairs (Models and Views) | falling | lint `domain-cycles` |
| `Process()` outside `Subprocess` | 17 files | 17 in 15 files | **0** | 0 | lint `process` |
| `CLICompletion.run` outside `AIOperation` | 54 in 27 files | 55 in 28 files | **0** | 0 | lint `clicompletion` |
| `SchemaVersionedStore` users | - | 1 | **14 files** (17 sites) | all `.dde` stores | `git grep` |
| `sqlite3_*` on the main actor | all | all | `SemanticDatabase` is an `actor`; 3 other files call `sqlite3_` (isolation not read) | 0 | lint `semantic-database-actor` |
| Places to edit for a new tool tab | 9 | about 7 | **2** | 1 | by reading `ToolRegistry`, `ToolTabViews` |
| JS files over 2800 lines | 3 | 3 | **0** (largest 1,322) | 0 | line counts |
| Unowned `Task {}` and `Task.detached` sites | - | 391 in 87 files | **263 in 70 files** (`Timer` 0, `asyncAfter` 21, each justified) | falling | `task-ownership.sh` |
| `.write(to:` sites | 115 | 112 | **35** (26 files, all allow-listed) | 0 | lint `atomic-write` |
| `NSLog` calls | 119 | 124 | **0** | 0 | lint `app-log` |
| `".dde"` literals | 56 | 57 | **0** | 0 | lint `project-paths` |
| `WKWebViewConfiguration(` creations | - | 10 | **0** | 0 | lint `webview-configuration` |
| String `case` labels in `WebViewBridge.swift` | 29 | 29 | **0** | 0 | `git grep` |
| `evaluateJavaScript` sites | 71 | 57 | 27 (7 files); `JS.call`/`JS.sequence` 6 -> 39 | 0 string-built | lint `js-interpolation` |
| `@unchecked Sendable` + `nonisolated(unsafe)` | 36 | 41 | 40, each justified | justified | lint `unchecked-sendable` |
| Literal assistant switches outside `Models/AI/Providers/` | about 28 in 13 files | same | **0** | 0 | lint `assistant-switch` |
| `NSAlert` references in `Models/` | - | 31 in 6 files | 25 in 11 files | 0 | `git grep` |

Reading the table: the first three rows are the architecture the review was about, and only the first moved a long way. A
file that went from 5,747 to 730 lines did not make the 56 views independent of it; `ArchitectureStore.swift` fell from
4,512 to 1,889 lines and `UIStudioSession.swift` from 3,766 to 1,958 by moving code into 8 and 9 new parts.

### 13.3 FU-20 to FU-30

| ID | State on 2026-11-15 | Basis |
|---|---|---|
| FU-20 Mermaid loses its stylesheet | addressed in code | `sanitizeMermaidSvg` keeps `<style>` and rebuilds it with `sanitizeScopedStylesheet`; `tools/tests/MermaidSvgWebTests.swift` exists; no diagram was rendered |
| FU-21 quit refused every time | addressed by reading | `saveBeforeTermination` is best-effort; a refused autosave is announced once per launch (`announceRefusedSave`) |
| FU-22 process-group kill never runs | addressed by reading | `SubprocessChild` spawns with `POSIX_SPAWN_SETPGROUP`; `SubprocessProcessGroupTests.swift` exists, not run |
| FU-23 `AtomicFile` on documents | addressed by reading | symlinks followed, extended attributes copied, temporary file outside the target folder; hard links documented as breaking |
| FU-24 CSS filter is a regex | addressed by reading | the browser's CSS parser serialises the declarations; only those are checked |
| FU-25 remaining sinks, `'unsafe-inline'` in cached Insight HTML | **open** | `InsightHTMLTemplate.swift:137` still has `script-src 'self' 'unsafe-inline'`; the canvas and Insight sinks named at 6.26.2 were not re-read |
| FU-26 silent nonce miss | addressed in code | `EditorPage` logs a miss; `tools/tests/EditorPageCSPTests.swift` exists, not run |
| FU-27 test runner limits | mostly addressed | per-suite time limits and group kill by reading; `--changed` exits 3 when changed files match no suite; `ci.yml` names no `gui` suite; the group kill was not exercised |
| FU-28 structural tests in the pure tier | closed | the 500-line `tasks/todo.md` check and the 21 + 19 folder-name pins are gone from `Phase7WebCITests.swift` and `Phase1CleanupTests.swift` (0 matches) |
| FU-29 dead `ToolSurface` fields | closed | `menuTools`, `WelcomeActions` and `isRestorable` read them |
| FU-30 one commit for twenty findings | partly followed | 151 commits on the branch; a finding spans several step commits, so it can be reverted as a range, not as one commit |

Still open from the earlier checks: FU-09 (no writer of the open-path file in the repository; the Quick Action handoff was
never tried) and FU-10 (the Insight frame was never run live).

### 13.4 What is not finished, with counts

- **AR-14, AR-17:** 56 views take the whole manager (target 0); 33 closure hooks in 12 files and 4 back-references in 4
  files remain, held by ratchets. `WorkspaceManager.swift` is 730 lines against the table's under 400.
- **AR-19:** 263 unowned tasks in 70 files: `Views/` 162 (Lifecycle 55, Workspace 43, Git 29, Deployments 14, Browser 5,
  the rest 16), X-Ray stores 37, UI Studio 19, Cockpit 8, project operations 8, the other 29.
- **AR-20, AR-21:** no layer rule, only a ratchet; 22 `Models/` pairs in cycles, led by Lifecycle -> Workspace (10 types
  back), UI Studio -> Workspace (12), Prototype -> Workspace (10), Browser -> Workspace (9), Cockpit -> Workspace (9).
- **AR-22:** `NSAlert` references in `Models/` 25 in 11 files; `FileManager` in `Views/` 25 uses in 15 files.
- **AR-24:** 35 `.write(to:` sites, `FileManager.default` 454, `try?` in `Models/` 1,087, `JSONEncoder()` 71 and
  `JSONDecoder()` 72, no shared watcher, JSON codec or rotating JSON-lines file.
- **AR-04, AR-27, AR-29:** 27 `evaluateJavaScript` sites, 80 `innerHTML =` sinks, 57 empty `catch {}` blocks, 63
  `<script>` tags with no module system, no `tsc --checkJs` or ESLint, 1,295 lines of inline CSS in `index.html`.
- **AR-31:** 2 places to edit for a new tool (target 1).
- **AR-36, AR-39:** 93 `try? decode` sites; file locking in exactly one file; the 14 `SchemaVersionedStore` users do not
  include `FeatureStore`.
- **AR-40, AR-41:** `cwd`, `folderDeclared`, `cwdTrusted` and `by_user` still come from the client; hardened runtime is not a
  project setting (`ENABLE_HARDENED_RUNTIME` 0 matches).
- **AR-42, AR-43:** not profiled; the warning count is unverified (189 distinct at 6.26.2; the branch's commit messages say
  the app target reached 0, which this pass did not check); `complete` checking is on for the package only.
- **AR-44:** no app-hosted test target; the stubs, the per-file `check(...)` helpers and the coverage gap were not
  re-counted.
- **AR-47, AR-48, AR-49:** no SwiftLint or SwiftFormat; `TestFiles/` 11 files and a 3.65 MB presentation PDF still tracked;
  `tasks/lessons.md` 2,036 lines, not distilled.
- **Not run:** build, `swift test`, `tools/tests/run.sh`, `build-warnings.sh`, the app. Until they are, the "done by reading"
  results are claims about code, not about behaviour.

### 13.5 The documents

The 21 living documents of `docs/architecture/` were rewritten against `ac3001ba` and each carries the commit it was checked
against; they cite files and symbols, not line numbers. Counted with the stale-reference checker of the second check (a
backticked path or `Type.member` that no tracked file or type matches), living documents before and after:

| | path missing | `file:line` cited | line beyond end of file | symbol missing |
|---|---|---|---|---|
| 21 living documents, 6.26.2 | 157 | 1,382 | 181 | 55 |
| 21 living documents, now | 30 | 0 | 0 | 5 |
| the two review documents, now (historical records) | 80 | 118 | 15 | 63 |

Of the 35 tokens still flagged in the living documents, 9 are deliberate mentions of removed files or types and 26 are false
positives of the checker (generic names and file patterns). `Type.member` pairs whose type exists but whose member does not:
72 -> 7. The two review documents are left as written; their counts rose because the new `Status` lines name removed files
(`project.yml`, `QUICKSTART.md`, `WorkspaceControllers.swift` and others) on purpose.

### 13.6 Recommended order

1. **Run what this pass did not:** build, `swift test --package-path Packages/MarkViewCore`, `./tools/tests/run.sh --tier pure`,
   `tools/lint/build-warnings.sh`, then look at one Mermaid diagram (FU-20), the Insight frame (FU-10) and the Finder Quick
   Action (FU-09) in a build that is not the installed app. Every other item depends on knowing which of the "by reading"
   lines hold.
2. **Small security closes:** FU-25 (`'unsafe-inline'` in cached Insight HTML), `ENABLE_HARDENED_RUNTIME` in the project
   (AR-41), and what to do with the client-supplied `cwd`, `cwdTrusted` and `by_user` (AR-40).
3. **AR-14 and AR-17 to the end:** take the 56 views off the whole manager one view at a time, each taking only the part it
   reads, and ratchet the `workspace-manager` count down to 0; then delete the 33 hooks and 4 back-references.
4. **AR-20 and AR-21 as a rule, not a ratchet:** an allowed-dependency table per folder; move the shared pieces of 12.3
   (`FrontMatter`, `YAMLParser`, `ContentHash`, `WindowStorage`, `SystemProbe`, `CommandPolicy`) to a shared home so the
   back-edges to `Workspace` and `AI` fall first.
5. **The sweeps, each with its count:** the 35 `.write(to:` sites to `AtomicFile` (AR-24), the JSON stores and the 93
   `try? decode` sites to `SchemaVersionedStore` (AR-36, AR-39), `NSAlert` out of `Models/` (AR-22).
6. **AR-19:** decide the rule for the 162 view-level tasks (a `.task` modifier owns its task; a button action that starts
   long work goes through a model that owns it) before touching them one by one.
7. **Web (AR-29, AR-27, AR-04):** an esbuild entry that emits one bundle in today's order, then `tsc --checkJs`; only then
   convert files.
8. **Tests and records (AR-44, AR-49):** an app-hosted test target for the GUI and WebKit suites; distil
   `tasks/lessons.md` by topic.
