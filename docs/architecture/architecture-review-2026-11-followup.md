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
