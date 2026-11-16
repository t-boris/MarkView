# Lessons

Rule book by topic, distilled 2026-11-16. The verbatim chronological text up to 2026-11-16 is `tasks/archive/lessons-2026-11-chronological.md`; `[A: heading words, date]` names the archive heading a rule came from (date: in the heading, else the heading's commit date). Append new lessons under the matching topic, or a new topic, as: date, rule, why.

## 1. Process and communication with Boris

- Read the whole report and list every ask in it; a validity summary or a "not a cause" note narrows nothing, and a bug with several outcomes has one checklist line per outcome.
  Why: BUG-108 shipped only the clipping fix and dropped the dictated half. [A: A report's "Original description", 2026-11-08]
- Match a loose UI word ("filter", "panel", "explanations") to the screen the person is on, name it back, and extend the existing tool before adding a panel; list every kind of
  noise a filter covers. Why: a Topic panel was built where X-Ray's filter was meant, and the wrong panel was fixed.
  [A: Новую возможность встраивать, 2026-09-25 | Confirm which panel, 2026-09-24 | "Filters" means, 2026-11-08]
- Describe a new concept as one concrete scene (what he types, what he sees) and confirm it before reusing the nearest feature. Why: a Discussion was built as "question -> Insight
  page"; he meant a conversation. [A: Discussion was built as, 2026-10-23]
- Grep the code before trusting a spec sentence or an `implemented` status; for two specs on one issue keep one. Why: a spec assumed unopenable files were hidden
  (`FileType.isOpenable` is true for every regular file); another was `implemented` with no code. [A: "Filters" means, 2026-11-08 | A spec's `implemented`, 2026-09-27]
- A message that arrives during a tool call is a request: answer it in the same turn. Before creating or finishing a bug `git fetch` and read `docs/bugs/` on origin/main (ids
  collide between sessions). Change a planned step only by saying so in the plan and the report; answer "why not X" from the invariant recorded in the code.
  [A: BUG-050, a prototype, 2026-11-03]
- For anything that runs over time, write down at the start what is measured per step, what the person SEES and where results appear; after each stage say what is visible and what
  is missing. [A: A feature that runs something, 2026-11-09]
- A screen the person supervises draws the thing (steps, who runs each, model, status, times) with raw text underneath, editable parts first, configuration folded; look at a
  picture of every state before "done". Why: the Cockpit plan was text cards and raw JSON. [A: A screen the person supervises, 2026-11-14]
- Every outcome of an input feature (success, empty, each error, silence) must show where the user looks, not in a tooltip, and name the setting that decides it. Why: dictation
  without a key looked like "heard nothing". [A: A feature that can fail silently, 2026-11-02]
- A status names the task and the concrete step ("Thinking" is never enough) and sits on each item (tab, file, job); check it with two items. [A: A status must say, 2026-10-12]
- A defect I can see in my own render is fixed in the same change, never listed as a "known limit"; if a live run on his own project shows the headline feature failing, fix it
  before release or say it does not work there. Why: both were filed as limits and both came back from Boris (the second as "it does not work").
  [A: a defect visible in my own render, 2026-11-09 | A finding that blocks, 2026-11-14]
- A feature that cannot run is not delivered: run a pipeline (generate, plan, run) end to end on a fixture with the real assistant before release; a run Blocked with 0 steps is my
  bug. [A: A feature that cannot run, 2026-11-10]
- Every sentence in a prompt, guide or label that says what the app does ("recorded automatically") names a function and its caller; a rule with no caller is a promise. Have a
  reader who did not write the code review spec plus file list before final verification. [A: Text that promises, 2026-11-05 | say "automatic" only, 2026-11-08]
- A change deletes the code it replaces (branches, flags, fallbacks, the tests that pinned them) and counts outside uses of every public declaration it touched; a test-only use is
  dead code or a double for `tools/tests/`. Why: Boris: "Don't leave old code." [A: A change removes the code, 2026-11-05]
- Never give UI directions from a grep: say "according to the code, not seen on screen", name a control that surely exists, and say first why I cannot do the step. Why: the
  Lifecycle button I named sat collapsed and he could not find it. [A: Do not give directions, 2026-11-09]
- "Close it" means check first: read requirements, criteria and status history; a requirement added to an `implemented` feature moves it back to `implementing`; tick criteria in
  the release that proves them. [A: UI Studio "implementing", 2026-11-05]
- Status is the progress bar: attach a new bug or feature and set it in progress before analysis; `fixing` at start, `fixed` only after the release is verified, for every bug a
  release closes. The app moves feature status (the tool stops at `ready`); only the `status:` line of `overview.md` may be hand-edited (Boris, 2026-11-03).
  [A: Take the issue into work, 2026-11-09 | Move the bug status, 2026-11-03 | Feature status: the app, 2026-11-03]
- Never restore, stash or reset a file the lifecycle tools wrote (it records an "external edit, unverified"); copy it byte for byte and fix a wrong status through the tools with a
  reason. Read a record back after each record-tool write (a malformed parameter list can store stray markup). [A: BUG-107, 2026-11-08 | BUG-052, 2026-11-03]
- Integrations (GitHub, ...) are opt-in, off by default, active only with a folder open: off means no `gh` call, no polling, no UI change. Why: MarkView can be a plain Markdown
  viewer on one file. [A: Интеграции опциональны, 2026-09-26]
- When scope grows mid-release, stop the running build, write requirement and decision records first, extend `tasks/todo.md`, publish once; independent pure modules go to agents
  with a written contract, shared-file wiring stays with one author. [A: One release for a growing, 2026-11-05]
- Pace: after the focused suites and the build, open the PR, merge, release; run no more harnesses and wait on no more checks than he asked. When a template step ("wait for CI")
  conflicts with a standing rule, ask once and write the answer into the plan header. [A: A report's "Original description", 2026-11-08 | "Filters" means, 2026-11-08]

## 2. Git, worktrees and the PR flow

- Docs-only changes (README, `docs/`, `tasks/`, records) go straight to main (no branch, PR, bump or DMG), including docs another session left uncommitted: check `git diff --stat`
  is docs only, use a throwaway worktree of origin/main, never force. [A: Documentation goes straight, 2026-11-03 | Documentation always goes, 2026-11-05]
- Compare versions with `git show <ref>:path`, `git grep <ref>` or a worktree; never `git stash` or `git reset --hard` in the shared tree (a stash of an untracked file did nothing
  and the pop would have applied another session's stash; a reset wiped statuses). [A: Never use `git stash`, 2026-09-24 | Bug status is a merge event, 2026-11-02]
- Run a red harness from `git worktree add --detach <dir> origin/main` before chasing it, and remove that worktree only after the background work reading it has ended.
  [A: Real streams, real machines, 2026-11-04 | `pgrep -f`, 2026-11-10]
- Push once per PR, batch docs commits, add no workflow or build step unasked (on 2026-11-08 a push started nine workflows). Do not wait for CI before merging (Boris, 2026-11-04
  and 2026-11-08), but read `gh pr checks` within minutes and fix a red check at once. [A: Every push starts, 2026-11-08 | merging without waiting, 2026-11-08]
- After a push that prints "Internal Server Error" compare `git ls-remote … refs/heads/main` with HEAD; the exit status is not proof. Build fake keys in fixtures at run time
  (`"sk_" + "live_"`) so push protection stays quiet. [A: GitHub can reject a push, 2026-11-04 | Fake credentials, 2026-11-04]
- A shallow clone's oldest commit looks like a root with the whole tree added, so an unreadable file list is "unknown", never "everything"; choose "the last commit" by topology
  (`rev-list --first-parent`), never by timestamp. [A: BUG-106, 2026-11-07 | feature-3, 2026-11-08]
- Bug status moves at merge: write the PR body before queueing a branch, keep a merge driver out of a session shell (it dies with the session), tell Boris the sequential-PR shape
  once. Conflict-marker checks match `<<<<<<<` only at line start with a branch name. [A: Bug status is a merge event, 2026-11-02 | Conflict-resolution scripts, 2026-11-04]

## 3. Build, project file and CI

- After a hand edit of `project.pbxproj` run `plutil -lint` (must say OK), quote paths with `+`, give each new file its four entries; never run XcodeGen (retired, it rewrote every
  ID). Why: an unquoted `ControlToolRunner+Agents.swift` broke CI ("Unable to read project"). [A: A file added to project.pbxproj, 2026-10-25 | HSplitView ignores, 2026-09-26]
- Never call the environment broken from truncated output (`| head`): read the last lines and exit code for the clean tree and mine; the "CoreSimulator is out of date" warning is
  harmless. Without xcodebuild: `swiftc -parse-as-library` over `MarkView/**/*.swift`, Info.plist, ad-hoc codesign. [A: "Unable to read project", 2026-10-25]
- A new top-level page in `Resources/Editor` goes into the "Build Web Editor" script in `project.pbxproj`, or `Bundle.main.url` is nil and the web view is blank; after a build
  `ls <App>/Contents/Resources/Editor/`. [A: New files in Resources/Editor, 2026-09-24]
- The CI compiler is not the local one: three or more `+` operands with a ternary, `??` or closure fail "unable to type-check" on CI only; use `+=`, interpolation, a named closure
  with `-> String`, typed steps in hot loops. Push early so CI compiles the branch; compare a long CI step with earlier runs before calling it a hang.
  [A: GitHub's compiler, 2026-10-25 | The CI compiler is not the local, 2026-11-04]
- A change to a file in a `.github/workflows/*.yml` `paths:` runs every `bash tools/tests/...` line of that workflow before merge (a failing step hides the rest); a new tool also
  updates the tool-count tests and classification table. Why: PR #400 merged with two other workflows red. [A: Cockpit gate, 2026-11-14]
- A file that gains a dependency breaks every standalone suite that compiles it, far from the cause: `grep -l <file> tools/tests/*.sh`, run each, add the file or a stub to its
  script (SourceKit "cannot find type" is noise until a compile); a stand-in class in a test file needs the members the shipping code now calls. Run
  `./tools/tests/run.sh --changed` without `--tier`, and the gui tier once on the integration tip before a release.
  [A: A model file that gains, 2026-11-03 | a moved or re-wired file, 2026-11-15]

## 4. Testing: harnesses, real data, evidence

- A new check is evidence only if it fails without the fix: show it red on origin/main or under a deliberate mutation, in the same run as green; run a suspect check ten times.
  [A: Replacing a blocked script, 2026-11-07 | X-Ray comparison by date, 2026-11-08 | a defect visible in my own render, 2026-11-09]
- Run a new check or heuristic over every real unit (all prototypes, the person's snapshot, the reported file), choose thresholds on the real haystack and name the corpus; fixtures
  prove geometry, not text. Why: a lint that looked clean on 12 screens flagged 7 of 40 real ones.
  [A: Measure a heuristic, 2026-11-03 | A narrow rule needs, 2026-11-03 | A layout fixed on a clean, 2026-11-04 | A source map must be checked, 2026-10-31]
- Test an outside program's contract against the real program (a pty for a CLI, real `claude -p`/`codex exec`, the real stream-json): a stand-in proves only the app side, and check
  the state an action leaves behind. Verify on the tool, model and effort the app uses, with the real history, over several runs.
  [A: A stand-in that writes, 2026-11-03 | Check a prompt against the real, 2026-11-03 | "MarkView eats all resources", 2026-11-04]
- Assert the exact state against what the real consumer accepts: a test of what the code happens to produce pins the bug (`hasSuffix(".")`), and a check that accepts the failure
  state ("degraded") proves nothing. [A: A test value must keep, 2026-11-04 | UI Studio automatic repair, 2026-11-14]
- Do not pin facts that drift (a line number): derive them from the fixture at run time; run every harness that touches a changed module before committing; a harness compiled from
  the main tree runs OLD code, so compile from the worktree and check the first output. [A: Harness checks must not pin, 2026-09-30 | Prototype audit, 2026-11-03]
- "Known failure, not mine" is still a failure: run every suite at the start, write down the red ones, fix them in their own branch; find the commit that broke a test and read its
  message to decide test or app, and change the app only with approval. [A: five suites that were, 2026-11-08]
- Harness hygiene: `WKWebsiteDataStore.nonPersistent()` and two runs in a row; an empty `"${1:-}"` is absent, `git status` after a new harness; no `timeout` on macOS; quote `=====`
  in zsh. In `main.swift` declare top-level `let`s above the `Task`/`application.run()` entry (segfault otherwise); `orderOut`, not `close()`; a window-less WKWebView cannot
  snapshot; print unbuffered with named steps and a time limit.
  [A: five suites that were, 2026-11-08 | UI Studio automatic repair, 2026-11-14 | The CI compiler is not the local, 2026-11-04]
- Watch progress, not total time (stop after 120 s without a reported check, cap 20 min); give timing assertions a window; compare extracted text without white space; use a
  `window` marker plus DOM node identity, not `performance.timeOrigin`. The first CI run is part of the verification.
  [A: X-Ray comparison by date, 2026-11-08 | Beautiful PDF export, 2026-11-07 | A palette that reads, 2026-11-08]
- Feed awkward and oversized inputs: a 207 s recording (`isFinal` held only the last minute), overlapping folders and symlinks, damaged entries, long unbreakable labels and ids.
  [A: The final result, 2026-11-02 | a collection that is keyed, 2026-11-08 | New optional fields, 2026-11-04 | A layout fixed on a clean, 2026-11-04]
- Reproduce a layout bug on the real view: host the shipping view in a borderless `NSWindow` far outside the displays, read the frames of the AppKit hosts, write a PNG
  (`cacheDisplay`, `ImageRenderer`); gestures need `orderFrontRegardless()`. [A: A fixed sheet width, 2026-11-08 | BUG-107, 2026-11-08 | a drawing in a flexible, 2026-11-08]
- `cacheDisplay` renders no blur or compositing filter: judge only gradients, opacity, shadows. Motion without a screen: read `presentation()` twice, or render it twice and compare
  pixels; test Reduce Motion by swapping the `NSWorkspace` getter and posting the notification. [A: a picture from `cacheDisplay`, 2026-11-09]
- A harness that clicks through `window.sendEvent` depends on key-window state (the CI runner dropped every click): hit test and call `mouseDown`/`mouseUp` on the hit view; use a
  DOM click for session checks. [A: Harness clicks through, 2026-11-04]
- A "fixed" bug that returns: list every UI that edits the same state and read the stored data for which wrote it; for "not saved" read stored files and history first; when "this
  is not what I did", run the code on the real data before asking for examples.
  [A: A "fixed" bug reported, 2026-09-30 | A bug without a repro, 2026-09-30 | Data the person asked for, 2026-11-04]
- A separate process does not see the app's settings: read `~/Library/Preferences/com.markview.MarkView.plist` with `plistlib` and print one named key (it holds API keys); never
  `defaults read | grep` a suspected key; "key absent" from `defaults` is not proof. [A: A separate process does not, 2026-11-03 | Prototype audit, 2026-11-03]
- To prove "never starts X" make X impossible to start (binary absent) and read the tool's source for flags that promise "only X"; never `curl` a dev server a Studio session uses.
  [A: Proving "never starts X", 2026-10-01 | A model-written rule, 2026-11-04]

## 5. The app-probe and live checks (no visible windows, no crashes)

- Never drive UI in the user's live app: automate the Debug build in `/tmp/MarkViewDerivedData` or a scratch copy, confirm first which window and folder is key, and leave
  destructive actions (close, delete, discard) to the person. [A: Don't drive UI in the user's live app, 2026-09-24]
- A scratch copy has its own `PRODUCT_BUNDLE_IDENTIFIER`, a unique process name (System Events addresses by name), a throwaway project and a short `MARKVIEW_SOCKET_DIR` (`sun_path`
  holds 104 bytes); `HOME` alone does not move app data (the probe sets `HOME` and `CFFIXED_USER_HOME`). Drive it by pid through AX, never by coordinates.
  [A: Check a second instance, 2026-11-03 | A Unix socket path, 2026-10-25 | Driving a background test copy, 2026-09-27]
- Kill only a pid whose `ps -o command=` shows the scratch path, listed in the same command, never one remembered from an earlier turn (a launch test once killed Boris's app);
  clean up test files by identity (the session id the run reported), never by "small and recent".
  [A: Launch tests must never, 2026-09-26 | Check a second instance, 2026-11-03 | A stand-in that writes, 2026-11-03]
- Capture only the test window (`screencapture -l<id>`, id from `CGWindowListCopyWindowInfo` by pid), never full screen or `-R`; a blank occluded WebKit page is not a bug by
  itself. [A: Never take a full-screen, 2026-10-11 | Live checks without disturbing, 2026-10-01]
- Before saying "not checked in the app" run `tools/tests/app-probe` (alpha-0 windows, accessory policy, empty HOME, own socket dir; steps in its README): a hosted copy of one view
  is not the app (in the real pane the tile list was taller than the window). [A: drive the real app invisibly, 2026-11-09]
- The probe keeps the app inactive, so synthetic mouse events reach SwiftUI Buttons but not a `DragGesture`, wheel or pinch: rebuild such a gesture in a lab with the app activated,
  never activate the real app, list it as "not driven in the real app". `snap` shows model layers, `frame` what the render server shows.
  [A: The invisible probe cannot drive, 2026-11-10]
- A probe must never crash (a hidden window does not hide the system crash dialog): validate step arguments, pass `bridge-contract-tests` and `bridge-contract-web-tests` first, and
  after each run `ls -t ~/Library/Logs/DiagnosticReports | head -3` for a new `MarkView*.ips`. [A: a probed test copy crashed, 2026-11-15]
- A probe reads Keychain attributes, never a secret: the system prompt window is not hidden and the main thread waits behind it (Keychain reads belong off the main thread). `agy`
  keeps its sign-in in the Keychain: link only what a check needs. [A: A probe must never make, 2026-11-10 | Never run a signed-out test, 2026-11-14]
- Test a signed-out path with the output redacted from the first run, never print a login link or pasted code, and say in one line what the test is; an empty HOME means signed out
  for `agy`. [A: Never run a signed-out test, 2026-11-14]
- An environment-injected harness gates itself on `getprogname()`: applications the app launches inherit `DYLD_INSERT_LIBRARIES` (a fixture's windows went alpha 0). A blank picture
  of another process: read its env (`ps eww`) first. [A: An application the app launches, 2026-11-10]
- A blank or tiny snapshot of a window I just opened is a finding: run `windows`, read its frame, exercise every path twice (open, open again). `pick` is 0-based over visible
  windows: read the project name in each snapshot and run the script on the previous build. [A: An odd snapshot, 2026-11-10 | UI state belongs to a window, 2026-11-10]
- When window counts look odd, run the same steps on a baseline copy of the shipped build (`ditto`, new bundle id, ad-hoc codesign) before changing code and keep the log field that
  tells branches apart; afterwards `defaults delete`, remove `MarkView-<id>`, `lsregister -u`. [A: A file open already gets, 2026-11-02]
- Click each new control once in a second instance, and make sure its parent supplies every environment object it reads: a build and a screenshot run no actions.
  [A: A new control in a view, 2026-10-14]
- `pgrep -f`/`pkill -f` match their own command line (exit 144, a Monitor that never ends): wait by pid (`kill -0`) and kill the pid you started; a background script must not
  outlive the worktree it reads. [A: `pgrep -f`, 2026-11-10]
- Run probes few times and hidden, never in loops on his own application (Boris: "stop creating StrikeDesk windows"); `alphaValue` 0 stops page rendering, so check a hiding trick
  against the baseline. [A: A hidden "Script error.", 2026-11-04 | Data the person asked for, 2026-11-04]

## 6. Release and install

- Never quit, kill, restart or reinstall the running MarkView (Boris works in it with live terminals): build into `/tmp/MarkViewDerivedData` or `./release.sh` without `--install`
  and let him install. An install ends the Claude Code session in its terminal and any background agent: install only when none runs.
  [A: Never restart the user's, 2026-09-24 | Installing MarkView ends, 2026-11-04]
- Relaunch with `env -u NO_COLOR -u FORCE_COLOR open -a …`, never by running the binary from an agent shell (`NO_COLOR=1` turned every terminal black and white); when output
  "suddenly" changes read the app's env (`ps -E -ww -o command= -p <pid>`). [A: A launch from an agent shell, 2026-09-27]
- Before deleting other copies run `spctl -a -vvv -t exec` on the one that stays and check `xattr` for quarantine; `release.sh` notarizes with the `markview-notary` profile.
  [A: Keeping one installed copy, 2026-09-29]
- After every publish run `gh release view v<version>`: `gh release create` can fail with HTTP 500 while `release.sh` exits 0; rerun only that line from the same clean worktree.
  [A: `gh release create`, 2026-11-04]

## 7. Swift concurrency, processes and task ownership

- Never call `Process.waitUntilExit()` or run git synchronously on the main thread, and read the pipe concurrently with the wait (64 KB buffer deadlock); everything starts through
  `Subprocess`. Why: opening a 1,200-file folder hung. [A: Зависший UI, 2026-05-31]
- Process exit and pipe EOF have different owners: a bounded runner watches the exit apart from EOF, drains both streams without blocking and escalates an ignored SIGTERM; forked
  terminal children close unrelated descriptors. Test a child whose descendant keeps stdout open and a hung child. [A: Process completion and pipe EOF, 2026-10-29]
- A `terminationHandler` needs the `Process` retained by a process-wide owner, not an instance of a short-lived object; `Subprocess` holds it.
  [A: Process.terminationHandler требует, 2026-05-30]
- `/bin/sh -c "exec <cmd>"` changes the exit status of a compound command: run the line as given, put the process group on the shell (`POSIX_SPAWN_SETPGROUP`), `killpg`, pass the
  folder as `$1`. [A: `exec` in front of, 2026-11-04]
- `defer { busy = false }` has not run when the Task chains into a job guarded by the same flag: clear the flag before the chained call. A step whose caller needs its result waits
  for the running one; never "skip if already running". [A: `defer` in a Task, 2026-09-24 | "Skip if already running", 2026-10-04]
- Whatever starts behind a prompt or callback captures a generation and does nothing if it changed (microphone, stream callbacks, overlapping loads checked after every await); a
  cancellable timeout task returns on cancellation without resuming the NEXT waiter.
  [A: Cancel must reach async, 2026-09-26 | X-Ray comparison by date, 2026-11-08 | UI Studio automatic repair, 2026-11-14 | Understand answers and image, 2026-09-27]
- Recordings, streams and processes are owned by the model, not by a view's `@StateObject`; temp files are unique and deleted after use. [A: Долгоживущие вещи, 2026-09-26]
- A write to a non-blocking descriptor has an owner for the unsent part: keep order, finish on a write source (EINTR retry, wait on EAGAIN), never block the main thread. Why:
  prompts over 1 KB were cut at 1022 bytes. [A: Write to a PTY, 2026-09-26]
- Queue external requests (Finder open) durably and drain at every moment the receiver may become eligible; a notification is only a "check the queue" signal and never branches on
  "is a window visible". Verify with `open -n -a <DerivedData app> <path>` and a log grep. [A: Fire-and-forget notifications, 2026-09-17]
- A step that starts by itself after another is background work with a banner, never `busy`; later steps wait for earlier ones. [A: A simulation must answer, 2026-11-14]
- Loops over many files or lines that create Foundation objects run in `autoreleasepool` (8 MB chunks; measure peak memory with `/usr/bin/time -l`); do not hash large or binary
  files; skip build caches and worktrees. Why: 650 MB of logs peaked at 1.18 GB, then 92 MB. Work on every line of a child's output runs off the main actor, coalesced.
  [A: Scanning large files, 2026-09-26 | "MarkView eats all resources", 2026-11-04]
- Make a list unique where it is built if it will be keyed (`Dictionary(uniqueKeysWithValues:)` aborts on a repeat); read a crash report's faulting-thread frames first.
  [A: a collection that is keyed, 2026-11-08]
- Never dispatch on `Any` downcasts of collections (an empty array matches every `as? [T]`); tell booleans from numbers with `CFGetTypeID == CFBooleanGetTypeID()` (`NSNumber` 0 and
  1 match `is Bool`); `await manager?.activate() ?? "error"` turns success into the error when nil means success.
  [A: An empty array passes, 2026-10-24 | JSONSerialization numbers, 2026-09-26 | Optional-success closures, 2026-09-27]

## 8. UI: SwiftUI and AppKit

- A view that shows an object's state observes that object (`@ObservedObject`/`@EnvironmentObject`) and nested observables forward `objectWillChange`; an action over 0.5 s shows
  progress at once. [A: Прогресс не виден, 2026-09-26 | Optional-success closures, 2026-09-27]
- `.toolbar` content does not get the window's `environmentObject` (SIGTRAP at launch): pass objects as parameters, launch the built app after toolbar changes. Menu enabled/checked
  state comes from a value-typed `.focusedSceneValue`, not a property of a focused object. [A: Содержимое .toolbar, 2026-09-26 | Menu commands don't observe, 2026-09-24]
- A view that mirrors state which can change while it is unmounted reconciles from the state on appear (compare the one value that matters, not a derived string).
  [A: A change observer must not live, 2026-11-02]
- An edit has one owner: never mutate an `NSTextView` and its `inout` binding in one call (text flashed in and vanished); async text goes only to the originating window's first
  responder; an image-only paste needs `readablePasteboardTypes`.
  [A: Never edit a text view, 2026-09-26 | Cancel must reach async, 2026-09-26 | Understand answers and image, 2026-09-27]
- `HSplitView` ignores `idealWidth`: restore widths with `NSSplitView.setPosition` after first layout (`LeftPanelWidthKeeper`). Two flexible siblings split width equally: bound the
  secondary pane with `maxWidth`, give a sheet `idealWidth`/`idealHeight`. [A: HSplitView ignores, 2026-09-26 | BUG-107, 2026-11-08]
- Never let a data-driven label set a width: `fixedSize()` on such text is a latent overflow, a fixed-width frame centres the overflow and cuts both edges, a fixed-size drawing
  sets its container's minimum (measure an empty box, draw scaled in an overlay). Bound labels (`frame(maxWidth:)`, `lineLimit(1)`, `.help`) and test the widest data.
  [A: A fixed sheet width centres, 2026-11-08 | a drawing in a flexible, 2026-11-08]
- State one window's user can change lives in that window's model (`PanelLayout`, `@WindowStorage`), never in a shared `@AppStorage` (UserDefaults only seeds the next window);
  project data is keyed by the full path; window-scoped notifications carry the window (`post(_:for:)`, `isFor`); no `static var`/`.shared` holds what a window shows; web
  `localStorage` is shared too (`EditorWindowPrefs`). Test "the other window keeps its value" by reading the key in the second window AFTER the first changed it.
  [A: UI state belongs to a window, 2026-11-10 | @AppStorage is app-wide, 2026-09-27 | A file open already gets, 2026-11-02]
- A palette that reads global state cannot differ per window: publish it in the environment and set `NSWindow.appearance`; migrate mechanically with a masking script (dry run
  first) and the compiler as oracle. [A: A palette that reads, 2026-11-08]
- Never replace `NSWindow.contentViewController` of a window the person may have resized (it collapsed to 249 pt wide): keep one hosting controller and swap `rootView` with a new
  `.id`. [A: An odd snapshot, 2026-11-10]
- Use one shared component for repeated wiring (`DictationInput`, `IntakeAttachmentBar`); it must not need `workspaceManager` in the environment (sheets and panels lack it); for
  "make X everywhere" grep every place text goes to the assistant and list file and line first. [A: One shared component beats, 2026-11-10]
- A nested `LazyVGrid` below the fold crashed on the advertised `AXScrollToBottom`: use an eager `Layout` for bounded collections and invoke advertised scroll actions after
  resizing. [A: Exercise advertised, 2026-11-11]
- A new view maps the approved prototype's layout and behaviour onto the app's own tokens (read `:root`), labels primary actions visibly (▼ means fold, use "⋯" for a menu), shows
  by default what a reader can take in (dense AI relations only around the selection), and is looked at beside a neighbouring view on a folder of the person's size.
  [A: A new view uses, 2026-11-04 | The first picture decides, 2026-09-30]
- A diagram uses the room the window has: derive zoom from the width, scale text and lines together, size it from every quantity that fills it, show trigger, actor and what
  MarkView does beside each arrow; "no overlap" is not "enough room". [A: a transition diagram must, 2026-11-08 | a defect visible in my own render, 2026-11-09]
- A file the app itself puts outside the project (PR cache, temp copy) counts as part of the open project (`isFileInCurrentWorkspace`), or opening it switches the workspace.
  [A: Файл вне папки проекта, 2026-09-26]
- A popover or list that is a private part of a big view cannot be rendered alone: make it its own `View`; give a view that depends on a big session object the one function it
  needs. [A: a flow that is only data, 2026-11-09 | A field's height is measured, 2026-11-04]

## 9. WKWebView, the JS bridge and editor pages

- Check editor UI in real WebKit (off-screen `WKWebView` over a local server or scheme handler), not Chrome; an element toggled with `hidden` whose CSS sets `display` needs
  `[hidden]{display:none}`, with `!important` against `!important` libraries (CodeMirror). [A: Verify editor UI in WebKit, 2026-09-24]
- A flex item holding a canvas needs `min-width: 0`; a user-resizable field in a flex column needs `flex: none` and a plain `height` (`border-box`); fit a growing field last
  (twice, plus `ResizeObserver`), border included. [A: Confirm which panel, 2026-09-24 | A resizable field, 2026-11-05 | A field's height is measured, 2026-11-04]
- A hidden page has `visibilityState: hidden`: transitions and entrance animations stall. Add `* { transition: none !important }` before a screenshot; QA windows report visible
  occlusion while ordered in. Never pace work with timers in an off-screen web view (use a `MessageChannel`).
  [A: A field's height is measured, 2026-11-04 | Offscreen WebKit windows pause, 2026-11-11 | Beautiful PDF export, 2026-11-07]
- In a hidden page a node can lie under a panel or outside the viewport (expand, centre and pan before pointer tests), and a focused field refuses a snapshot overwrite (blur
  first). [A: Cleanup that compares, 2026-11-05 | A node card is built, 2026-11-04]
- A bare "Script error." has three causes: scripts loaded from per-file `file:` URLs (serve one origin via a `WKURLSchemeHandler`), our own injected script (a name declared as both
  `var` and `function`; try/catch recording the stack), and a runtime rethrowing the page's error with `setTimeout(throw)` (use `reportError`). A UI check waits a frame and asserts
  no `error` event. [A: "Script error." is WebKit, 2026-11-03 | A hidden "Script error.", 2026-11-04 | A runtime that calls, 2026-11-04]
- The app serves a resource the page cannot read at a URL (`markview-doc:`); the editor's text stays byte for byte what is on disk, an address rewritten for display keeps the
  author's value in a data attribute, and after finding such corruption search the person's repositories. [A: A document's text is never, 2026-11-03]
- A file kind the page may send is checked in Swift by its first bytes, never by name or the page's claim (SVG refused); a stored path is one relative path (no `..`, no scheme),
  validated first so a refusal changes nothing. [A: Cleanup that compares, 2026-11-05]
- Measure the round trip before promising an editable preview of a structured Markdown file (the converter replaced front matter by a table); text selected in the rendered view is
  not the Markdown source. [A: A resizable field, 2026-11-05 | Text selected in the rendered, 2026-09-27]
- Update the one element that holds a changed value (`entry.label.textContent`), never `textContent`/`innerHTML =` on a container that gained children; test every edit path with
  all parts present; give a new control its own class before its CSS (a copied `rm-desc` broke 15 checks); do not clear the value a cleanup function compares against.
  [A: A node card is built, 2026-11-04 | Cleanup that compares, 2026-11-05]
- Two screens of one page need their own state keys (`stateKey()`), clear mode-only state on enter and leave, and key a "do once" guard by everything that makes the work valid
  again. [A: X-Ray comparison by date, 2026-11-08]
- A render step whose cost grows with page size is paid per item (a `<style>` element restyles every element): draw in chunks with the body hidden (about 600 ms), measure "frozen"
  with a timer-gap meter, time the real reported file, check the other side of the bridge (per-block SQLite writes took 28.8 s under a lock).
  [A: A render step whose cost, 2026-11-07]
- A main-frame load blocked by a content rule list fails with `WebKitErrorDomain` 104 (report a policy block); `loadHTMLString` under a rule list is blank (serve from loopback); a
  blocked parser-inserted script fires `error` after `load` (install the stand-in when the tag enters the document) and an allowed address is never replaced.
  [A: A main-frame load blocked, 2026-11-04 | Replacing a blocked script, 2026-11-07]
- Zoom by scaling the container's bounds, not `pageZoom` (the CSS viewport must not change); a fragment-only navigation keeps the old document (load `about:blank` first,
  `StudioPageLoad`); a switch set in the current page is lost on the next page (keep it in the runtime config, reinstall the user script; replays crossing a page load run step by
  step and count `didCommit`). [A: Zoom a WKWebView, 2026-11-04 | UI Studio automatic repair, 2026-11-14 | A page loaded during recording, 2026-11-04]
- WebKit asks `decidePolicyFor` about a redirect target before `didReceiveServerRedirect` (take the "from" in `didStartProvisionalNavigation`); an unhandled rejection's
  `reason.stack` has no message line (add `name: message`). [A: WebKit and the UI Studio log, 2026-11-04 | UI Studio "implementing", 2026-11-05]
- Terminal OSC 8 links go through `Terminal.options.linkHandler` (plain URLs through WebLinksAddon): reserve Cmd+click, resolve relative links against the live cwd, and replay the
  emitter's exact bytes (BEL vs ST, `id=`) against the pre-fix page. [A: Terminal OSC 8, 2026-09-26 | Terminal escape-sequence tests, 2026-09-26]
- A sanitizer that strips attributes can break a library's output (KaTeX): allow what the library writes by property name, never by a pattern that rejects bad values. In PDF check
  text with `pdftotext` (the system font wrote U+0138 in place of a Cyrillic letter) and detect the language from running prose only. [A: Beautiful PDF export, 2026-11-07]

## 10. SQLite, stores, file writes and paths

- A column added to an existing table needs a migration (a new step at the end of `SemanticSchema.migrations`, `addMissingColumns`), tested on a copy of an old database;
  `CREATE TABLE IF NOT EXISTS` skips an existing table. [A: New columns need a migration, 2026-09-24]
- A stored Codable gets a lenient `init(from:)` (unknown values fall back, missing fields empty): one bad element fails the whole file and the store is replaced. Round-trip test
  every new field and load a file written before it. [A: New optional fields, 2026-11-04 | Themes: a new manifest field, 2026-11-03]
- A file both the person and the app edit: read-modify-write from disk at the moment of change; new files `.withoutOverwriting` with a number above every name on disk and every
  mention; background reads carry a generation counter; never recreate a deleted file; do not rewrite YAML that cannot be rewritten losslessly.
  [A: Файлы, которые правит, 2026-09-26 | Real streams, real machines, 2026-11-04]
- Data the person asked for outlives the next reopen and change: the next session opens on the state he built (per project, never committed); the app carries what does not change
  and the model returns only what it adds (never make it copy bulky data). [A: Data the person asked for must outlive, 2026-11-04]
- A save that removes a status or variant in use is two steps (the file, then the reassignment); a crash between leaves items readable as "unknown" and the next start finishes the
  move. [A: feature-3, 2026-11-08]
- A scripted edit reads into a variable, edits, writes once (`open(p,'w').write(open(p).read())` emptied a 4,500-line file), asserts `old in s` per replacement and checks
  `git diff --stat`; before deleting a span or a file list every declaration in it and grep each. [A: Scripted edits, 2026-10-01 | Range deletes by marker, 2026-09-24]
- Record a user-triggered event at the action with what is known then, never after an in-memory wait, and share one status rule across every entry into a state; for each automatic
  trigger find the code that produces the transition and prove it on live data. [A: A lifecycle event that waits, 2026-09-27 | Автоматическая фиксация, 2026-09-26]
- Never show or log an API response body or any part of a key (only presence and length): map HTTP status and the provider's identifier-shaped code to a sentence, a next step and a
  short tag. [A: Never show an API response, 2026-09-27 | Хардкод абсолютных путей, 2026-09-03]
- A tolerant parser accepts exactly the expected error (type and path of a requested field) and fails on everything else; read the real answer first and make a fake `gh` answer
  like the real one. Why: one NOT_FOUND field rejected 40 good ones. [A: An all-or-nothing guard, 2026-11-07]

## 11. AI assistants, prompts and CLIs

- Run assistant work headless through `CLICompletion`/`AIOperation` and let the app own the result: a schema, Swift validation (ids, edges, budget, paths that exist), a re-ask
  listing the problems, the app writes the file; a smaller true diagram beats a bigger guessed one. [A: A diagram is useful, 2026-10-07]
- A stateless loop puts the primary sources (his words, every recorded answer, the transcript) into every call; questions come from the feature's open decisions, in rounds with a
  recommended answer; log label, seconds, tokens. [A: A stateless AI loop, 2026-09-30]
- An AI step that settles something writes it into the artifact the next step reads, shows the reviewer settled items and "empty is expected", and gives it an "implementer decides"
  boundary; count what each round produced. [A: An AI loop must write, 2026-10-04]
- An empty or insubstantial answer is a failure: validate substance before caching, keep the previous result and say so. Optional AI detail never holds up a local analysis (build
  the outline first, cache by file signature, bound the explicit AI wait). [A: AI answers: an empty, 2026-09-29 | Optional AI detail must not, 2026-09-29]
- Code reads what names and exports tell (route files, folders), completely and in milliseconds; the model gives it meaning and its list is completed by the scan. A request that
  waits for a model answers in seconds ("preparing"); hand the model the file it would search for; count a deadline per attempt from when it gets a slot, never the queue.
  [A: Do not make a model find, 2026-11-04 | Application deadlines are shorter, 2026-11-04]
- A contract that never varies belongs to MarkView: code in a folder the assistant cannot write (zero-specificity `:where()` rules), never a prompt sentence or a patch appended to
  a model-owned file; baseline-neutral, applied wherever the site is built or opened. [A: A contract that never varies, 2026-11-03]
- Do not make the model emit large fixed code as escaped JSON; check whether a complete answer already parses before asking for more (Copilot over ACP streams its internal
  continuations as one answer); recover truncated files through small valid fragments. [A: Copilot over ACP, 2026-11-03 | Truncated prototype files, 2026-11-03]
- Size the result before designing the request (45 files cannot be one answer): fan out per unit with a router listing `remaining`; never discard what the model said (an empty
  change with a `summary` is an answer); replay the exact request on the real CLI. [A: BUG-051, 2026-11-03]
- When a prompt lets the assistant decline into a field, the caller acts on it or the prompt forbids it; split work by what each problem names; a repair that leaves problems says
  so in the header. [A: A repair path must not, 2026-11-03]
- A model-written rule is checked against the data it serves; prompts state coverage and the mock-up policy wherever they can refuse; a Swift check after preparation is the real
  guard; a schema field the assistant fills needs its meaning in the prompt and a validator. [A: A model-written rule, 2026-11-04 | A finding that blocks, 2026-11-14]
- State a required language by name from a deterministic recogniser (`QALanguage`) and check it on the real assistant over several runs; an open language lets the model pick.
  [A: Name the language, 2026-11-10 | BUG-052, 2026-11-03]
- A prompt that conditions on "uncommitted changes" lists what the app itself owns (`.dde/`, statuses it just set) as expected; verify with headless `claude -p` in a fixture repo.
  [A: Prompts that make the AI check git, 2026-09-27]
- Show small data whole (a shortened list made the assistant refuse), add a deterministic guard, and verify on the app's own tool, model, effort and history over several runs: a
  fix must not depend on the model. [A: "MarkView eats all resources", 2026-11-04]
- Headless `claude -p` needs `--allowedTools WebSearch,WebFetch` and its `permission_denials` read; Codex `error` events are not fatal (only `turn.failed`): unwrap the nested
  message and test model choices with a real `codex exec`. [A: Headless `claude -p`, 2026-09-27 | Codex "error" events, 2026-09-24]
- Never hard-code a path to an external CLI: settings override, candidates (every `~/.nvm/versions/node/*/bin`), then a login-shell `command -v`; configurable in the UI; "not
  found" names what, where and how to fix; check auth with `claude auth status`/`codex login status`; log in through an executable `.command` and `NSWorkspace.open`, not
  `NSAppleScript`; know what a CLI does signed out before polling it. [A: Хардкод абсолютных путей, 2026-09-03 | Never run a signed-out test, 2026-11-14]
- Do not depend on a client's process model (MCP discovery by ancestry): add a path that does not (the app's socket plus the agent's folder) and a one-command diagnosis; a shared
  daemon's cwd is not the agent's, so make the agent say its folder. [A: Don't tie a feature to, 2026-10-05 | A server's working folder, 2026-10-14]
- An operation started for the person reads the setting he made (`CLICompletion.Assistant.chosen`), not what a running session reports, and sends only the current session's turns.
  Open as of 2026-11-14: BUG-048 (`remember` writes a `/model` switch into the project setting).
  [A: An operation tied to a window, 2026-11-14 | Assistant memory must not, 2026-11-04]
- A progress line maps every `CLICompletion.Activity` case (test with both assistants) and always shows an elapsed clock; before "stuck" look at the process (`ps`,
  `/usr/bin/sample`); a refusal based on recent output waits for quiet. [A: A progress line must, 2026-11-10 | A status heuristic must give, 2026-10-25]
- Long prototype runs have explicit, optional deadlines (BUG-030: end on completion, Stop or a provider error; test ACP and native transports); count before trusting a summary (400
  of 891 files were sent) and hand the model original artefacts to copy verbatim. [A: Long prototype runs need, 2026-10-29 | BUG-050, a prototype, 2026-11-03]
- Distinguish the process host from the tool execution host; verify a read-then-edit in fresh and resumed threads, refresh saved context through the provider API, keep the native
  sandbox. [A: Verify remote edits, 2026-10-28]
- A line protocol over a model's stream gets its breaks from events that end a text block, tried on every backend's real stream; a status written at the start of a long run needs a
  way back when the run dies with the app. [A: Real streams, real machines, 2026-11-04]

## 12. Product areas: X-Ray, maps, Studios, workflow

- X-Ray: a file is a leaf (no file content in the map; the file viewer shows changes with the "why"); aggregation stops at `kind === 'file'`; a diff overlay shows the diff's own
  version or maps lines by content; a one-click open is gated on what the node is, not the tab.
  [A: PR X-Ray: файл, 2026-09-26 | Nodes inside files, 2026-09-24 | A loaded diff goes stale, 2026-09-24 | X-Ray comparison by date, 2026-11-08]
- Reproduce map layout bugs on the stored snapshot (`.dde/state.db`, shipping `CodeArchitecture.view`, hidden WKWebView or headless cytoscape-elk) and measure bounding boxes; count
  parts per layer before deciding what is "layout"; long unbreakable labels get `overflow-wrap: anywhere`; use a placement routine's returned size below it.
  [A: Layout bugs: replay, 2026-09-28 | A layout bug is reproduced, 2026-11-04 | A layout fixed on a clean, 2026-11-04]
- Enforce presentation thresholds in the shared node builder for every outline source (keep item ids and positions); a model path and a draft path that build one view agree on
  structure. [A: Normalize cached outlines, 2026-09-28 | A layout bug is reproduced, 2026-11-04]
- UI Studio simulation: describe how the application reads answers once (`envelopes`), never wrap what is already in its shape, make anything a button changes state plus a change
  event, review stored environments once when a field is added, and give an Electron renderer run as a page a simulated preload bridge (a no-op hands it proxies).
  [A: A simulation must answer, 2026-11-14]
- UI Studio dev server: its endpoints (lazy compilation, HMR, `*.hot-update.*`) pass, never simulated; framework data requests (`_rsc`, `next-action`) belong to it; Next 16 allows
  one `next dev` per folder; a past test clock breaks file watchers (webpack/Rspack/Rsbuild keep the real clock).
  [A: Framework data requests, 2026-11-04 | Next.js 16 refuses, 2026-11-04 | A test clock in the past, 2026-11-04 | A runtime that calls, 2026-11-04]
- UI Studio state: probe readiness by TCP connect, not by rendering the page; classify a dev overlay by the framework's own label and a build failure only from compile or bundle
  lines; a restore owns the state until it ends; a selection is a fingerprint, never a position.
  [A: A readiness probe must not, 2026-11-04 | A dev overlay is not, 2026-11-04 | A selection is identified, 2026-11-04]
- UI Studio repair: a route with a placeholder is a family of pages (never load or save it as prepared); module-loading failures are code or server, never data; "current" is a
  question about contracts only; a replacement test value keeps the shape libraries check (a signed JWT).
  [A: UI Studio automatic repair, 2026-11-14 | A test value must keep, 2026-11-04]
- Prototype Studio: "styled" is not "looks like the real app" (render both at one viewport, list the differences); pair "content exists" audits with a geometry check of clipping
  boxes and a check of file content (BUG-053); a unit's sync is "unknown", never "in sync", when its sources are not fully known; run an incremental sync once with the real
  assistant on a change that touches shared data.
  [A: "No longer raw HTML", 2026-11-03 | BUG-053, 2026-11-03 | Prototype audit, 2026-11-03 | Sync baseline, 2026-11-03 | Incremental sync, 2026-11-03]
- Moving a hard-coded table into data: move the old table first and run the unchanged suites, then grep every status literal (`== "closed"`, `isPastExplore`) and replace each with
  a role or workflow lookup; when code and a record disagree fix the record through MarkView and tell Boris. [A: feature-3, 2026-11-08 | a flow that is only data, 2026-11-09]
- A harness that drives UI by labels breaks with each wording change: update `tools/tests/cockpit-e2e` in the same change and give unlabeled controls an accessibility label.
  [A: A screen the person supervises, 2026-11-14]

## 13. Diagnosing hangs, performance and crashes

- A hang or beachball: `/usr/bin/sample <pid> 3` first and read thread 0; `ps -o %cpu,state` (0% and `S` is blocked, high CPU is a busy loop); use full paths `/usr/bin/sample`,
  `/usr/bin/log` (a zsh wrapper shadows the short names). Why: three guesses wasted cycles, the stack named `GitClient.refresh` at once. [A: Зависший UI, 2026-05-31]
- A slowness complaint: get the scale (seconds or minutes) and read timestamped logs before a hypothesis; a cause must explain the observed order of magnitude (parsing costs
  seconds; blocking and per-item `main.sync` cost minutes). [A: Диагностика перформанса, 2026-05-30]
- "Eats all resources": measure each process (`footprint <pid>`, `vmmap --summary`, `top -o cpu`, `*cpu_resource*.diag`) before blaming one: CPU reports first, then `sample`, then
  a benchmark of the suspect on a copy of real data; a loop over work items must not re-read a file; keep `markview_*` calls few while diagnosing MarkView.
  [A: "MarkView eats all resources", 2026-11-04 | For a slow or spinning app, 2026-11-09]
- Both processes idle while the run is slow means waiting: sample both; measure the cost model before changing a threading rule.
  [A: Beautiful PDF export, 2026-11-07 | A render step whose cost, 2026-11-07]
- When a report names a suspect, measure it before fixing; when a fix is scoped to one flow, grep the sibling flows that share the mechanism; trust no diagnosis (mine included)
  until the real collector ran on real data. [A: A guard fixed for one entry point, 2026-09-27 | BUG-106, 2026-11-07]
