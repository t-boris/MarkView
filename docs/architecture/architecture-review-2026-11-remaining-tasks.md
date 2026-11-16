# Architecture review 2026-11: remaining tasks

Status date: 2026-11-16, version 6.27.3 (PR #421, merge `b845a62a`). This is the only list of what is still open. It replaces the
scattered "not done" paragraphs in `architecture-review-2026-11.md` (AR items), `architecture-review-2026-11-followup.md` (sections
13.4, 14, 15.3 and 16) and the agent memory. When a task is finished, its status line here is changed in the same pull request, with the
count that proves it (project rule: a finding is done when the old thing is gone, and "done" is written by whoever ran the count).

## How to read this document

- **Gate** says why the task was not started: every task below needs a decision from Boris under `~/.claude/CLAUDE.md` ("never break
  the architecture or change libraries without approval", "never implement quick fixes, always ask for approval") or touches stored
  data, security behaviour or tracked files. None of them is a mechanical sweep.
- **Acceptance** is a count that must reach a stated number. Measure it with the named command, never from memory.
- **Size** is the review's own estimate (S = a day or less, M = a few days, L = more than a week of one agent's work).
- Numbers marked *(recorded)* were measured at the date shown and were not re-measured for this document; re-measure before starting.
- One group = one pull request (Boris, 2026-11-15: all in one pull request, merged by me, CI checked afterwards); one commit per task.
  Each pull request bumps the version once (`./bump-version.sh`) and ends with the release workflow from `CLAUDE.md`.

## Decisions

Boris delegated D1–D9 to the implementing agent on 2026-11-16. The decisions are recorded in [DEC-012](../features/architecture-review-2026-11/decisions/DEC-012.md); D5 preserves the binding token-only decisions DEC-009 and DEC-011. The table below is the original set of questions and recommendations.


Answer by the id; "A, B" is a complete answer. My recommendation is in brackets.

| Id | Question | Recommendation |
|---|---|---|
| D1 | Delete the tracked `TestFiles/` (11 files) and `MarkView-Presentation.pdf` (3.65 MB) + `.html` from git? (AR-48) | Yes. History keeps them. |
| D2 | Add SwiftLint and SwiftFormat as build tools (new tools, config files, a CI step)? (AR-47) | Yes, SwiftLint first, in warning mode with a ratchet allow-list, like the other lint rules. SwiftFormat later or never. |
| D3 | Turn on the hardened runtime in the Xcode project, not only in `release.sh`? (AR-41) | Yes, if Debug builds and the test harness still run; otherwise only in Release configuration. |
| D4 | Add a JavaScript toolchain (esbuild bundle of the 46 first-party editor scripts, `tsc --checkJs`, ESLint in CI)? (AR-04/27/29) | Yes, but only the no-behaviour-change bundle plus `tsc --checkJs` now; the module conversion file by file is a separate, later decision. |
| D5 | Stop trusting the client for `cwd`, `folderDeclared`, `cwdTrusted` and `by_user`, and show a native confirmation for `by_user` actions? (AR-40) | Yes. It changes how agents are launched and one dialog appears, so it needs your approval of the dialog's wording and which actions confirm. |
| D6 | Cut `AgentTools` <-> `Workspace` with a window protocol of about 15 members and a "open a window" function? | Yes, last: it is the largest change and the only one that touches every MCP tool. |
| D7 | Add an app-hosted test target to `MarkView.xcodeproj` (a second product type) for the GUI and WebKit suites? (AR-44 step 4) | Yes, after D6; it needs a stable window protocol to host against. |
| D8 | Drop the 19 SQLite tables no code touches, with a new migration step? | Only after one release in which a startup check logs whether any of them has rows; a released migration is never edited. |
| D9 | Complete strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`) on the app target? (AR-43) | Yes, per domain folder, behind the build-warnings ratchet (0 allowed). |

## Group A: cleanup (D1, D2, D3). Size S-M, low risk

**A1. AR-48 dead files in git.**
- Status 2026-11-16: removed 11 tracked `TestFiles/` files and both presentation files. `git ls-files TestFiles` and `git ls-files "*.pdf"` each report 0 after staging. `EmbeddingClient` remains in 2 files (its definition and `DDESettingsView` calls to the key helpers). DEC-013 replaces the all-tier run with automated pure and gui tiers. The pure tier passed 149 suites with 0 failures, and the repeated gui tier passed 73 suites with 0 failures before the subsequent operations-window and app-hosted test changes; repeat them on the final code.
- Now: `TestFiles/` 11 tracked files (measured), `MarkView-Presentation.pdf` 3,653,172 bytes and `MarkView-Presentation.html` 54,317 bytes
  (measured). `EmbeddingClient` is still constructed; two files use its key helpers, `DDESettingsView` among them *(recorded 2026-11-15)*.
- Do: remove the tracked test files and the presentation after checking that no test or script reads them (`git grep -n TestFiles
  tools Tests MarkView`); decide with D1 whether the Fixtures under `Tests/Fixtures/` replace what a suite needs.
  Delete `EmbeddingClient` and its settings keys only if `git grep EmbeddingClient` shows no caller outside the key helpers; a settings key
  name never changes once shipped (`settings-key-table-tests`), so a retired key is removed from the table in the same commit with the
  test updated.
- Acceptance: `git ls-files TestFiles` = 0; `git ls-files '*.pdf' | wc -l` = 0 for the presentation; `git grep -c EmbeddingClient -- MarkView` = 0
  (or a stated number with the reason).
- Risk: a suite that reads `TestFiles/` fails; per DEC-013, run the automated `pure` and `gui` tiers, leaving live scenarios manual.

**A2. AR-47 compiler and lint policy.**
- Status 2026-11-16: SwiftLint 0.65.1 reports 50 warnings (47 force_try, 3 unused_closure_parameter); a per-file/rule ratchet and CI step were added. Warnings-as-errors is enabled in both app configurations; a Debug build passed on 2026-11-16. Analyzer-only unused_import, Release and CI verification remain outstanding. A full `swiftlint analyze` against the Debug compiler log was stopped after 20 minutes without a result; it reached about 4 GB RSS. An eight-file pilot analyzed each file (3–87 seconds per file, 3 warnings total); it is not a full baseline. Do not add the unbounded invocation to CI or claim unused_import is checked until a bounded approach is verified.
- Now: no SwiftLint or SwiftFormat (0 config files), `SWIFT_TREAT_WARNINGS_AS_ERRORS` not set *(recorded)*. The build-warnings ratchet
  (`tools/lint/build-warnings.sh`, allow-list empty) already holds app warnings at 0; `.editorconfig` exists.
- Do (after D2): `.swiftlint.yml` with the rules the project already enforces by script left to the scripts, only style rules that find
  real defects (`force_try`, `force_cast`, `unused_import`, `unused_closure_parameter`), run in CI in warning mode with an allow-list
  under `tools/lint/` that may only shrink, like the other ratchets. No mass reformat in the same pull request.
- Acceptance: `swiftlint lint --quiet | wc -l` equals the allow-list count and the CI step exists; `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in
  both app configurations with the build still green (warnings are 0 today).
- Risk: a new tool on every developer machine and in CI; the install step must be documented in `CLAUDE.md`.

**A3. AR-41 platform posture (hardened runtime).**
- Status 2026-11-16: enabled the Xcode setting in Debug and Release (2 occurrences). Debug build and the Cockpit scratch harness passed. An independent Xcode Release build, without `release.sh`, succeeded and `codesign -dv` reported `flags=0x10002(adhoc,runtime)`; the intermediate 6.29.0 release was Developer ID signed and notarized. An independent Xcode Release build of 6.30.7 signed directly with Developer ID (without `release.sh`) reported `flags=0x10000(runtime)` and passed `codesign --verify --deep --strict`. Final release verification remains open.
- Now: `ENABLE_HARDENED_RUNTIME` appears 0 times in `project.pbxproj` (measured); only `release.sh` signs with `--options runtime`.
  `NSAllowsArbitraryLoads` is already false; `NSAllowsArbitraryLoadsInWebContent` is true (needed for local pages and web previews).
  The shell-string deployment and remote commands are the documented exception and were not re-checked.
- Do (after D3): set the build setting in Release (and Debug if the harness still runs), re-run `release.sh` to prove the signed, notarized
  app is unchanged; scope ATS further only if a web preview of a local page still works.
- Acceptance: `grep -c ENABLE_HARDENED_RUNTIME MarkView.xcodeproj/project.pbxproj` >= 2 and `codesign -dv --verbose=4` of the Release app
  shows `flags=0x10000(runtime)` without `release.sh` adding the option.

## Group B: JavaScript toolchain (D4). Size M now, L later

**B1. AR-29 no module system; AR-27 web-side copies; AR-04 residual JS calls.**
- Now *(recorded 2026-11-15/16)*: 63 `<script>` tags in `index.html` (measured), `index.html` carries 1,295 inline CSS lines (measured), `window.x =`
  assignments 111, `innerHTML =` sinks 80, no `tsc --checkJs` or ESLint in `ci.yml`. The largest first-party JS file is 1,322 lines. The
  Swift half of AR-27 is done (`WebHost`, 0 raw `WKWebViewConfiguration`). AR-04: the defect class is closed by the lint `js-interpolation`;
  27 `evaluateJavaScript` sites remain, constant scripts or `JS.call`, accepted by the lint.
- Do in this order, one commit each: (1) an entry file that imports the existing scripts in today's order and emits one bundle with
  `tools/web-vendor` (no behaviour change; same load order; `index.html` loads the bundle); (2) `tsc --checkJs` on the bundle's inputs
  with `// @ts-check` added file by file, errors allow-listed and shrinking; (3) move the 1,295 inline CSS lines to `css/`; (4) only with a
  separate approval, convert file by file to `import`/`export` and replace the wrap chains (`setContent` reassigned in four files,
  `setTheme` in three) with a view registry.
- Acceptance (steps 1-3): `<script>` tags in `index.html` = 1 first-party bundle + vendor tags; the bundle is built by `npm ci && ./build.sh`
  and `git diff --exit-code` after a rebuild is clean in CI; `tsc --checkJs` error count equals its allow-list; inline CSS lines in
  `index.html` = 0.
- Risk: the editor loads scripts in a fixed order and wraps entry points; a bundle that reorders anything breaks the editor silently. The
  `editor-page-csp-tests`, `web-preview-tests` and `bridge-contract-web-tests` suites plus a hidden app-probe run (rules in `tasks/lessons.md`) must pass
  before merge.

## Group C: window architecture (D6, and D7 after it). Size L, highest risk

All of C is a redesign; none is a sweep. Do it in this order because each step shrinks the next.

**C1. `AgentTools` <-> `Workspace`.**
- Status 2026-11-16: the control tools use `AgentControlWindow`; window opening is injected from `WindowSessionController` independently of live window registrations. The Debug build and `remote-browser-tests` passed with a test of the opener before any window registration. Debug build passed and `domain-dependencies.py --layer Models --why AgentTools Workspace` reports 0 types (was 2); `domain-cycles` is now 0 back-edges. `control-agent-tools-tests`, `project-agent-tools-tests`, `browser-agent-tools-tests`, `cockpit-host-bridge-tests`, `remote-workspace-tests` and `remote-browser-tests` passed. The standalone control suite exercises the tool contract and socket clients, not the shipping `ControlToolRunner`; app-hosted coverage remains open under C5. The MCP control tools name `WorkspaceManager` and `WindowSessionController`. Define a window protocol
of about 15 members (the ones those tools actually call: read the list with `python3 tools/lint/domain-dependencies.py --why AgentTools
Workspace`) and an "open a window" function the app passes in; the tools take the protocol. Acceptance: `domain-cycles` back-edges 1 -> 0
(`tools/lint/domain-cycles-allowlist.txt` empty after `--tighten`); the control tools still pass `control-agent-tools-tests` and the other MCP suites.

**C2. 31 closure hooks and 4 back-references.**
- Status 2026-11-16: the C1 protocol removed three manager references; `ResearchMapStream` now publishes readiness as a Combine event, observed by its driver, instead of a post-init callback. The PDF reader routes Find through a narrow delegate; the PDF suite passed with a check of the named Find action, and Debug build and warning ratchet passed. `architecture-lint.sh --tighten` reports 26 hooks (was 31) and 0 back-references (was 4). Debug build and `research-map-run-tests` passed; that suite covers parsing, not the driver subscription. UI Studio preparation now emits record events consumed by its session, replacing another callback. The UI Studio preparation and lifetime suites, Debug build, warning ratchet and architecture lint passed; existing checks cover events at start and completion. The two browser save-menu callbacks use a narrow delegate. Web-preview tests passed, including selection and PDF save routing; Debug build, warning ratchet and architecture lint passed. The shared operations store receives the originating window per action and retains a weak presenter per run for notification routing, instead of a mutable last-window back-reference. The two-window editor and asynchronous run routing checks, four focused suites, changed-file suite, window-session and web-preview suites, Debug build and warning ratchet passed. The remaining hooks remain open. Each is listed with a reason in `tools/lint/window-wiring-hooks.txt` and
`window-wiring-backrefs.txt`. The remaining ones are redesigns (for example `ResearchMapStream.onReady` needs a relay object). Per hook:
replace the closure by a protocol the owner conforms to, or by an event on an existing part, and delete the closure property.
Acceptance: `architecture-lint.sh` `window-wiring (hooks)` 31 -> a lower stated number and `(back-references)` 4 -> 0, each by `--tighten`.

**C3. 2 views on the manager.**
- Status 2026-11-16: `FileTreeView` uses `ProjectContext`, its existing scoped coordinators, and `WindowCommands` instead of observing `WorkspaceManager`; the ratchet fell from 2 views to 1 (`EditorView`). Debug build succeeded with no warnings, and file-browser, file-operations and window-composition suites passed (3/3); architecture lint passed after tightening. A hidden scratch-app probe opened the project, but the simulated Show Files click did not switch views, so opening a file was not verified; no new crash report appeared. `EditorView` now receives the existing scoped parts and window commands. The view ratchet is 0; Debug build, warning ratchet, architecture lint and six bridge/WebKit/window suites passed. Those standalone suites exercise the bridge and window composition, not `EditorView` hosted in the application; app-hosted coverage remains open under C5.
Move the commands to `WindowCommands` (`@Environment(\.windowCommands)`), as the other views did. Acceptance: `workspace-manager` rule 2 -> 0.

**C4. The 16-domain strongly connected group of `Models/`.** After C1-C3 re-run `domain-dependencies.py`; the tool counts named types only.
- Measurement after C1–C3, 2026-11-16: `python3 tools/lint/domain-dependencies.py --layer Models` reports a largest strongly connected group of 10 domains (was 16) and 0 back-edges. The tool counts named types only; the remaining group is not claimed eliminated.
Acceptance: the stated number of domains in the largest cycle, or a written decision that the remainder is accepted.

**C5. AR-44 step 4: an app-hosted test target (D7).**
- Status 2026-11-16: `MarkViewHostedTests` hosts the migrated QA WebKit fault suite with the shipping `BrowserSession` and `BrowserAgentExecutor`; their two stand-in definitions and the old standalone suite were removed. `xcodebuild -list`, `xcodebuild test`, the manifest runner and architecture lint passed. The dedicated `HostedTests` build uses a separate bundle ID and compile-time startup isolation; the test bundle has no app `NSPrincipalClass`. The first experimental host crashed because it inherited that class; the installed app remained running, and the corrected host ran without another crash. The parallel hosted CI job passed in [run 43902583991](https://github.com/t-boris/MarkView/actions/runs/43902583991); the hosted job took 5m15s and the full workflow 5m20s, with one pure shard queued for about 1m49s. Further stub migrations and app-hosted `EditorView` and control-runner coverage remain open.
 Add a second product type to `MarkView.xcodeproj` that hosts the GUI and WebKit suites
in the app process; live-assistant scripts stay manual. Acceptance: `xcodebuild -list` shows the test target and `xcodebuild test` runs
the gui tier suites that today compile stand-ins of shipping types (the stub definitions are removed in the same pull request).
Per CLAUDE.md rule 2, no target is added without a first real suite moved into it.

## Group D: security, tests, data (D5, D8, D9). Size M each

**D1. AR-40 the local control socket trusts what the client says.**
- Status 2026-11-16: the server is being changed to use only the authenticated peer PID, kernel ancestry and process working directory; client folder, ancestry and trust fields are no longer authoritative. The control, project, browser and remote-browser suites passed, including forged-folder and forged-ancestry requests. The Debug build and warning ratchet passed with 0 warnings; the changed-file suites passed (7 suites), and the four focused control, project, browser and remote-browser suites passed after the routing change. A follow-up preserves BUG-042: legacy `project_folder` can only reject a mismatch after routing and never select a window; real-socket tests passed for both mismatch and match. A hidden scratch-app Cockpit run on `1a356231` passed S5 and S12 (normal execution and wrong-ticket refusals, including a caller outside the step); no new MarkView crash report appeared. CI and release verification are outstanding. DEC-012 retains the binding token-only policy without a separate confirmation gate.
- Now: the browser-control, Cockpit and Remote sockets already use `PrivateSocket` (256-bit token in a mode-0600 file, constant-time
  compare, kernel peer credentials). Not done: `cwd`, `folderDeclared` and `cwdTrusted` (defaults to true) still come from the request, and
  `by_user` is a boolean the agent supplies (`ControlToolRunner+Flow.swift`, `ControlAgentTools`); no native confirmation exists.
- Do (DEC-012): derive the working folder from the peer’s PID ancestry in the server; drop `cwdTrusted` from the request schema and ignore client-supplied ancestry and folder fields for routing. A legacy `project_folder` can only restrict a selected project and is refused if it mismatches. Preserve the `by_user` flow and do not add a separate confirmation gate, as required by DEC-009 and DEC-011.
- Acceptance: `git grep -c cwdTrusted -- MarkView` = 0; socket tests show a forged folder and ancestry cannot select a window, and a `cwd` outside a pinned window is ignored. The `by_user` gate remains as recorded in DEC-009 and DEC-011; a native confirmation is not part of this decision.
- Risk: agents that relied on a declared folder from a shared daemon may stop routing until launched in the project or by the app.

**D2. AR-42 main-thread blocking, by measurement.**
- Status 2026-11-16: a hidden 6.30.16 probe opened an APFS copy of `vivaa-internals`. Two samples and Time Profiler recordings were taken; the timed sample was mostly main-run-loop waiting, and Instruments reported 0 `potential-hangs` and 0 `hang-risks`. The capture did not establish an attributable before/after stall or three worst stalls, so the acceptance remains open. Raw traces were removed because Instruments included environment variables. The installed app remained running and no new crash report appeared during the probes.
- Now: only by reading; nothing was profiled. Done: all SQL off the main thread, `hasMarkdownFiles` a stored flag, directory walks in
  `Views/` 0, `waitUntilExit` 0, the 2 s open-files poll is a `PollingScheduler` job. Not re-checked: how much of that poll still runs on
  the main thread; the `ForEach` enumeration in `GraphCreatorSheet` and the lookup fallback in `TOCView`.
- Do: profile with `/usr/bin/sample <pid> 3` and Instruments on a large project (the vivaa-internals tree), name the worst three stalls,
  fix those. Acceptance: a stated main-thread stall (ms) before and after on the same project and the same action; no claim without it.

**D3. AR-43 concurrency checking.**
- Measurement 2026-11-16: a clean Debug build with `SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=NO` failed on `StudioMessageHandler` WebKit protocol conformance and emitted 221 distinct warning lines in 63 files before termination (Xcode 27.2). Targeted checking remains in the project; these diagnostics must be resolved before switching the setting. The editor bridge is now main-actor isolated; the targeted Debug build and both bridge-contract suites passed. The repeat complete-concurrency build compiled `WebViewBridge.swift` with 0 warnings (37 distinct warning lines for that file in the first build); the overall build still fails on the WebKit conformance. The initial failed build’s overall warning count is not comparable to the completed clean build. The UI Studio reply callback now matches WebKit’s main-actor contract: a clean complete-concurrency Debug build succeeded with 232 distinct warning lines in 77 files before the later editor-delegate refinements; Both UI Studio regression suites passed. The editor delegate and WebKit navigation callback now use main-actor contracts; both bridge-contract suites and the web-preview suite passed. Two new targeted-build warnings from the bridge isolation were fixed; the repeated Debug build and warning ratchet passed with 0 warnings. In complete checking, the compiled `EditorView.swift` emitted 17 distinct warnings, down from 21 in the preceding clean build. The MCP tool schemas have been changed from shared non-Sendable static values to freshly constructed values; Debug build and the control, project and browser tool suites passed. A complete-checking incremental build compiled all five affected files with 0 AgentTools warnings, down from 19 in the prior clean build. Three Architecture JSON schemas are now constructed locally rather than shared as non-Sendable values; the six changed-file suites and Debug build passed, and complete checking compiled all three files with 0 static-schema warnings (3 before). Four Prototype JSON schemas are also constructed locally; isolated complete-concurrency type checking reported 0 warnings (4 static-schema warnings before), the prototype ownership suite passed, and the targeted Debug build and warning ratchet passed. Three UI Studio schemas now also construct dictionaries per use. Complete checking compiled `UIStudioPrompts.swift` with 0 warnings (3 static-schema warnings before); the targeted Debug build and warning ratchet passed. The three GUI suites passed, including the real session harness. Five more UI Studio schema and bridge dictionaries use local construction. The preparation and lifetime suites and Debug build passed, and complete checking emitted 0 static-property warnings in the four affected files (5 before). Two Lifecycle bug schemas now construct dictionaries locally; all four changed-file suites and the Debug build passed, and complete checking emitted no static-schema warnings in those files (2 before). Two QA schemas now construct dictionaries locally. All nine changed-file suites and the Debug build passed; complete checking emitted no static-schema warnings in the two files (2 before). The full gui run exposed a regression from WebViewBridge main-actor isolation: `js-call-web-tests` did not compile. Its editor WebKit driver now runs on the main actor, and the focused `js-call-web-tests` rerun passed (including editor and terminal WebKit checks). The original gui run was stopped after that failure; the full gui rerun on the fixed driver passed 73 suites with 0 failures. The socket server now transfers its request arguments without `nonisolated(unsafe)`; complete checking compiled the file with no warning, four socket/tool suites and the Debug build passed. By the same grep, production sites fell from 40 to 39; including test sources the count at that point was 44 (43 at the starting commit), because migrated tests had added sites. The socket-permission test returns its counters from a detached task instead of two unsafe shared variables; the focused package test and architecture lint passed. The same grep across app and package (including tests) is now 42 lines, down from 43 at the starting commit. CI run 43905786545 then found two async-context semaphore warnings in that test. The handshake now uses `AsyncStream` and cancellation; the focused test and warning ratchet passed locally, and a new CI run is required. Claude session timestamp formatters are confined behind locks; complete checking reports no warnings in the file (2 static-formatter warnings before), and the focused suite, 200 concurrent parsing checks and Debug build passed. UI Studio’s shared authentication timestamp formatter is confined behind a lock. The focused suite, 200 concurrent formatting checks and Debug build passed; complete checking reports no warnings in the file (1 static-formatter warning before). GitHub date parsers use lock-owned formatter state. Eight changed-file suites, 200 concurrent parses and Debug build passed; complete checking reports no static-formatter warnings (3 before), with 1 other warning in that file. The zero-warning target remains open.
- Now: `SWIFT_STRICT_CONCURRENCY = targeted` in both app configurations; `MarkViewCore` is built with complete checking. 43 sites of
  `@unchecked Sendable` or `nonisolated(unsafe)` in `MarkView` and `Packages` (measured with `git grep -cE`), each justified (lint
  `unchecked-sendable`, exit 0).
- Do (after D9): raise to `complete` one `Models/` domain folder at a time, convert lock-plus-unchecked services to actors where the owner
  is a single object, keep the build-warnings ratchet at 0. Acceptance: setting `complete` in both configurations with 0 warnings, and the
  unchecked count at a stated lower number.

**D4. AR-44 steps 3-4 and the stubs.**
- Status 2026-11-16: moved the PrivateSocket real-socket and phase2 core checks to `MarkViewCoreTests` and removed their standalone script and manifest entry. The PrivateSocket package test passed (1 test, 0 failures); the migrated phase2 checks passed (2 tests, 0 failures); the remaining script mains and application stubs are not yet migrated. Port script mains to `swift test` cases in `Packages/MarkViewCore` and delete the scripts; one
`TestSupport` target with one fake per protocol replaces the stub type definitions (81 stubbed application types, 125 definitions, at
2026-11-15). Acceptance: the stub count by `git grep -c "^final class\|^struct" tools/tests/*.swift` for application type names falls to a
stated number per pull request; `tools/tests/manifest.json` suite count stays true.

**D5. The 19 SQLite tables nothing touches (D8).**
- Status 2026-11-16: release 6.29.0 recorded row counts for the 19 candidate tables on the database-opening thread, without reading row content; missing or unreadable tables were reported as errors, not empty. That temporary check is removed in the migration release. `semantic-database-tests` passed, including the 19-count check on a real database. The first release is [6.29.0](https://github.com/t-boris/MarkView/releases/tag/v6.29.0) from `d6eca5e2`, published 2026-11-16 with CI and Build & Release passing. Its signed DMG was accepted by `spctl` as notarized. Running its released binary’s headless indexer against a temporary project produced 19 count-only log entries, all zero; `user_version` was 3. SQLite reported 37 physical tables, including five FTS shadow tables (32 logical tables), rather than the recorded 34. Migration 4 was implemented after that release: it keeps nonempty tables and parents referenced by retained tables. `semantic-database-tests` passed: a new database has 18 physical tables (13 logical plus five FTS shadows), and a version-3 fixture with data retains three candidates and drops 16. The Debug build and warning ratchet passed with 0 warnings; the final release is outstanding.
- Baseline: The review recorded 34 tables and 19 with no code users; the actual version-3 fixture has 32 logical tables plus five FTS shadow tables. The `blocks` path was removed
  in 6.27.2 with migration step 3 as the template.
- Do (after D8): add one startup check that logs (counts only, never content) whether any of the 19 has rows; release; then add the next
  `SQLiteMigration` at the end of `SemanticSchema.migrations` that drops those with 0 rows. A released step is never edited.
- Acceptance: `PRAGMA user_version` goes up by one; the table count falls from 34 to 15 (or a stated number with the reason for any kept);
  `semantic-database-tests` pass on a database made by the previous version (add a check that opens a database written by 6.27.3).

## Group E: checks only a person can make (Boris, in the installed app)

Not seen by me in the real app; each takes a minute. Tick them here when done.

- [ ] `AlertPrompts`: close a window with an unsaved tab, run Project Operations "Run", a page `confirm()` in a browser tab, "Connect Agents...";
  each asks the same question as before (titles, texts, buttons, the first button is the default).
- [ ] Save-panel exports (PDF export, Book PDF, discussion thread export) write the file.
- [ ] Paste a picture into a terminal; pick an element in UI Studio; Preview in QA; prototype hand-off (the picture writers).
- [ ] `claude login` and `gh auth login` start from their buttons (the sign-in scripts, `LoginScript`).
- [ ] Not hand-checked in 6.27.0-6.27.2 either: archive/canvas viewers, project-less image/zip windows, drag and drop and the trash
  dialog in the file tree, closing a window with running work, X-Ray AI chain and its Pull request overlay, the Insight frame.
- [ ] Live suites `book-pdf-live` and `ui-studio-live-run` (need a real assistant).
- [ ] Install 6.27.3 (nothing from 6.27.1 on was installed by me).

## Suggested order

1. A (cleanup): D1, D2, D3 in one pull request. The least risk, and it makes the rest cheaper to review.
2. D1/D5 of group D after D5's answer, then B1 steps 1-3.
3. C1 -> C2 -> C3 -> C4, then C5.
4. D2, D3, D4 and the SQLite drop as separate pull requests, because each needs its own measurement or its own release.

## What is done and must not be reopened

Every AR and FU item not named above is recorded as done, or as partial with its reason and count, in the two review documents; this list
is the open part. Two accepted limits are not tasks: 59 tolerant `try? decode` sites stay on the `silent-decode` allow-list with a reason each
(AR-36), and CI jobs per push (AR-45) were not measured against the target of three. The structural rules that hold the closed items are in
`tools/lint/architecture-lint.sh`, all passing at 6.27.3. A ratchet allow-list under `tools/lint/` may only shrink.

## CI duration investigation (2026-11-16)

On [push run 43871770311](https://github.com/t-boris/MarkView/actions/runs/43871770311), the pure regression step took 12m46s of the 13m15s workflow; the parallel build job took 4m46s. The previous push run 43856849658 spent 15m37s in that step. The suite runner compiles many standalone Swift test binaries; it already runs up to six suites per machine. CI now distributes the same manifest-selected pure suites over three independent macOS jobs; the former phase2 core checks were moved into the package suite, removing a redundant package build and test run. Its standalone suite took 94.7 seconds in run 43871770311. The current manifest has 149 pure suites after moving two scripts into the package. On [push run 43880643640](https://github.com/t-boris/MarkView/actions/runs/43880643640), all three shards and the build passed: the slowest pure step took 4m17s, and the full CI run took 6m32s, compared with 12m46s and 13m15s respectively on run 43871770311. The app build was the critical path; the runs also differ in source changes and cache state.

A later [push run 43887926164](https://github.com/t-boris/MarkView/actions/runs/43887926164) passed in 7m45s. Its last pure job started about two minutes after the other jobs, and GitHub reported macOS ARM runner capacity constraints; queue time is separate from test execution.

In [run 43887926164](https://github.com/t-boris/MarkView/actions/runs/43887926164), the slowest pure shard took 6m05s and a runner waited about 2 minutes; per-suite durations summed to 491s, 764s and 1,032s by shard. CI now assigns all 149 suites exactly once using measured durations and longest-first balancing (historical sums approximately 762s per shard); [Run 43891177394](https://github.com/t-boris/MarkView/actions/runs/43891177394) passed with pure steps 3m20s, 4m57s and 5m12s, and a total duration of 6m22s. Runs also differ in runner load and cache state.
