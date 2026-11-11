# End-to-End QA (Scenarios, Web, Native and API Runners, Video, UX Review, Bugs, Cleanup)

End-to-End QA turns a goal ("a requester submits an expense and a manager approves it") into a branching
scenario, shows it in a visual editor, and checks the chosen branches against a running web application
or an installed native macOS application with one or more players, each in a browser or an application
instance of their own. The check is driven by the user's Claude Code or
Codex CLI. It records a video with subtitles that say what is done, where and why, reviews every new screen
as a person using the application would, and files a bug for each check that failed, was blocked or was
interrupted and for each defect the review finds.

Related module docs: [feature-workflow](feature-workflow.md), [editor-and-bridge](editor-and-bridge.md),
[ai-assistants-and-dictation](ai-assistants-and-dictation.md), [build-release-testing](build-release-testing.md).
The feature record is `docs/features/end-to-end-qa/` (requirements REQ-001..017, decisions DEC-001..026).

---

## 1. Scope of this release

Shipped: web applications (5.55.0) and native macOS applications. One scenario targets one type of
application (Q-009, DEC-007): web, native and HTTP API flows are separate scenarios. HTTP API checks are available alongside the screen runners (section 9). A native player launches the
installed application the person chose, reads and operates it through Accessibility and takes its
pictures through ScreenCaptureKit; both permissions are granted by the person in System Settings and the
Run panel says which one is missing. Old runs are cleaned up by a retention rule (section 8).

## 2. Files

| Layer | Files (`MarkView/Models/` unless noted) |
|---|---|
| Scenario model and rules | `QAScenario.swift` (nodes: action, check, alternative, failure; edges with conditions; actors, applications with review profiles, environments), `QAScenarioEdit.swift`, `QAPlan.swift` (branches, execution plan), `QAGate.swift` (approval; production needs an acknowledgement of the list of actions that change data), `QAGraphLayout.swift` |
| Storage | `QAStore.swift`: scenarios in `.markview/qa/scenarios/<id>.json` (a project asset, one file per scenario); runs in `.dde/qa/runs/<run-id>/` (`run.json`, `frames/N.png`, `branch-N.mp4`) with a self-writing `.gitignore` |
| Generation | `QAGeneration.swift` (prompt and schema), `QAGenerator.swift` (validate and retry through `CLICompletion`) |
| Run engine | `QARun.swift` (outcomes and the state machine), `QARunner.swift` (the loop), `QAActions.swift` (the actions the assistant may ask for and how they are validated), `QAEffort.swift` (measured counts, `QAFinding`) |
| Web player | `QAWebActor.swift` (`QAWebActor`, `QAWebDriverFactory`), `QACredentials.swift` (placeholders and scrubbing), `BrowserSession.swift` (optional website data store) |
| Native player | `QANativeTree.swift` (pure: the element model, the text the assistant reads, key parsing, measured evidence), `QANativeAccessibility.swift` (the Accessibility layer), `QANativeCapture.swift` (window pictures), `QANativeActor.swift` (`QANativeActor`, `QANativeError`), `QANativeFactory.swift` (`QANativeDriverFactory`, `QANativePermissions`) |
| HTTP API | `QAAPI.swift` (persisted request, JSON Pointer checks), `QAAPIClient.swift` (bounded HTTP transport, isolated sessions and captures), `QAAPIActor.swift` (driver and factory), `Views/QAAPIRequestEditor.swift` (editable request fields) |
| Assistant | `QARunAssistant.swift` (`QACLIAssistant`: one `CLICompletion` call per turn, effort `low`), `QALanguage.swift` (names the language of the scenario for the prompts) |
| Video | `QAFrameComposer.swift` (players side by side), `QAVideoWriter.swift` (H.264, subtitle band) |
| Review | `QAReview.swift` (prompt, schema, parsing, effort summary), `QAPageEvidence.swift` (in-page measurements) |
| Bugs | `QABugs.swift` (drafts), `QABugFiler.swift` (idempotent filing), `QAFeatureStoreBugSink.swift` (writes through `FeatureStore.createBug`) |
| Cleanup | `QARunRetention.swift` (pure rule), `QARunCleanup.swift` (applies it to the disk), `QAStore.swift` (`deleteRun`, `deleteRuns`, `sizeOfRuns`) |
| UI | `QAModel.swift`, `QARunModel.swift` (`@MainActor`), `Views/QAViews.swift` (editor, setup, run panel), `Views/QANativePermissionsView.swift`, `Views/QARunViews.swift` (live run), `Views/QARunReportViews.swift` (earlier runs, delete) |

The QA tab is a tab kind (`.qa`) opened by `WorkspaceManager.openQA()`. The editor is native SwiftUI over
the pure layered layout in `QAGraphLayout`, so no bridge message exists and the shipping editor
(`Resources/Editor/`) is untouched.

## 3. Scenario and plan

A scenario is a graph. A branch is a path from the start to a leaf; the person chooses which branches to
check and each chosen branch is a separate check that starts from the prepared baseline. A branch has a
condition (how to establish it, how to verify it). An environment (local, dev, production) gives each
application an address; an actor can name a saved browser login (host + user name). Passwords are never
in a scenario file.

`QAPlanner.make` turns the scenario, the environment and the logins that exist into an execution plan;
`QAGate` holds the approval of exactly that plan and loses it when the plan changes (DEC-002). Production
additionally requires acknowledging the list of steps that change data.

## 4. The run

`QARunner.run()` goes: baseline (preparation) → logins and accounts → branch conditions → steps. Per
branch, per step, it loops: observe the page, take a screenshot, measure the screen if it is new, ask the
assistant for the next action, perform it. Limits: no cap on the number of actions in a step; a step is given up when
the same action is chosen 4 times on an unchanged page (going in circles), after 3 failed actions in a row,
or after 2 unusable answers in a row. Cancelling marks the branch in progress interrupted and the ones not started uncovered.

Outcomes: passed, failed (the check did not hold), blocked (the run could not go on: login failed,
launch failed, baseline failed), interrupted (stopped), uncovered (not run). A failed baseline or login
is never reported as a failure of the application.

Players: `QAWebActor` hosts a `BrowserSession` with a non-persistent data store in an off-screen window,
so several players on one host do not share cookies. Actions go through `BrowserAgentExecutor`, with element
references `e12` taken from `data-mv-ref` attributes. Faults (a slow or failing request) are injected by
a document-start script wrapping `fetch` and `XMLHttpRequest`. The assistant writes `{{username}}` and
`{{password}}`; `QACredentials.fill` puts the real values in only on the way into the page, a placeholder
the player has no value for is refused, and everything that comes back is passed through
`QACredentials.scrub`. The Keychain is read in a detached task, never on the main thread.

The assistant is called only through `CLICompletion` (Claude: `-p --safe-mode … --json-schema`; Codex
attaches the screenshot). A run keeps and sends what it sees; the only rules are that a password field's
value is never read into the snapshot and a saved password stays in the Keychain (DEC-023).

The native player (`QANativeActor`, DEC-008, DEC-012) takes the bundle identifier of the application from
the environment, launches it with `NSWorkspace` as an instance of its own (one per player, so two players
can be signed in to the same application at once; an application that refuses a second instance is
reported as such, and the person's own running copy is never touched) and drives it by process id.
`QANativeAccessibility` walks the window and the menu bar into the pure model of `QANativeTree`, which
renders the text the assistant reads: elements that can be operated carry references `e12` that are
numbered afresh at every look; the value of a secure field is never read. Actions: click (Accessibility
press, falling back to a mouse click at the element's centre), fill (focus and set the value, with the
same `{{username}}`/`{{password}}` handling as the web player), select (open the pop-up, choose the item),
scroll, key (`Enter`, `cmd+n`) and wait; opening an address and sending a request are refused. Every
Accessibility call runs on a serial queue with a 2 second timeout, so an application that hangs cannot
hang MarkView. Players act in turns: with `bringToFront` on, the player's application is activated
before it is looked at or operated, because SwiftUI controls ignore background clicks. `close()`
terminates only the process this player launched. A missing Accessibility or Screen Recording permission
is checked before anything is launched and is reported by name.

## 5. Video and live view

`QARunModel` receives the runner's events through an `AsyncStream`. A web player's pictures are page
snapshots; a native player's are the latest frame of its application window from an `SCStream` (a
desktop-independent window filter, so the window may be covered; macOS 13 compatible, DEC-017). For each branch it writes
`branch-N.mp4`: the players side by side, one frame per change, a band below with the current subtitle
(the one-line what/where/why the assistant gives with every action). The language of the lines, and of the review's findings, is named in the
prompts (`QALanguage` recognises it from the scenario's own texts), because asking for "the language of the step" alone came back in other languages. Recording is on by default and a
checkbox in the Run panel switches it off (`UserDefaults` `qaRecordVideo`). The live view
(`QALiveRunView`) shows the players, a feed of the same lines, the findings with a thumbnail, a
confirmation banner when a production step needs a yes, and per-branch results with a Video button.

## 6. UX review

After each new screen of a step (depth `screens`, the default), or at the end of each step (`steps`), or
never (`off`; `UserDefaults` `qaReviewDepth`), one CLI call reviews the screenshot with the page text, the
measurements (for a web page: tiny text, weak contrast, clipped content, small targets, sideways scroll, unnamed
controls, skipped headings; for a native window: small targets, unnamed controls, elements past the window
edge) and the **measured** effort (clicks, fields, scrolls, page loads, key presses,
screens, time). At most 40 reviews per run; a screen already reviewed (same address and structure) is
not reviewed again. The screen is labelled "Step in progress" or "Step just performed" so a result that is
not on a mid-step screen yet is never reported as missing, and the titles already reported are listed so
nothing is said twice. A finding has a kind, a severity, a concrete proposal and `isDefect`; defects become
bugs, everything else stays a suggestion in the report. The end of each branch shows what it cost a person
and the steps that cost the most.

## 7. Bugs

At the end of a run `QABugDrafts.drafts` makes one report per failed, blocked or interrupted check
(severity high, medium, low) and per defect finding. The key (`qa_key` in the front matter) is the run and
the branch or finding, so filing twice creates nothing new. `QABugFiler` reads the existing reports before
writing, files through `FeatureStore.createBug` in the workflow's "Not started" status, and copies each
finding's frame into the bug's `assets/` folder. The report names the recording of its own branch (a file
on this Mac, because `.dde/` is not committed) and the time in it.

For an application with the administration profile the review also gets measured speed and automation
evidence: the slowest requests of the screen with their times (Performance API, paths without query
strings) and the count of controls with no identifier, name, test attribute or label.

## 8. Cleanup of runs

A run leaves `run.json`, frames and one video per branch. When a new run starts,
`QARunCleanup.prune` deletes the older runs of the scenario except the newest 5 (the new run counts as
one) and every run a filed bug names in its `qa_key` (DEC-025, REQ-016); a run in progress is never
deleted, and when the bug reports cannot be read nothing is deleted. The earlier-runs list has "Delete
run" and "Delete all runs of this scenario…", each after a confirmation that says how many runs and how
much disk. Ids are validated and a folder that leads out of `.dde/qa/runs/` is refused. Files are removed,
not moved to the Trash.

## 9. Tests

Standalone `swiftc` suites, no XCTest: `tools/tests/qa-tests.sh` (model, plan, gate, store, machine, runner
with a made-up browser and assistant, credentials), `qa-video-tests.sh`, `qa-review-tests.sh`,
`qa-evidence-web-tests.sh` (the measuring script in a real WKWebView), `qa-bugs-tests.sh`,
`qa-native-tests.sh` (the tree text, keys and evidence, then a live part that drives a small AppKit
application, alone and as two players in two instances; `QA_NATIVE_LIVE=0` skips the live part) and `qa-retention-tests.sh`. The fixture
applications are `Tests/Fixtures/qa-demo/` (`python3 server.py --port 8765`: two users, shared state) and
`Tests/Fixtures/qa-native-demo/` (`build.sh <folder>` builds it; bundle `com.markview.qa-native-demo`). The
end-to-end check of the real app is `tools/tests/app-probe/run.sh` with `PROBE_AI=1`, which links the
AI CLI's login into the probe's empty home; never let a probe read a Keychain item (a system prompt opens
on the real screen).

## 10. Not built yet

- Mixing web and native applications in one scenario (Q-009 answered: no).
- An HTTP/REST service as a third application type (Q-011, open).
- Replaying resolved steps without the assistant (a step cache); every re-run asks the assistant again.

## 9. HTTP API scenarios

Choose **HTTP API** in New scenario, describe the backend flow, and attach an
OpenAPI/Swagger contract or API documentation. The generator also reads the
project's routes, validation, auth handlers and tests. It proposes positive and
negative branches with concrete request templates, not just prose. Generation
never executes requests. `QAGeneration.schema(for:)` includes the serialized
request object only for API proposals; validation and retry reject malformed or
missing requests. The existing web/native schema stays unchanged.

Each step's API editor saves its method, path, headers, body, expected HTTP
statuses, timeout (1–120 seconds), JSON equality assertions and captures.
JSON paths are RFC 6901 pointers (`/items/0/id`; `~1` escapes `/`, `~0` escapes `~`).
Expected values are JSON literals (`true`, `3`, `"Alice"`, `null`). An empty request
path checks the same actor/service's previous response without sending again.
A write must be an action marked as changing data or unknown; checks and
read-only nodes cannot send POST/PUT/PATCH/DELETE.

A capture names a value from a response for later `{{name}}` substitution in a
path, header or body. `{{name.json}}` inserts an escaped JSON literal without
surrounding quotes; `{{username.json}}` / `{{password.json}}` do the same for saved
credentials. Authentication is an explicit request step: choosing a login supplies
credentials but sends no implicit request. Capture a login token with Secret on,
then send `Authorization: Bearer {{token}}`. Cookies and captures are isolated by
actor and service, and discarded between branches. No cross-client variable sharing
is implied; keep a create/read/update/delete flow on one actor/service.

`QARunner` executes each saved API request once through `QAAPIExecuting`; no
assistant chooses the request or its verdict during replay. Status/JSON/capture
mismatches fail the branch. Missing variables, connection errors, timeouts and
responses above 2 MiB block it. Stop cancels the in-flight request and interrupts
the branch; cancellation during request creation is covered by a race check.
Expected negative statuses pass. Redirects remain responses under test and are
never followed, preventing credential forwarding and implicit write replays.
All requests must stay on the configured HTTP(S) origin (scheme, host and port).

The live feed and archived timeline retain request templates, HTTP statuses,
response evidence (at most 16,000 characters) and timings. Assertions use the full
bounded response. Request headers/bodies are omitted from evidence; saved passwords,
secret captures and common authentication fields are removed from response text.
API runs skip video and screen review and retain the existing approval,
production confirmation, outcome, archive, retention and bug-filing paths.

Verification: `tools/tests/qa-api-tests.sh` runs the real client and runner against
`Tests/Fixtures/qa-api-demo`, including the retained real-assistant proposal. Other
QA suites cover shared behavior and web/native regressions. For native live checks
from a worktree under `/tmp`, set `QA_NATIVE_FIXTURE_ROOT` to a regular local build
folder, because Launch Services does not register apps beneath temporary folders.
