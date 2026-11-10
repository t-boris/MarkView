# End-to-End QA (Scenarios, Web Runner, Video, UX Review, Bugs)

End-to-End QA turns a goal ("a requester submits an expense and a manager approves it") into a branching
scenario, shows it in a visual editor, and checks the chosen branches against a running web application
with one or more players, each in a browser of their own. The check is driven by the user's Claude Code or
Codex CLI. It records a video with subtitles that say what is done, where and why, reviews every new screen
as a person using the application would, and files a bug for each check that failed, was blocked or was
interrupted and for each defect the review finds.

Related module docs: [feature-workflow](feature-workflow.md), [editor-and-bridge](editor-and-bridge.md),
[ai-assistants-and-dictation](ai-assistants-and-dictation.md), [build-release-testing](build-release-testing.md).
The feature record is `docs/features/end-to-end-qa/` (requirements REQ-001..009, decisions DEC-001..023).

---

## 1. Scope of this release

Shipped: web applications. A scenario can describe a native macOS application (the editor has a Web /
macOS app switch and the plan, gate and bug rules cover both), but the native player (launching the app,
driving it through Accessibility, recording it with ScreenCaptureKit) is not built yet. Starting a check of
a native application says so and blocks the branch; it never reports a pass.

## 2. Files

| Layer | Files (`MarkView/Models/` unless noted) |
|---|---|
| Scenario model and rules | `QAScenario.swift` (nodes: action, check, alternative, failure; edges with conditions; actors, applications with review profiles, environments), `QAScenarioEdit.swift`, `QAPlan.swift` (branches, execution plan), `QAGate.swift` (approval; production needs an acknowledgement of the list of actions that change data), `QAGraphLayout.swift` |
| Storage | `QAStore.swift`: scenarios in `.markview/qa/scenarios/<id>.json` (a project asset, one file per scenario); runs in `.dde/qa/runs/<run-id>/` (`run.json`, `frames/N.png`, `branch-N.mp4`) with a self-writing `.gitignore` |
| Generation | `QAGeneration.swift` (prompt and schema), `QAGenerator.swift` (validate and retry through `CLICompletion`) |
| Run engine | `QARun.swift` (outcomes and the state machine), `QARunner.swift` (the loop), `QAActions.swift` (the actions the assistant may ask for and how they are validated), `QAEffort.swift` (measured counts, `QAFinding`) |
| Web player | `QAWebActor.swift` (`QAWebActor`, `QAWebDriverFactory`), `QACredentials.swift` (placeholders and scrubbing), `BrowserSession.swift` (optional website data store) |
| Assistant | `QARunAssistant.swift` (`QACLIAssistant`: one `CLICompletion` call per turn, effort `low`) |
| Video | `QAFrameComposer.swift` (players side by side), `QAVideoWriter.swift` (H.264, subtitle band) |
| Review | `QAReview.swift` (prompt, schema, parsing, effort summary), `QAPageEvidence.swift` (in-page measurements) |
| Bugs | `QABugs.swift` (drafts), `QABugFiler.swift` (idempotent filing), `QAFeatureStoreBugSink.swift` (writes through `FeatureStore.createBug`) |
| UI | `QAModel.swift`, `QARunModel.swift` (`@MainActor`), `Views/QAViews.swift` (editor, setup, run panel), `Views/QARunViews.swift` (live run) |

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
assistant for the next action, perform it. Limits: 12 actions per step, 3 failed actions, 2 unusable
answers. Cancelling marks the branch in progress interrupted and the ones not started uncovered.

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

## 5. Video and live view

`QARunModel` receives the runner's events through an `AsyncStream`. For each branch it writes
`branch-N.mp4`: the players side by side, one frame per change, a band below with the current subtitle
(the one-line what/where/why the assistant gives with every action). Recording is on by default and a
checkbox in the Run panel switches it off (`UserDefaults` `qaRecordVideo`). The live view
(`QALiveRunView`) shows the players, a feed of the same lines, the findings with a thumbnail, a
confirmation banner when a production step needs a yes, and per-branch results with a Video button.

## 6. UX review

After each new screen of a step (depth `screens`, the default), or at the end of each step (`steps`), or
never (`off`; `UserDefaults` `qaReviewDepth`), one CLI call reviews the screenshot with the page text, the
in-page measurements (tiny text, weak contrast, clipped content, small targets, sideways scroll, unnamed
controls, skipped headings) and the **measured** effort (clicks, fields, scrolls, page loads, key presses,
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

## 8. Tests

Standalone `swiftc` suites, no XCTest: `tools/tests/qa-tests.sh` (model, plan, gate, store, machine, runner
with a made-up browser and assistant, credentials), `qa-video-tests.sh`, `qa-review-tests.sh`,
`qa-evidence-web-tests.sh` (the measuring script in a real WKWebView), `qa-bugs-tests.sh`. The fixture
application is `Tests/Fixtures/qa-demo/` (`python3 server.py --port 8765`: two users, shared state). The
end-to-end check of the real app is `tools/tests/app-probe/run.sh` with `PROBE_AI=1`, which links the
AI CLI's login into the probe's empty home; never let a probe read a Keychain item (a system prompt opens
on the real screen).

## 9. Not built yet

- Native macOS players (one app instance per actor, in turns; Accessibility; ScreenCaptureKit).
- Mixing web and native applications in one scenario (Q-009, recommended no).
