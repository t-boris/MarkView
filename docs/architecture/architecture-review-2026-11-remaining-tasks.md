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

## Decisions needed from Boris

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
- Now: `TestFiles/` 11 tracked files (measured), `MarkView-Presentation.pdf` 3,653,172 bytes and `MarkView-Presentation.html` 54,317 bytes
  (measured). `EmbeddingClient` is still constructed; two files use its key helpers, `DDESettingsView` among them *(recorded 2026-11-15)*.
- Do: remove the tracked test files and the presentation after checking that no test or script reads them (`git grep -n TestFiles
  tools Tests MarkView`); decide with D1 whether the Fixtures under `Tests/Fixtures/` replace what a suite needs.
  Delete `EmbeddingClient` and its settings keys only if `git grep EmbeddingClient` shows no caller outside the key helpers; a settings key
  name never changes once shipped (`settings-key-table-tests`), so a retired key is removed from the table in the same commit with the
  test updated.
- Acceptance: `git ls-files TestFiles` = 0; `git ls-files '*.pdf' | wc -l` = 0 for the presentation; `git grep -c EmbeddingClient -- MarkView` = 0
  (or a stated number with the reason).
- Risk: a suite that reads `TestFiles/` fails; run `./tools/tests/run.sh --all` once.

**A2. AR-47 compiler and lint policy.**
- Now: no SwiftLint or SwiftFormat (0 config files), `SWIFT_TREAT_WARNINGS_AS_ERRORS` not set *(recorded)*. The build-warnings ratchet
  (`tools/lint/build-warnings.sh`, allow-list empty) already holds app warnings at 0; `.editorconfig` exists.
- Do (after D2): `.swiftlint.yml` with the rules the project already enforces by script left to the scripts, only style rules that find
  real defects (`force_try`, `force_cast`, `unused_import`, `unused_closure_parameter`), run in CI in warning mode with an allow-list
  under `tools/lint/` that may only shrink, like the other ratchets. No mass reformat in the same pull request.
- Acceptance: `swiftlint lint --quiet | wc -l` equals the allow-list count and the CI step exists; `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in
  both app configurations with the build still green (warnings are 0 today).
- Risk: a new tool on every developer machine and in CI; the install step must be documented in `CLAUDE.md`.

**A3. AR-41 platform posture (hardened runtime).**
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

**C1. `AgentTools` <-> `Workspace`.** The MCP control tools name `WorkspaceManager` and `WindowSessionController`. Define a window protocol
of about 15 members (the ones those tools actually call: read the list with `python3 tools/lint/domain-dependencies.py --why AgentTools
Workspace`) and an "open a window" function the app passes in; the tools take the protocol. Acceptance: `domain-cycles` back-edges 1 -> 0
(`tools/lint/domain-cycles-allowlist.txt` empty after `--tighten`); the control tools still pass `control-agent-tools-tests` and the other MCP suites.

**C2. 31 closure hooks and 4 back-references.** Each is listed with a reason in `tools/lint/window-wiring-hooks.txt` and
`window-wiring-backrefs.txt`. The remaining ones are redesigns (for example `ResearchMapStream.onReady` needs a relay object). Per hook:
replace the closure by a protocol the owner conforms to, or by an event on an existing part, and delete the closure property.
Acceptance: `architecture-lint.sh` `window-wiring (hooks)` 31 -> a lower stated number and `(back-references)` 4 -> 0, each by `--tighten`.

**C3. 2 views on the manager.** `EditorView` and `FileTreeView` read `WorkspaceManager` for window commands (`tools/lint/workspace-manager-views.txt`).
Move the commands to `WindowCommands` (`@Environment(\.windowCommands)`), as the other views did. Acceptance: `workspace-manager` rule 2 -> 0.

**C4. The 16-domain strongly connected group of `Models/`.** After C1-C3 re-run `domain-dependencies.py`; the tool counts named types only.
Acceptance: the stated number of domains in the largest cycle, or a written decision that the remainder is accepted.

**C5. AR-44 step 4: an app-hosted test target (D7).** Add a second product type to `MarkView.xcodeproj` that hosts the GUI and WebKit suites
in the app process; live-assistant scripts stay manual. Acceptance: `xcodebuild -list` shows the test target and `xcodebuild test` runs
the gui tier suites that today compile stand-ins of shipping types (the stub definitions are removed in the same pull request).
Per CLAUDE.md rule 2, no target is added without a first real suite moved into it.

## Group D: security, tests, data (D5, D8, D9). Size M each

**D1. AR-40 the local control socket trusts what the client says.**
- Now: the browser-control, Cockpit and Remote sockets already use `PrivateSocket` (256-bit token in a mode-0600 file, constant-time
  compare, kernel peer credentials). Not done: `cwd`, `folderDeclared` and `cwdTrusted` (defaults to true) still come from the request, and
  `by_user` is a boolean the agent supplies (`ControlToolRunner+Flow.swift`, `ControlAgentTools`); no native confirmation exists.
- Do (after D5): derive the working folder from the peer's pid ancestry in the server; drop `cwdTrusted` from the request schema; for the
  actions marked `by_user` (answer, approve requirements, file issues, start unattended implementation) raise a native confirmation in
  the window the agent belongs to and ignore the boolean.
- Acceptance: `git grep -c cwdTrusted -- MarkView` = 0; a test that sends `by_user: true` without the confirmation is refused; a test that
  sends a `cwd` outside the window's folder is ignored. Hidden probe: the confirmation sheet appears and Cancel leaves no change.
- Risk: agents that work today with a declared `cwd` stop working until launched by the app; wording of the dialog is yours.

**D2. AR-42 main-thread blocking, by measurement.**
- Now: only by reading; nothing was profiled. Done: all SQL off the main thread, `hasMarkdownFiles` a stored flag, directory walks in
  `Views/` 0, `waitUntilExit` 0, the 2 s open-files poll is a `PollingScheduler` job. Not re-checked: how much of that poll still runs on
  the main thread; the `ForEach` enumeration in `GraphCreatorSheet` and the lookup fallback in `TOCView`.
- Do: profile with `/usr/bin/sample <pid> 3` and Instruments on a large project (the vivaa-internals tree), name the worst three stalls,
  fix those. Acceptance: a stated main-thread stall (ms) before and after on the same project and the same action; no claim without it.

**D3. AR-43 concurrency checking.**
- Now: `SWIFT_STRICT_CONCURRENCY = targeted` in both app configurations; `MarkViewCore` is built with complete checking. 43 sites of
  `@unchecked Sendable` or `nonisolated(unsafe)` in `MarkView` and `Packages` (measured with `git grep -cE`), each justified (lint
  `unchecked-sendable`, exit 0).
- Do (after D9): raise to `complete` one `Models/` domain folder at a time, convert lock-plus-unchecked services to actors where the owner
  is a single object, keep the build-warnings ratchet at 0. Acceptance: setting `complete` in both configurations with 0 warnings, and the
  unchecked count at a stated lower number.

**D4. AR-44 steps 3-4 and the stubs.** Port script mains to `swift test` cases in `Packages/MarkViewCore` and delete the scripts; one
`TestSupport` target with one fake per protocol replaces the stub type definitions (81 stubbed application types, 125 definitions, at
2026-11-15). Acceptance: the stub count by `git grep -c "^final class\|^struct" tools/tests/*.swift` for application type names falls to a
stated number per pull request; `tools/tests/manifest.json` suite count stays true.

**D5. The 19 SQLite tables nothing touches (D8).**
- Now: `SemanticSchema` creates 34 tables; 19 are touched by no code (counted in section 15.3, not dropped). The `blocks` path was removed
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
