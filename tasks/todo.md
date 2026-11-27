# Every agent call uses the agent's own parallel work (2026-11-26)

Goal from Boris: check every place that calls an agent (Claude Code, Codex, Antigravity, Copilot; buttons included) and call each one
optimally: when the task has independent parts, run them in parallel (Claude: subagents, a workflow for list-shaped work), or let the
agent create the parallel calls itself; Codex and Antigravity have their own mechanisms and settings.

## Audit (2026-11-26, code and the installed CLIs)

- 119 one-shot runs (`AIOperation` -> `CLICompletion`), 16 prompts sent into agent sessions (`AITerminalsController.sendToAssistant`),
  about 30 user actions that call the assistant several times. Outside managed Cockpit runs no prompt mentions subagents or parallel
  work; `AgentLaunchCapabilities.interactiveDelegation` is never read; `cockpitDelegation` is read only by `CockpitSession`.
- Gap: a plain Cockpit plan shows "Delegation to subagents" and the planner may mark `delegate`, but `CockpitSession` passes delegation
  only to managed (feature) runs, so the agent is told "Do not delegate".
- Mechanisms (CLI versions on this Mac; docs checked 2026-11-26):
  - Claude Code 2.1.332: subagents through the `Agent` tool (not "Task" any more); a dynamic workflow starts when the prompt says
    "use a workflow" (not in `-p`), without approval under bypass permissions; size is the person's `workflowSizeGuideline`.
  - Codex 0.172: subagents are on by default (`agents.enabled`) but start only after a direct request; they inherit the sandbox and
    approvals.
  - Antigravity 1.5.18: the agent starts subagents with its `invoke_subagent` tool (built-ins `research`, `browser`, `self`);
    `/run-workflow` asks to approve its script unless the permission preset allows it.
  - Copilot 1.0.114: `/fleet` only tells the agent to split the work into todos and run the independent ones as parallel subagents;
    no setting turns it on; `--fleet` does not work with `--acp` (one-shot runs).
  - Cline 3.0.74: no subagent mechanism.
- One-shot runs cannot delegate today: Claude gets only Read/Grep/Glob, Copilot `view grep glob`, Cline plan mode.

## Plan

Phase 1 (PR 1): interactive sessions, where the agent itself can run parallel work.
- [x] Provider: `parallelWork` replaces `cockpitDelegation` (the mechanism in words + the sentence that asks for it for a task with
      independent parts, and a stronger one for a list of independent items: Claude "use a workflow", Codex an explicit request to
      spawn one subagent per item, Antigravity `invoke_subagent`, Copilot parallel subagents as /fleet does). Cline: none.
- [x] Every send: Implement with AI, Fix with AI, a goal via `markview_agent_send`, the bug basket (no more "for each bug in turn"),
      Resolve conflicts, PR "fix all" and review tasks, CI failure fix, GitHub issue implement, Deployments discovery, prototype handoff.
- [x] Cockpit: a plain plan honours "Delegation to subagents" and the step's `delegate` like a managed run; the planner hears the
      mechanisms in every plan.
- [x] Tests: prompt tests per provider and per send; Cockpit hosted tests; one live run per assistant in a scratch repository that
      shows the subagents were started (Claude, Codex, Antigravity; Copilot not run: quota exhausted).
Phase 2 (PR 2): one-shot runs, where MarkView runs the independent calls itself.
- [x] Independent calls of one action run concurrently with a small bound (document translation chunks, QA screen reviews, UI Studio
      screens, X-Ray book parts and scenarios, intake attachments, Book PDF chapters, Insight "Explore all"); calls that depend on
      each other stay in order. Done for translation, Book PDF passages and paragraphs, X-Ray scenarios, attachments; the rest stay
      in order or were already concurrent (see the review).
- [x] A read-only run over many files may use read-only subagents where the CLI supports them: moved to phase 3 (the goal asks for
      it; the probes show it stays read-only).
- [x] One release at the end, minor bump.
Phase 3 (PR 3): a one-shot run that may read files can hand independent reads to the CLI's own subagents (the goal's "or let the
agent create the parallel calls itself"); probes on 2026-11-26 decided each CLI:
- [x] Claude: `Agent` joins Read/Grep/Glob when the run may read files (probe: two Explore subagents at once, only the session's
      tools, a schema answer still arrives); the stream parser keeps the Agent tool's input out of the answer and still shows the
      subagents' reads.
- [x] Codex: subagent tools off in one-shot runs (`-c agents.enabled=false`): an `--ephemeral` exec has no rollout for a child to
      load ("collab spawn failed ... no rollout", v1 and v2), so every spawn fails and costs a turn; Codex already runs independent
      reads as parallel tool calls (probe: both `cat`s started before either ended). Dropping `--ephemeral` would store document
      contents in `~/.codex/sessions` and make `resume --last` in the AI panel open a one-shot run.
- [x] Antigravity: no change; print mode already starts `invoke_subagent` subagents side by side and the deny list holds inside
      them (probe: a subagent's `write_file` was denied, no file written).
- [x] Copilot: unchanged (`--available-tools view grep glob` leaves out its subagent tool); the quota is exhausted for every model, so
      adding it cannot be verified; after the quota resets. Cline: no mechanism.
- [x] Tests: hosted launch and parser tests (a recorded Claude stream with two subagents); one live run of the app's own path per
      changed CLI. Minor bump, one release.

## Review (2026-11-26)

- Phase 1: PR #452 merged as 2d17c917 (7.9.0): `AssistantProvider.parallelWork` + `ParallelWork.parts/.items` in every prompt sent
  into an agent session, built for the terminal that receives it; Cockpit plain plans delegate marked steps when the switch is on.
  Live: Claude Code `-p` started two Agent subagents, interactive Claude Code started a workflow on "use a workflow", Codex `exec`
  started two child threads, Antigravity `-p` started two `self` subagents. Copilot not run (monthly quota exhausted; its configured
  model `claude-sonnet-4.5` is no longer available).
- Phase 2: PR #453 merged as 084c192c (7.10.0): `SideBySide.map` (MarkViewCore) and `CLICompletion.sideBySide = 3`; side by side
  now: Translate document sections, Book PDF passages and shortened paragraphs, X-Ray automatic scenario traces, new-feature
  attachments (sources still made in order). `PrototypeAI.sideBySide` runs on the helper (its own task-group loop deleted).
  Already concurrent before: X-Ray book chapters (4) and the parts of the X-Ray code analysis. Left in order on purpose: UI Studio
  screens (scenario names depend on the screens written), QA reviews (already-reported findings and numbering), Insight "Explore
  all" (one current node and task), Insight "Decide all" (chunks must agree, one key).
- Evidence for phase 2: Core tests (157), new hosted tests that fail with the limit set to 1, 37 hosted tests of the touched files,
  4 gui suites, `book-pdf-live` with Claude (translation 227 → 195 words, 50% shortening 227 → 126), and one live X-Ray run on a
  fixture through a temporary uncommitted hosted check (3 scenarios traced together, +12 s → +21/22/24 s).
- Open for Boris (1) was decided by phase 3 (the goal asks for it): read-only subagents in one-shot runs. Probe: `claude -p --tools Read,Grep,Glob,Agent` started two subagents
  at once, each had only Agent/Glob/Grep/Read and could not write a file, so it stays read-only; not switched on because the heavy
  runs (X-Ray code analysis) are already split by MarkView and need exact `file:line` evidence that subagent summaries may lose, and
  every run would spend more tokens. (2) DEC-033: plans made outside Build keep "Delegation to subagents" off by default.
- Found on the way: BUG-131 (a Markdown attachment's copy is read as a second source with the same id), recorded, not fixed.
- Phase 3: PR #455 merged as f915a9a5 (7.11.0): Claude one-shot runs with a folder get `Read,Grep,Glob,Agent`; the stream parser keeps
  the Agent tool's input out of the answer (before, a subagent's task reached `answerDelta` and the answer counter); Codex one-shot
  runs turn subagent tools off (`-c agents.enabled=false`). Evidence: a hosted test (tools, Codex flag, a recorded two-subagent
  stream through the parser) that fails with the old parser filter; live through `CLICompletion.run` on a three-file fixture
  (temporary hosted check, not committed): Claude asked for subagents 14 s, not asked 7 s, Codex 8 s with three `cat`s started
  together and no spawn attempt; in the red run the streamed answer showed "Starting three subagents in parallel" and their tasks.
  Antigravity unchanged (already starts subagents under its deny list, verified); Copilot unchanged and not run (quota).
- Phase 4: PR #456 merged as 1bc1ec99 (7.12.0): every new Cockpit plan starts with "Delegation to subagents" on
  (`CockpitControls.newPlan`; DEC-038 proposed, extends DEC-033); unreadable controls keep the restrictive default. Evidence: the
  real-window routing test asserts it and fails with the old default; 21 Cockpit managed-run hosted tests.
- Release: v7.12.0 published 2026-11-27 (contains 7.11.0) after Boris restored the `markview-notary` profile; notarized, codesign
  and spctl accepted; DMG copied to build/. Not installed.
- Boris 2026-11-27: skip the Copilot CLI agent; accept DEC-038; Copilot Cockpit must be optimal too. Its agent calls inside a step
  are covered (planner and supervisor one-shot runs can start subagents, step agents delegate by default); its steps still run one
  at a time. Boris chose "spec first, then build": feature `cockpit-runs-independent-plan-steps-side-by-side` (REQ-001..006,
  DEC-001..003, Q-001 blocking, Q-002), status draft, awaiting his review. Found on the way: BUG-132 (with Fix bugs on, a
  verification step's source changes are not audited).
- Copilot (open, quota; every offered model answers "exceeded your monthly quota", checked again with six low-cost ones): the
  one-shot profile disables its parallel tools `task`, `read_agent`, `write_agent`, `list_agents`, `run_dynamic_workflow` and
  `dynamic_workflows_manage` (its "Disabled tools" notice, printed before any model call; all marked `safe` in its session
  records), but no recorded session ever ran them, so how its subagents obey `--available-tools` and ACP permission
  requests is unknown; add `task` to the ACP one-shot profile only after a live run once the monthly quota resets.
- CI: PR #453's build job failed on a new warning (unused `addTaskUnlessCancelled` result) and an unused import in `SideBySide.swift`;
  fixed in PR #454 (ba250238, 7.10.1). PR #452's build job timed out in the unused-import step (107 recompiled files, 35 min); the
  same check run locally over every changed source of both PRs finds nothing.

## Phase 5: Cockpit runs independent plan steps side by side (2026-11-27)

Boris approved the spec `cockpit-runs-independent-plan-steps-side-by-side` (REQ-001..008, DEC-001..003; Q-001: a "Parallel steps"
switch, on by default; Q-002: a managed run reviews with two agents at once, in this feature). BUG-132 went first (PR #457, 7.12.1).
Branch `feat/cockpit-parallel-steps` (worktree `../MarkView-parallel-steps`), one PR, minor bump, one release for the batch.

- [x] Model: `CockpitStep.parallelGroup` and `CockpitControls.parallelSteps` (both left out of the JSON when empty/off, so old plans
      keep their fingerprints; `newPlan` turns the switch on, `affectsSteps` counts it); `CockpitPlan.group(containing:)`,
      `members(from:)`, `parallelGroups`, `normalizeGroups()` (plain plan: 2 to `CLICompletion.sideBySide` adjacent members, no
      prerequisite, recovery, QA scenario or last step; managed: reviews only), called by parse and every edit; `ungroupStep` moves the
      step after its group; duplicate inserts the copy after the group.
- [x] Planner: schema `group`, `CockpitPlanning.groupRule` in the prompt only with the switch on and only for a plain plan, parse keeps
      a label only with the switch on.
- [x] Managed compose: with the switch on and a second reviewer (an agent that is neither the implementer nor the reviewer), two
      review steps in group "review"; findings absorbed inside one save; `keepOneReview` when the switch goes off.
- [x] Workflow (Go): `Step.Group`, `StepTask.GroupMembers`, `Start.Kept`; behind `GetVersion("parallel-step-groups")` a valid group
      runs its members from `Current` to the group's end at once, results in plan order at the end, stop/pause cancels all, an
      activity error cancels the rest, a failed prerequisite member pauses and Retry runs the failed members again; `group_test.go`.
- [x] Record (`CockpitRun`): `currentMembers`, `complete(stepID:)`; a member's result waits in `groupResults` until the group ends,
      then all are appended in plan order; pause/retry/restart/continue (keeps the members that passed, `keptMembers`) for groups;
      refusals and signals name their step (`stepSignals`, `quietestStep`).
- [x] Execution: a clock, meter and time-limit watch per running step; a group adds its wall-clock time (`busySince`, DEC-003);
      results saved by step id; the reconciliation skips member results saved before the group ended; per-step activity.
- [x] Session: one `CockpitAgentAttempt` per task (`makeAttempt`); progress, fix cycles, gate calls and surviving processes routed by
      step; `CockpitGroupAudit`: one "before" picture for the group and the "after" picture when every member has ended or given up,
      members held to `ChangeRule.group` whatever Fix bugs says (REQ-005).
- [x] Views: the "Parallel steps" guardrail, controls and approval summaries; group bar, chip and "Run on its own" on the step card;
      "Start from" offers only a group's first member; run header, flight path, flight strip, run list and failure banners show every
      running member.
- [x] Tests: Go workflow (`group_test.go`), hosted `CockpitParallelStepsHostTests` (12) and
      `CockpitRuntimeIntegrationHostTests/testGroupMembersRunTogetherThroughThePackagedRuntime` (added to
      `cockpit-runtime-integration-tests.sh`); docs, build, lint, suites.
- [x] PR, merge, release with 7.12.1, statuses.

## Review (Phase 5)

- Version 7.13.0 (minor). Clean Debug build: 0 warnings (`build-warnings.sh` with the app and package logs). `architecture-lint.sh`
  passes, SwiftLint 49 of baseline 49.
- Go: `go vet`, `gofmt -l` clean, `go test -count=1 .` passes; with groups switched off five group tests fail (red check).
- Hosted: the 12 new tests, every Cockpit test of `EditorHostTests` (16), `CockpitManagedRunHostTests` (22) and the runtime
  integration suite (2 tests, 85 s) pass; `swift test` 157 tests; `run.sh --tier pure` 9 suites.
- The end-to-end test drives the packaged runtime and `CockpitExecution`: the two members overlap, the quick one ends first and its
  result is still second, the next step starts after both, each member gets only the results from before the group, and the run's
  time is under 3 s for members of 2 s and 1.2 s.
- Not checked in the app by hand: the plan screen (switch, group bar, "Run on its own", "Start from"), the run screen with two
  members, the two reviews of a managed run with real agents, and an app restart in the middle of a group.
- Delivered 2026-11-27: PR #458 merged (20624bec); v7.13.0 released from origin/main (also carries 7.12.1, BUG-132): notarized,
  stapled, `spctl` accepted, Latest; copy in `build/MarkView-7.13.0.dmg`. Not installed. Feature status in-review. PR #457's
  `hosted-tests (3)` failed on `testPrototypeAuditInHeadlessChrome` (headless Chrome, unrelated); the rerun passed, BUG-132 done.
- 7.13.1 (PR #459, cd49f263): #458's `+` chains with ternaries/closures did not type-check on CI's Xcode 26.6 (main red: build,
  hosted-build, cockpit, backdrop); rewritten in typed steps, texts unchanged; on #459 hosted-build, cockpit, backdrop and every
  hosted shard pass. Released as v7.13.1.

## Phase 6: the rest of the call sites (2026-11-27)

The goal's check asked for every call site, not only the ones Phases 1-5 changed. Counted on 9477785d with grep:
51 `AIOperation` construction sites in 36 files (some are wrappers that many actions share: `FeatureAssistant.run(key)`,
`ArchitectureStore.xrayCall`, `DiagramAI.generate`), 13 `sendToAssistant` prompts into agent sessions (every one passes a
`ParallelWork` shape since Phase 1), 4 `ParallelWork.ask` calls, the Cockpit's own prompts (`parallelWork?.mechanism` in
`CockpitSession` and `CockpitPlan`). Each action that makes more than one call was read along its path and put in one class:

| Class | Actions |
|---|---|
| Already side by side before Phase 6 | Translate (sections), Book PDF (passages, paragraphs), X-Ray scenario traces, new-feature attachments (`SideBySide.map`, 3); Research map inquiries, report diagrams and translation batches (task groups, 3), Insight sections (5), codebase audit documents (3); Cockpit groups of read-only steps and a managed run's two reviews (Phase 5) |
| Made side by side in Phase 6 (PR #460, 7.14.0) | X-Ray book parts; apply settlements (requirements + overview in one window of 4); code explainer rating beside its keyword search; audit document beside its diagram; Book PDF title and labels beside the chapters; prototype files of a cut-off answer |
| Kept in order: the next call reads the last one's answer | X-Ray Analyze steps (scan, describe, link, rate), QA reviews (deduplication and numbering), Insight "Explore all" (one current node, levels), "Decide all" (chunks re-read the feature, one run key), the parts of one prototype file, a chapter's shortening after its translation (renderer DOM) |
| Kept in order: shared state | UI Studio screens (the saved-scenario list needs unique names) |
| One call per action | the rest (code question, selection action, change review, deployments ask, GitHub explain failure per run, PR review, finding, link, describe, ...) |

Per CLI (probes recorded in Phase 2 above):
- Claude Code: one-shot runs with a readable folder get the `Agent` tool; prompts into sessions ask for subagents, and for a list
  "use a workflow".
- Codex: one-shot runs pass `-c agents.enabled=false` because an `--ephemeral` exec cannot start a child ("no rollout"); the exec
  already reads files as parallel tool calls. Sessions are told to start subagents with a direct request (Codex starts them only then).
- Antigravity: `-p` already starts subagents with `invoke_subagent` (probe); sessions get its mechanism sentence.
- Copilot CLI: skipped as Boris asked ("skip copilot agent but not markview copilot"); its one-shot tools leave out the agent tools.
- MarkView's Cockpit ("Copilot Cockpit"): plain and managed plans delegate marked steps (DEC-038, on by default) and run groups of
  read-only steps together (Phase 5); `Copilot Cockpit Checks` on main passed for cd49f263.

Open, for Boris:
- X-Ray Analyze: the book stage could overlap naming, but both rewrite the whole snapshot and its ratings, so it needs a merge
  design and would run up to about 8 assistant processes at once.
- New feature intake: the request's fact extraction could run beside the attachments', but the attachments then lose the request's
  facts as context (a change of what they are asked).

## Review (Phase 6)

- Version 7.14.0 (minor). Six hosted tests hold the calls until they are in flight together; each fails on `origin/main`'s file
  restored with `git show` (peak 1 or 2 where 2 or 3 is expected) and passes on the new one: `testXRayBookPartsAreDescribedSideBySide`,
  `testApplyingASettlementRewritesRequirementsAndOverviewSideBySide`, `testCodeRatingRunsBesideItsKeywordSearch`,
  `testAuditDocumentAndItsDiagramAreWrittenSideBySide`, `testBookExportTranslatesTheTitleAndLabelsWhileTheChaptersAreRewritten`,
  the shell-file peak in `PrototypeDeadlineHostTests`.
- Every hosted test of the touched test files (26 + 19 + 5 + 2, 0 failures), `prototype-deadline-tests`, `--tier pure` (9 suites),
  `architecture-lint`, SwiftLint 49/49, a clean Debug build with 0 warnings, unused imports (baseline 1 lower: `PrototypeAI.swift`).
- PR #460 merged (9477785d); v7.14.0 released from origin/main (2026-11-27): notarized, stapled, `spctl` accepted, Latest; copy in
  `build/MarkView-7.14.0.dmg`. Not installed, not checked by hand in the app with a real assistant.

## Phase 7: a per-site audit and the limits it found (2026-11-27)

Three read-only agents put every call site in a row (site, the button behind it, calls per action, readable folder, verdict,
file:line evidence): 44 rows for X-Ray/Book/Workspace, 82 for Lifecycle/Insight/Research/QA/Prototype, 15 one-shot rows for UI
Studio/Cockpit/GitHub/Deployments/ProjectOps and every prompt into a session (11 `sendToAssistant` starts, 4 `ParallelWork.ask`,
the Cockpit step prompt, 7 other paths). Findings beyond Phase 6:
- Unbounded: X-Ray zoom importance rating starts one call per drawn container with no limit (`XRayFilterStore.swift:126-149`);
  files dropped or chosen on the Sources panel start one fact extraction each (`FeaturePanelSourceViews.swift:103`).
- Sequential although independent: Book PDF chapters (`BookPDFExportModel.swift:101-109`; each chapter already runs 3 at a time).
- Gap: `markview_agent_send` adds the parallel-work sentence only with `goal: true` (`ControlToolRunner+Agents.swift:154-161`).
- Codex probe (0.172, 2026-11-27): a non-ephemeral `exec` starts subagents that run at the same time (children 45.7-56.0 s and
  49.5-67.2 s); `codex delete --force <parent>` removes the parent and its children (files and state rows); `resume --last` skips
  exec sessions unless `--include-non-interactive`. Needs Boris: one-shot runs would write a session for the run's length.

Plan (one PR, 7.15.0):
- [x] `SideBySide.Slots` (MarkViewCore): one limit shared by runs that start at different times, waiting in order, a cancelled
      waiter leaves without a slot; package tests.
- [x] X-Ray zoom rating through the store's slots (`CLICompletion.sideBySide`); hosted test red on the old file.
- [x] Fact extraction through the feature assistant's slots, so the Sources panel and attachments share 3; hosted test red on old.
- [x] Book PDF chapters side by side, every passage call through one export's slots (3 in all); hosted test red on old.
- [x] `markview_agent_send` `work: parts|items` appends the agent's parallel-work sentence to a task prompt.
- [x] Bump, build, lints, tests, PR, merge, release; then ask Boris the open decisions.
- [x] The per-site tables are in `docs/architecture/assistant-call-sites.md`.

## Review (Phase 7)

- Version 7.15.0 (minor). `Slots` runs on `OSAllocatedUnfairLock`: the first version cancelled a waiter through an unowned `Task`,
  which the `unowned-task` lint refuses. Package: 159 tests, the two `Slots` tests six times in a row.
- Red on the old behavior, green now: `testZoomRatingsShareTheStoreSlots` (old peak 8), `testSourcesAddedTogetherShareTheFactSlots`
  (old peak 5), `testBookExportRewritesShortChaptersSideBySide` (chapters one at a time: peak 1); new
  `testAgentSendAsksForParallelWorkOnlyForATaskOrAGoal`. Every hosted test of the touched files plus `XRayContentHostTests`,
  `ControlToolRunnerTests`, `RemoteBrowserHostTests`: 41, 0 failures; `remote-browser-tests`, `--tier pure` (9), `architecture-lint`,
  SwiftLint 49/49, clean build 0 warnings, unused imports at baseline. Not run: `book-pdf-live` (real assistant).
- PR #461 merged (c3e69c69). 7.14.0's CI: PR #460 `hosted-tests (1)` (`UIStudioSessionHostTests.testSession`, 181 s, "SIM-05") and
  `(3)` (`testRealFeatureFlowGitHubCheckoutWithLocalFixture`, "Every blocked fixture process must end") failed and both pass here
  (136 s and 1 s); main's `build` timed out in the unused-import analyzer on `ArchitectureStore.swift` (300 s limit; 87 s here, the
  same before #460, about 298 s on the PR's runner).
- Released https://github.com/t-boris/MarkView/releases/tag/v7.15.0 (Latest, notarized, `spctl` accepted, `codesign` ok, version
  7.15.0); DMG `build/MarkView-7.15.0.dmg` (sha256 633af917...). Not installed; not checked by hand in the app (zooming with the
  Importance overlay, adding several sources at once, a book export with short chapters).

Kept in order, with the evidence the agents found: UI Studio refill batches (the next batch's prompt is built from the seed the
last one wrote, `UIStudioEnvironmentMapper.swift:819`, `:836`), "Fix problems" (each fix reloads the page, `UIStudioRepairing.swift:141`),
project-operations discovery (the web call is built from the first answer's unknowns, `ProjectOperationDiscoveryService.swift:76-83`),
Decide all (`FeatureAI.swift:1302-1327`), QA reviews (`QARunModel.swift:535`, `:556`), Explore all levels (`InsightSession.swift:351`),
intake request facts (accepted facts reach the attachments' context, `FeatureIngest.swift:110-113`), prototype thin-screen repairs
(each prompt holds the site with the previous repair, `PrototypeAI.swift:901`).

## Phase 8: Boris's answers to the open decisions (2026-11-27)

Boris: Codex one-shot calls start subagents and the session is deleted afterwards; UI Studio screens, QA run branches (web and API
apps), the X-Ray Analyze book stage and Insight "Explore all" siblings run side by side; the data-dependent sites stay in order.
One PR per change, one release at the end (memory: one final release for the batch).

- [x] A. Codex one-shot subagents (`feat/codex-one-shot-subagents`, PR #462 merged 04b306e1, 7.16.0). With a readable folder: no `--ephemeral`, no
      `agents.enabled=false`, the instructions ask for subagents where parts are independent. The run reports Codex's
      `thread.started` id (`CompletionSink.onSession`, only when `CompletionLaunch.keepsSession`); a marker file
      (`Application Support/MarkView/assistant-sessions/`, tool + id, our pid) lives until `codex delete --force <id>` succeeds or the
      rollout is gone; the delete runs after every end (answer, error, timeout, cancel) in an awaited detached task; markers of dead
      processes are swept at launch. The AI panel's Codex activity and answered-model readers skip `source: exec` rollouts. Fixture:
      `assistant-cli-timeout.py` emits `thread.started` and records `delete`; tests for answer, cancel, timeout, no folder, the sweep.
      Live (real codex 0.172, the app's own command line): three independent modules, 30 s, four `collab_tool_call` (`wait`)
      items in the stream, the session stored before `KeptSessions.delete` and gone after; through `CLICompletion.run` two runs
      (8 s and 29 s) left no rollout and an empty note folder.
- [x] B. UI Studio background screens: requests side by side, saves in order (PR #464 merged afca9072, 7.17.0). The source check
      stays right before the write against the request-start snapshot, so an answer that waited for earlier screens is still
      refused if its files changed (a review finding, red with the check at answer time). DEC-014 / REQ-021 reworded through the
      MarkView tools (criterion 3 left unticked: not seen in the app).
- [x] C. QA run branches side by side for web and API apps. Boris (2026-11-27): one at a time for native (launch and attach) and
      for a scenario with a baseline or selected branches with a state or data condition; one Stop gives one "QA interrupted" bug
      per run naming the interrupted branches; `QAFinding.branch` (optional) in the same PR so a bug links the right video.
      PR #468 merged 3b34a641, 7.21.0. Review round: feed lines carry the branch label (the player tile's) while branches run
      side by side, and the `noBaseline` warning says the branches share the app's data. Found on main and filed, not fixed:
      BUG-133 (a stopped run drafts its "QA interrupted" bug, but `QABugFiler.file` refuses it in the cancelled task). REQ-005 /
      DEC-010 reworded through the MarkView tools; REQ-005's interrupted criterion is unticked until BUG-133 is fixed.
- [x] D. X-Ray Analyze: the book stage beside naming, each stage applying its own fields to the live snapshot; one
      `SideBySide.Slots(limit: 4)` per Analyze (today's peak) instead of 8. PR #466 merged 14fd6d2e, 7.19.0; two hosted tests
      (both landing orders) red on the old store; the Book's counts kept in `bookProgress` until step 4.
- [x] F. `/goal` for every agent (Boris, 2026-11-27, asked after the parallel work): PR #467 merged feaed9ca, 7.20.0. Checked
      on the installed CLIs: Codex 0.172 `/goal` (4000-character objective, its TUI moves a longer one to `goal-objective.md`),
      Antigravity 1.5.18 `/goal` (seen in its command list in a hidden terminal, no Enter pressed), Copilot 1.0.114 `/autopilot`.
      Bug fixes and baskets now go as a goal to all four; Antigravity's feature and agent_send goals too; Cline keeps the plain
      request. Not run live with a real bug.
- [x] G. The CI failure of main at 7.15.0 (`testSlotsAreFreedOnErrorsAndCancelledWaitersLeave`, sleeps outlasted on the runner):
      PR #463 merged 893cdffa, test-only; the Slots tests hold their runs on gates.
- [x] E. Insight "Explore all": siblings side by side, 3 node pipelines at once across depths; Boris (2026-11-27): sections stay
      at 5 per node (up to 15 processes). PR #465 merged 2aee9349, 7.18.0: one `runPipeline` (five copies and the uncalled
      `retryCurrent` deleted), own breadcrumbs per page, ready-only snapshots, and `cancel()` now stops the walk (it went on after
      the tab closed: a bug found while reading). Not tested: the 50 MB eviction guard (needs >50 MB of buffers).
- [x] Release once after the last PR: v7.21.0 (https://github.com/t-boris/MarkView/releases/tag/v7.21.0, Latest, notarized, DMG
      sha256 5cd23acd…, copy in build/); records, lessons, memory; report with the PR links.

### Review (Phase 8)

- Delivered: #462 (7.16.0), #463 (tests), #464 (7.17.0), #465 (7.18.0), #466 (7.19.0), #467 (7.20.0), #468 (7.21.0); one release.
- Built by four agents in parallel worktrees from design notes; each change was reviewed before its PR, and two came back:
  UI Studio's source check had moved to answer time (an answer that waits behind earlier screens could save stale sources), and
  QA's interleaved feed lines named no branch. Both fixed with a red test before merging.
- Not checked in the real app: every side-by-side site, the Codex subagents through a button, the goal commands with a real bug.

# BUG-130: a whole Cockpit run stops at a discovery QA step (2026-11-26)

Boris asked for items 1, 2a and 3 of the analysis of run CF9C64A9 (vivaa-platform) in one PR. Cause chain: the QA runner's snapshot
does not list a React row that opens with a mouse click (`<tr onClick>`), so the branch ends blocked/elementNotFound; the workflow
pauses on every failed step (the planner is told only a prerequisite pauses); the pause shows the agent's long report and no filed bugs.
Branch `fix/bug-130-cockpit-continues-past-failed-steps` (worktree `../MarkView-bug-130`), minor bump (new behaviour), release.

## Plan

- [x] 1. Snapshot (`BrowserAgentExecutor.Scripts.snapshot`): list the outermost visible pointer-cursor element that is not a control,
      not inside one and not a label, as `clickable`; clicking it by ref works. Page evidence (`QAPageEvidence`): a `mouseOnly` tally
      (pointer cursor, no control role, not focusable) in the summary, `isClean`, the parser, the decoder and the review's "nothing flagged".
- [x] 2a. Workflow (`workflow.go`, behind `GetVersion`): a failed step that is not a prerequisite is recorded and the run goes on; a
      prerequisite still pauses (recovery unchanged). `CockpitRun.completeCurrent` mirrors it; a finished run with failed steps says so
      (phase "Finished with failures", the outcome banner, the list, the notification); a step failure while the run goes on is notified.
      Planner prompt and step prompt say what a failed non-prerequisite means. Managed runs are unchanged (their steps are prerequisites).
- [x] 3. `CockpitQAAttempt`: the step detail starts with the QA result; a failed QA names branch, node, block reason and reason, the
      bugs QA filed (new `QARunModel.filedBugIDs`) go into the step's progress.bugs and the needed input.
- [x] Tests: Go workflow tests (continue, prerequisite still pauses), hosted tests (record, phase, notice, QA text, snapshot pointer
      row, page evidence), runtime integration, pure tier, lints. Decision record for 2a (Boris's choice).

## Review (2026-11-26)

- PR #451 merged as e4db7aaa, version 7.8.0, released as https://github.com/t-boris/MarkView/releases/tag/v7.8.0 (Latest; signed,
  notarized, `spctl` accepted; Build & Release of the merge commit green). DMG also in `build/MarkView-7.8.0.dmg`. Not installed.
  DEC-029 (accepted) records 2a.
- Verified locally: Go `go test ./...` (red first on the old workflow); 5 new hosted tests (the snapshot and evidence tests red on the old
  scripts); all 81 Cockpit/QA/Browser hosted tests; `cockpit-runtime-integration-tests` with a new BUG-130 block through the packaged
  worker; `qa-web-fault-tests`; `remote-browser-tests`; Debug build; pure tier (9/9); architecture lint; SwiftLint 49 = baseline.
- Not run: `qa-native-tests` (live). Not checked by hand: a real Cockpit run in vivaa that goes past a failed QA step, and the QA runner
  clicking the real Vendor applications row (item 4, the vivaa row fix itself, was not part of this PR).
- BUG-130 was set `done` by MarkView 5 s after it was filed, from PR #436 (an older `bug-130` branch); only Boris can reopen it.

# BUG-129: Cockpit stops at recoverable CI blockers (2026-11-25)

Goal from Boris: reproduce, find the root cause, fix and verify BUG-129. BQ-1 answered: the plan was launched directly in Cockpit
(BQ-2 exact message and BQ-3 saved plan stay open). Answers of 2026-11-25 (binding): (1) recovery of the CI step is deterministic:
`parse` attaches it to a prerequisite that checks CI; (2) when repair needs source changes and Fix bugs is off, ask specifically
(warning before approval, a precise "input needed" text on the pause), the controls stay the person's; (3) both paths (direct plan and
managed Build -> Cockpit run) in one release. One PR (one finding, two paths), patch bump, release.
Branch `fix/bug-129-cockpit-ci-recovery` (worktree `../MarkView-bug-129`).

## Root cause (static; no real run available)
- Direct plan: recovery is optional in the planner prompt; `CockpitPlanning.parse` attaches it only when the model supplied one, so
  the first failed CI attempt pauses the run (`CockpitRun.completeCurrent`). With Fix bugs off (the default) the step prompt tells the
  agent not to change source and the audit fails any edit, so the agent can only report "cannot pass CI".
- Managed run: `CockpitManagedRun.compose` adds the "CI is green" step as a verification (DEC-036: no source edits) without recovery,
  while the default CI instruction says "fix failures".

## Plan
- [x] Red tests first (hosted): CI prerequisite without recovery gets one on parse (Fix bugs on); none when off; failed CI gate with
      Fix bugs off pauses with a specific input text; managed `.checks` step has bounded recovery; a recovery attempt may change source.
- [x] Direct path: `CockpitStep.verifiesCI`, default CI-repair recovery, planner prompt, approval advisory, specific pause text.
- [x] Managed path: recovery on the `.checks` step, writable recovery attempt, step brief and instruction no longer contradict, DEC-037.
- [x] Verify: Debug build, hosted Cockpit tests, Go workflow tests, pure tier, architecture lint, SwiftLint ratchet.
- [x] PR, merge, release, install on request; add Boris's answers to BUG-129 `## Clarifications`.

# Source-grounded process graphs in X-Ray (2026-11-25)

Branch `feat/xray-process-graph`, based on `93df066b`, submitted through the contributor fork.

- [x] Add a validated process model with forks, joins, conditional paths, explicit returns and nested groups.
- [x] Compile the core model and run 10 standalone Swift behavior checks; add 16 package test cases.
- [x] Generate and persist source-grounded scenarios through the existing X-Ray assistant boundary.
- [x] Read bounded source excerpts off the main thread and keep source explanations paired with the selected block.
- [x] Add the Process view with orthogonal routing, separate return corridors, drill-down, zoom and pan.
- [x] Verify the shipping web editor with 41 interaction checks over a 74-block, three-level fixture.
- [x] Run 130 layout checks, the pure suites, changed-source checks, editor type checking and architecture lint.
- [x] Add a hosted WebKit regression using the same native graph projection and web checks.
- [x] Run full application compilation and XCTest on a runner with Xcode; keep the pull request as a draft until verified.

Local verification constraints: Command Line Tools is selected, full Xcode is unavailable, and `swift test` cannot import XCTest.
The core module itself compiled. Fork CI cannot start because GitHub reports an account billing issue.
The pure architecture-lint suite required system Python because the Homebrew Python expat extension cannot load.
Full app compilation and XCTest remain unverified; the installed application has not been replaced.
The upstream account has read access; a contributor cannot merge or publish an upstream release.

## Review (7.7.1)
- Red first: 3 new hosted tests failed with 13 assertion failures on a behavior-neutral stub; they pass with the fix. 33 Cockpit hosted tests,
  `cockpit-runtime-integration-tests`, pure tier 9/9, architecture lint, SwiftLint ratchet 49/49 passed. PR #450 merged as 9a49a136; release v7.7.1
  notarized and stapled (Latest); `Build & Release` and `Copilot Cockpit Checks` on 9a49a136 succeeded, `CI` was still running at the time of writing.
- Decision DEC-037 (agent-aware-implementation-runs) is `proposed`, not accepted: the managed repair may write whatever Fix bugs says.
- Not verified: a real Cockpit run against a failing GitHub PR (no affected run or repository available); the advisory banner on the plan screen
  was not looked at in the app; BQ-2/BQ-3 stay unanswered, so the cause of the reported run is inferred from the code.
- Process miss: the bug stayed in `backlog` until Boris asked (see tasks/lessons.md, 2026-11-25).

# BUG-127: welcome backdrops restart their animation on unrelated display callbacks (2026-11-25, 7.4.1)

Boris: "почини" after the main run of PR #438 failed twice in `WelcomeScreenHostTests` (aurora 0.0 %, then bugs 0 of 0).
Branch `fix/bug-127-welcome-backdrop-restarts` (worktree `../MarkView-welcome-frames`), one PR, patch bump, release.

- [x] Evidence: tree of 77ff8e8a = PR head (green there); locally aurora changes 3.6 % in 1.5 s (threshold 0.2 %), frames are
      deterministic over five rounds; posting `accessibilityDisplayOptionsDidChange` mid-measurement reproduces the CI aurora message.
- [x] Red test first: another display option and a colour space change at the same scale each rebuilt the backdrop (built 1 more times).
- [x] Fix: `BackdropHostView` records the scale and motion setting it built with and rebuilds only when one changes.
- [x] The frames checks name a rebuild during the measurement in their failure detail.
- [x] Build, lints, suites, PR, CI, merge, release 7.4.1: Debug build, architecture lint, SwiftLint 50/50, pure tier 8/8,
      welcome-screen-tests and qa-web-fault-tests, swift test 136/136; PR #439 checks 12/12 (hosted-tests (4) passed, 109 s);
      merged as f32474da; main CI 45543491759 green in all 12 jobs; release v7.4.1 notarized, Latest.

## Review (7.4.1)
- MarkView marked BUG-127 done at 03:46, before PR #439 merged, from PR #433 (`fix/bug-127-agents-panel-drag`, another
  agent's branch with no record) and PR #438 (the related feature): PRs #433-#436 used bug ids 127-130 that never got records.
- Not fixed here (separate findings): the test process keeps ~180 closed windows alive (one notification costs 0.57 s);
  after the 7.4.0 reinstall 4 of 9 windows were missing because they never entered `windowSessions.json`.

# Agent-aware implementation runs (2026-11-24, goal from Boris: implement docs/features/agent-aware-implementation-runs)

Branch `feat/agent-aware-implementation-runs` (worktree `../MarkView-agent-aware-runs`), one PR, minor version bump, release.
Binding records: Q-001 (B: recommend + override), Q-002 (C: delivery through merge and release), Q-003 (A: sequential steps,
in-step delegation), DEC-011..013, DEC-027..031, F-001..F-005 resolutions, and DEC-032 (asked 2026-11-24: risk acceptance only for
acceptance-criterion findings; project-rule findings need a verified fix). The Temporal workflow stays as it is: a managed run continues
by starting a new workflow on the same run record from the step evidence selects.

## Plan (plan issues I-1..I-7)
- [x] I-1 Launch advice in Build: `ImplementationLaunch` (Lifecycle) recommends direct or Cockpit from the plan issues and the
      checklist, with reasons and DoD/project-rule conflicts; the Definition of Done sheet offers both actions, Enter = recommended.
- [x] I-1 Feature drafts: `CockpitDraftStore` (`.dde/cockpit/drafts/<slug>.json`); the session opens, prepares, saves and switches
      drafts without touching other features' drafts or runs; a planning blocker offers an explicit direct handoff.
- [x] I-1/I-5 Managed plan builder (`CockpitManagedRun.compose`): planner writes implementation steps only; MarkView adds branch,
      tests, review, fix, re-verify, version, PR, CI, merge, release, other checklist items and a final verification (Skip omitted,
      Ask gated, Require items become success criteria).
- [x] I-2 Approval separate from Start; `CockpitAdmission` keeps at most one unfinished run per project (main-actor reservation plus
      saved runs), names the blocking run and keeps the approval; End run for a saved unfinished run (DEC-034).
- [x] I-2 Evidence-based start and continuation (DEC-027, DEC-035): `CockpitManagedRun.firstUnsupported`; implementation marked
      started only when the first step of the run begins.
- [x] I-3 Capabilities per launch profile (installed CLI, MarkView tools, full-access arguments, provider delegation) offered to the
      planner and re-checked at Start; delegation only where supported and the control allows (DEC-033); delegates reported by the step.
- [x] I-4 Delegate stop confirmation: `CockpitDelegateWatch` records the step terminal's descendant processes; a managed step does not
      run while one of an earlier attempt is alive; the run screen names them and can stop them.
- [x] I-5 Ask me gate: a scheduled Ask step pauses the run until the person approves; decline shows the blocking action; pre-launch
      warning about launch-profile permissions.
- [x] I-6 Delivery reconciliation: `CockpitDeliveryProbe` (git + gh) before each delivery step and before Start/Continue; external
      completion recorded and the duplicate skipped; uncertain state stays pending; partial delivery status on the run screen.
- [x] I-7 Review findings gate (DEC-029, DEC-032): findings reported by the review step, blocking merge and release until fixed and
      verified or accepted for that finding and revision (criteria only); re-verification on a later revision.
- [x] Pre-existing bug found by the new integration check: Retry of a failed prerequisite could never save its result
      (`completeCurrent` needs a running step, the record stayed paused) and the run ended interrupted. `CockpitExecution.retryBegan`
      moves the record back to running when the retried step's task arrives.
- [x] DEC-036 (asked 2026-11-24 after the real-agent run failed its branch step on "Fix bugs is off, but a commit was made"): in a
      managed run the steps that write or deliver the change may change source and commit; tests, review, re-verification, CI checks
      and final verification stay under the audit. `CockpitStepKind.isVerification`, `CockpitStepAudit(changesAllowed:)`, step brief.
- [x] Tests: `CockpitManagedRunHostTests` 19/19, `testCockpitPolicyAndControls`, Cockpit runtime integration (Ask me gate, retry,
      continuation), qa-web-fault-tests (general hosted lane), cockpit-e2e S5 and S16, pure tier 8/8, `swift test` 136, architecture lint,
      SwiftLint 50/50; Debug build.
- [ ] Version bump, PR, CI, merge, release.

## Review
- Real pipeline on a fixture (`greeting-punctuation`, invisible probe app, real Claude Code): Implement with AI recommended a mode
  with reasons; Prepare a Cockpit plan produced an 11-step draft (branch, 2 work, tests, review, fix, re-verify, PR, CI, merge Ask me,
  final) with REQ-001's criteria and the checklist's Require items; Review and approve, then a separate Start with the permissions
  warning; a second Start was refused while the first run was unfinished and named it; End run freed the project; the next Start
  ran steps 1-7 with the real agent (branch, the change, its unittest, tests, review with no findings, fix, re-verify), each with its
  revision recorded, and stopped at "Open the pull request" as pending because GitHub could not answer (local bare origin).
- Found and fixed on the way: the Fix bugs audit failed every managed step that commits (DEC-036); the retried prerequisite never
  saved its result (pre-existing); a refinement sent the delivery steps back to the planner; a live Retry was not held by live
  delegates; zombies counted as live delegates; the feature card's title wrapped beside its folder.
- Not seen with a real agent: the Ask me merge gate (covered by the runtime integration check), review findings that block merge,
  risk acceptance, CI/merge/release evidence on GitHub, a delegate that outlives its step, the time limit in a managed run, the planning
  blocker with its direct-handoff choice. Unticked criteria: REQ-001 #2-3, REQ-003 #2-4 and #6, REQ-004 #21 and #23-25.

# Finish the architecture review (2026-11-15, goal from Boris: "fix all issues described above, finish the architecture review issue")

Source: `docs/architecture/architecture-review-2026-11.md` (AR-01..AR-49) and `docs/architecture/architecture-review-2026-11-followup.md` (FU-01..FU-30, sections 10 and 12). Decisions DEC-001..DEC-011 stand. Rules: CLAUDE.md "Architecture & Refactoring Rules" (a finding is done when the old thing is gone and a count says so; one finding per pull request; a first real caller in the same pull request; behaviour tests only). Merged PRs are batched into one version bump and one release per wave; nothing is installed without Boris asking.

## Wave 1: regressions and small defects (independent files, run in parallel)
- [ ] A1 FU-20: Mermaid SVG loses its `<style>` in `mvKit.sanitizeMermaidSvg`; test renders a real diagram and checks a computed fill. Code: `sanitizeMermaidSvg` rebuilds the style with `sanitizeScopedStylesheet` and `tools/tests/MermaidSvgWebTests.swift` exists; not ticked, because neither was run or looked at in the count pass.
- [ ] A2 AR-01 rest (FU-24, 25, 26): CSS parsed not regexed, canvas colour, Insight SVG sink, nonce miss logged and tested. FU-24 and FU-26 are in the code (browser CSS parser; `EditorPage` logs a miss, `EditorPageCSPTests.swift` exists); FU-25 is open: `InsightHTMLTemplate.swift:137` keeps `'unsafe-inline'`.
- [ ] B1 FU-21 + FU-15: quit must not be refused by a newer session file; one notice. In the code by reading (`saveBeforeTermination` is best-effort, `announceRefusedSave` shows the notice once); the quit path was not driven.
- [ ] B2 FU-23: document save through `AtomicFile` keeps symlinks, attributes; temp file outside the project folder. In `CoreFiles.swift` by reading (symlinks followed, extended attributes copied, item replacement directory); not run.
- [ ] C1 FU-22: `Subprocess` really kills the process group. `SubprocessChild` spawns with `POSIX_SPAWN_SETPGROUP`; `SubprocessProcessGroupTests.swift` exists; not run.
- [x] D1 Cockpit and Remote sockets: token and peer check (AR-40 rest). `CockpitHostBridge` and `RemoteToolBridge` both require `PrivateSocket.peer(of:).isCurrentUser` and `listener.accepts(token:)` before they read a request. Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.
- [ ] D2 FU-27, 28, 29: runner kills its group and has per-tier limits; structural rules become a named lint script; dead `ToolSurface` flags removed. FU-28 closed (the 500-line `todo.md` check and the 21 + 19 folder-name pins: 0 matches in the two phase tests), FU-29 closed (`menuTools`, `WelcomeActions` and `isRestorable` read the flags); FU-27 by reading (`--changed` exits 3 when no suite covers the changed files), the group kill was not exercised.
- [x] E1 Records (docs, straight to main): stale paths in `docs/architecture` (140), REQ and review ticks that the code does not support, `CLAUDE.md` slip. Living documents: path missing 157 -> 30, `file:line` citations 1,382 -> 0, line beyond end of file 181 -> 0, symbol missing 55 -> 5 (9 of the 35 left are deliberate mentions of removed things, 26 are checker false positives); `CLAUDE.md` Repository Map and How to Add reconciled. Committed on the branch `ar/e1-docs`, not pushed to `main`.
- [ ] Wave 1 release prep: one version bump, release.

## Wave 2: migrations to zero (count must reach the target)
- [x] AR-25 `Process()` outside `Subprocess`: 17 sites in 15 files -> 0 (lint `process`: 0 in 0 files, allow-list empty). Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.
- [x] AR-26 `CLICompletion.run` outside `AIOperation`: 55 in 28 files -> 0 (lint `clicompletion`: 0 in 0 files). The old repair loops were not re-counted. Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.
- [ ] AR-31 `ToolRegistry` drives menu, tab icons, titles, restore, welcome tiles: lists to edit 7 -> 2 (target 1: the `ToolID` and descriptor in `ToolRegistry.swift`, and the view in `ToolTabViews.builders`); Workflow/QA icons and the Cockpit tile were not checked.
- [x] AR-35 remaining assistant switches -> provider registry: about 28 switches in 13 files -> 0 (lint `assistant-switch`: 0 in 0 files; 5 providers in `AssistantProviders.list`). Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.
- [ ] AR-36/39 all `.dde` JSON stores through `SchemaVersionedStore`; AR-24 `AtomicFile`, `ProjectPaths`, logger. `SchemaVersionedStore` users 1 -> 14 files; `NSLog` 124 -> 0 (lint `app-log`), `".dde"` literals 57 -> 0 (lint `project-paths`); open: `.write(to:` 112 -> 35 sites (lint `atomic-write`), 93 `try? decode` sites, `FeatureStore` not on the store.
- [ ] AR-27 / AR-04 one `WKWebViewConfiguration` factory; `JS.call` for every `evaluateJavaScript`. `WKWebViewConfiguration(` 10 -> 0 (lint `webview-configuration`) is done; `evaluateJavaScript` 57 -> 27 sites and `JS.call` 6 -> 39 (the lint `js-interpolation` passes, but 27 sites do not go through `JS.call`) is open.
- [x] AR-18 settings key registry and one defaults observer: direct `UserDefaults.standard` 82 -> 0, `didChangeNotification` observers 4 -> 0 outside `Settings.swift` (lints `settings-literal` and `settings-observer`); 70 `Setting` keys. Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.

## Wave 3: structure
- [ ] AR-20 shared home + dependency lint with a falling violation count; AR-21. The lint exists (`domain-cycles`, ratchet: 104 type references in 29 pairs; `domain-dependencies.py`: 22 `Models/` pairs in cycles, 28 at 6.26.2); the shared home is `Packages/MarkViewCore` (12 files); no layer rule, cycles remain.
- [ ] AR-14 `WorkspaceManager` steps 2-11, AR-17 composition root, AR-19 tasks/timers, AR-16 split of the two big stores. All 11 steps exist as types, `WorkspaceManager.swift` 5,747 -> 730 lines, `WindowComposition` is the root, `ArchitectureStore.swift` 4,512 -> 1,889 and `UIStudioSession.swift` 3,766 -> 1,958 lines, unowned tasks 391 in 87 files -> 263 in 70, `Timer` 0; open: 56 views still take the whole manager (62), 33 hooks and 4 back-references.
- [x] AR-37/38 SQLite off the main actor with real migrations: `SemanticDatabase` is an `actor` (lint `semantic-database-actor`), `SemanticSchema.migrations` is an ordered list on `PRAGMA user_version`. Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run.
- [ ] AR-42/43 main-thread paths and concurrency warnings: `hasMarkdownFiles` is a stored flag, directory walks in `Views/` 2 -> 0, `waitUntilExit` 11 -> 0, 40 `@unchecked Sendable` and `nonisolated(unsafe)` sites each justified (lint `unchecked-sendable`: exit 0); the warning count (189 at 6.26.2) and the main-thread cost were not measured.
- [x] AR-28/29 typed bridge both sides; split the three JS files over 2800 lines: `bridge-contract.json` declares 37 messages in 3 channels, string `case` labels in `WebViewBridge.swift` 29 -> 0, JS files over 2,800 lines 3 -> 0 (largest 1,322). Counted 2026-11-15 at the merge tip `ac3001ba` of `feat/architecture-review-finish`, nothing built or run. The module system and bundle of AR-29 are not part of this item and are open (63 `<script>` tags).
- [ ] AR-32/33/34 themes as data with user folder, layout presets with UI, backdrop registry. In the code: 11 JSON themes read by `ThemeCatalog` with a user folder, 4 JSON layout presets read by `LayoutCatalog`, `BackdropRegistry` with 17 descriptors; not ticked, because the picker, the menu and the registry were not driven in the app.

Status is written here only with the count that proves it. Result of the count pass of 2026-11-15 (merge tip `ac3001ba`, base 6.26.2 `6facd9f`; nothing built or run): ticked where a lint or a count proves the item, unticked where an item is only in the code, was not run, or has an open part; the table of counts, FU-20 to FU-30 and the recommended order are in `docs/architecture/architecture-review-2026-11-followup.md` section 13, the per-finding results in the `Status (2026-11-15)` lines of `docs/architecture/architecture-review-2026-11.md`. Wave 1 release prep (one version bump, release) is not done and not part of this pass.

# Architecture Review 2026-11 Implementation (2026-11-15, 6.26.0)

Full implementation of `docs/architecture/architecture-review-2026-11.md` across Phases 0–7 and Continuous items (`AR-01..AR-49`, `REQ-001..REQ-008`, `DEC-001..DEC-010`, GitHub issue `#414`).

- [x] Phase 0 (`REQ-001`, `AR-01..AR-13`): CSP & DOMPurify HTML sanitization, `ProcessRunner` drain/timeout/kill, `PathSafety.resolveInsideRoot`, `AtomicFileWriter`, `SingleFlightKeyed` for `PDFRenderCache`, `WebViewCoordinator` retain-cycle fix, `ExportPreviewSheet` cancellation, `TerminalSessionView` scroll coalescing, Turndown vendor bundle (`tools/tests/phase0-safety-tests.sh` 20/20).
- [x] Phase 1 (`REQ-002`, `AR-22`, `AR-30`, `AR-44` step 1, `AR-46..AR-48`): Removed dead `EditorWeb/`, retired XcodeGen (`project.yml`, `setup.sh`), added `.swift-format` and `.editorconfig`, added `tools/tests/manifest.json` + `tools/tests/run.sh`, scaffolded `Packages/MarkViewCore` (`tools/tests/phase1-cleanup-tests.sh` 17/17).
- [x] Phase 2 (`REQ-003`, `AR-18`, `AR-24`, `AR-25`, `AR-27`, `AR-44` step 2): Added `MarkView/Core/` (`CoreInfrastructure.swift`, `CoreFiles.swift`) and linked `Packages/MarkViewCore` into `MarkView.xcodeproj`, added `TypedWebBridge` (`WebCommand` / `WebEvent`) and `ProjectPaths.projectCacheIdentifier(for:)` (`tools/tests/phase2-core-tests.sh` 13/13, `swift test` 6/6).
- [x] Phase 3 (`REQ-004`, `AR-31..AR-34`): Added user JSON theme loader with WCAG contrast check & CSS token derivation (`DEC-003`), `BackdropSceneDescriptor` registry, `WorkspaceLayoutPreset` (`Writing`, `Review`, `QA`, `Cockpit`, `DEC-002`), `MarkdownCommandRegistry`, and `SurfaceRegistry` (`tools/tests/phase3-extensibility-tests.sh` 14/14).
- [x] Phase 4 (`REQ-005`, `AR-14..AR-19`): Added `DocumentScrollSideTable`, `TaskBag`, `WindowTaskScheduler`, `WorkspaceModalCoordinator`, `WorkspaceSemanticCoordinator`, `WorkspaceChromeCoordinator`, `MarkdownDocumentChunker`, and `WindowDependencies`; routed scroll/heading updates through `updateActiveTabSilently` (`tools/tests/phase4-shell-tests.sh` 21/21).
- [x] Phase 5 (`REQ-006`, `AR-26`, `AR-35`): Added `AIOperation<Input, Output: Decodable>`, `AIJSONSalvage`, and `AssistantProviderRegistry` (`tools/tests/phase5-ai-tests.sh` 26/26).
- [x] Phase 6 (`REQ-007`, `AR-36..AR-43`): Added `SchemaVersionedStore<T>` + `StoreLoadResult<T>` backup recovery, `SQLiteMigration` + `SemanticDatabaseExecutor` actor, per-instance control socket `0600` token + peer UID/PID check + `byUserConfirmationGate` (`DEC-009`), scoped ATS in `Info.plist`, cached `hasMarkdownFiles`, and enabled `SWIFT_STRICT_CONCURRENCY = targeted` (`DEC-010`) (`tools/tests/phase6-storage-security-tests.sh` 19/19).
- [x] Phase 7 & Continuous (`REQ-008`, `AR-20..AR-23`, `AR-28`, `AR-29`, `AR-45`, `AR-49`): Added shared `mv-kit.js` (`window.mvKit` + `window.mvBridge`), consolidated CI into `.github/workflows/ci.yml` with build caching and concurrency cancellation (`DEC-008`), rotated `tasks/todo.md` into `tasks/archive/todo-archive-2026-11.md`, and synchronized `CLAUDE.md` and `docs/architecture/` (`tools/tests/phase7-web-ci-tests.sh`).

# Architecture and code review (2026-11-15, docs only)

Boris asked for a serious architecture and code analysis written to a file under docs, as a source for tasks (clean architecture, decomposition, sharing, decoupling, improvements such as a plugin system for themes, splash screens, layouts).

- [x] Seven read-only passes (layering, shell and state, AI layer and processes, web editor and bridge, extensibility, tests/CI/build/repo, persistence/security/concurrency), then a spot check of the most serious claims against the code.
- [x] `docs/architecture/architecture-review-2026-11.md`: findings AR-01..AR-49 (severity, effort, evidence, fix), target structure, roadmap in 8 phases, 10 decisions for Boris; linked from `docs/architecture/README.md`.
- Nothing was built, run or profiled; performance findings are by reading. No code was changed. No tasks or issues were created: Boris turns the findings into tasks himself.

# Three new themes and four new welcome animations (2026-11-14, 6.25.0)

Boris: "add about three new themes and three new animations for the splash screen, the main screen; invent something interesting". Status: APPROVED by Boris's answers (themes: Nord + Forest + Daylight; animations: he ticked all four of Git Flow, Deep Sea, Warp, Typewriter, so all four are built, "about three" leaves room). Implementation in worktree `MarkView-welcome-themes`, branch `feat/welcome-animations-and-themes`.

Reading of the request (to confirm): "themes" = window appearances in the theme picker (`AppTheme`, today 6 presets: 5 dark, only 1 light); "animations" = backdrops of the welcome screen (`WelcomeBackdrop`, today 9 animated + By Project, Shuffle, Off).

## Themes (appended to the picker, all per-window like the others, DEC-002)

| Theme | Mode | Idea | Accent |
|---|---|---|---|
| Nord | dark | arctic blue-grey, frost cyan (Nord palette family) | ~#88C0D0 |
| Forest | dark | deep moss green, warm parchment text (first green theme) | ~#A7C080 |
| Daylight | light | cool daylight grey-white, deep teal (a second light theme, cooler than warm Paper) | ~#0F766E |

Final hex values are tuned by the existing contrast checks (body text and accent >= 4.5 on bg and sidebar), not guessed.

- [ ] `Models/Appearance/AppTheme.swift`: three cases, `displayName`, `summary`, `isPreset`, `isDark`, `webID`, `pickerChoices`, one `Base` palette each. Stored name of an unknown theme already falls back to Classic Dark, so no migration.
- [ ] `Resources/Editor/js/markview-themes.js`: base + `t` + `syn` + `struct` + `term` tokens per theme (the web editor, code colours, terminal).
- [ ] `tools/tests`: add the three to `ThemeModelTests` (presets), `ThemeWebTests` (Look list, compares Swift and JS base colours), `WindowThemeTests` (list).
- [ ] Docs: `docs/architecture/modules/app-shell-and-workspace.md`, `editor-and-bridge.md`, README theme list.

## Animations, four of them (Core Animation only, DEC-001: no frame timer, no display link, bounded layer counts, still picture for Reduce Motion)

1. **Git Flow**: horizontal lanes of a commit graph; branches fork off and merge back along curves, commit dots pulse, the whole graph drifts left as a seamless loop (replicator + one translation). Colours from the theme (blue/green/purple/orange).
2. **Deep Sea**: surface waves (path animation between two wave paths), swaying light rays from above, rising bubbles, a few jellyfish pulsing and drifting. Calm, cyan/blue/purple.
3. **Warp**: hyperspace, streaks radiating from a drifting vanishing point with staggered speeds and a soft glow in the middle. Slow and low contrast on purpose (no flashing).

4. **Typewriter**: lines of Markdown (headings, bullets, a code fence) drawn as text-like bars that are typed out left to right by a caret, then fade and scroll up; a blinking caret. Bars, not real text, so no document content is involved.

Spare ideas: Snowfall, Paper Planes, Fireflies, Rainy Window.

- [ ] `Models/Appearance/WelcomeBackdrop.swift`: cases `gitflow`, `deepsea`, `warp`, `typewriter` with title and symbol, added to `animated` (so Shuffle includes them). By Project rules stay as they are.
- [ ] `Views/Appearance/BackdropLayerBuilders.swift`: dispatch; new files `Views/Appearance/DevBackdropLayers.swift` (Git Flow, Typewriter) and `Views/Appearance/AtmosphereBackdropLayers.swift` (Deep Sea, Warp) (project.yml and `MarkView.xcodeproj` kept aligned) with the four builders as a `BackdropBuilder` extension, `detail` 1...4 respected.
- [ ] Background pill/menu picks the new cases up from `allCases`; check that the menu stays one screen tall.
- [ ] `tools/tests/WelcomeScreenTests.swift`: new scenes in the dark / light / narrow checks, presentation-layer motion, changing rendered frames, layer-count bound, click-through, Reduce Motion.
- [ ] `docs/architecture/modules/welcome-backdrops.md` (nine -> thirteen), README.

## Verification and delivery

- Pure + render checks: `theme-model-tests.sh`, `theme-web-tests.sh`, `window-theme-tests.sh`, `welcome-screen-tests.sh` with `SNAPSHOT_DIR` and I look at the pictures of each scene in a dark and a light theme; every script of every triggered workflow; Debug build.
- Real app, invisibly (app-probe, alpha-0 window, empty HOME): each new backdrop and theme selected, layers move, hit test nil; CPU of the app idle with each new scene for ~10 s (BUG-117 lesson).
- Delivery per CLAUDE.md: branch `feat/welcome-animations-and-themes`, `./bump-version.sh minor` (6.25.0), one PR, merge, `./release.sh --publish` from a clean worktree, remove my worktree. Boris installs; I do not touch the running app.
- Not verifiable by me: how the scenes look on a real display, WindowServer cost, taste.

## Review (6.25.0, 2026-11-14)

- Delivered: PR #413 (`7a946fe`): themes Nord, Forest, Daylight; backdrops Git Flow, Typewriter, Deep Sea, Warp (4, not 3: Boris ticked all four). Shuffle includes them; By Project rules unchanged.
- Verified: 10 test scripts that compile the changed files (theme model/web/window, window-session, project-backdrop, welcome-screen, intake-clipboard, pdf-reader, change-review-layout, workflow-editor-layout), Debug build, the real Debug app invisibly (each new scene with a new theme: layers move, backdrop hit test nil, app CPU idle 0.0%, pictures looked at).
- The scenes were looked at as pictures in dark and light themes. Layer counts at detail 4: Git Flow 61, Typewriter 60-65, Deep Sea 78, Warp 205 (bound 260).
- Not seen: the scenes on a real display, WindowServer cost (the probe's alpha-0 windows do not measure it), taste. Typewriter in a narrow window shows only fragments between the tiles; at 1142 pt the side pages slip 18 pt under the tiles.
- Release: https://github.com/t-boris/MarkView/releases/tag/v6.25.0 (Latest, built from `7a946fe` by `release.sh --publish`: signed Developer ID, notarization Accepted, stapled, `spctl` accepted the DMG as Notarized Developer ID, app version 6.25.0). DMG: `build/MarkView-6.25.0.dmg`. NOT installed: the running app is older; waiting for Boris's "reinstall". 6.24.2 (PR #412) has no release of its own, it ships inside v6.25.0.
- Also in this release, separate PR #412 (6.24.2): End-to-End QA took the model of the shown agent tab (`observedModel ?? model`, since 5.65.1); it now takes the project's chosen model for the shown agent's tool (`CLICompletion.Assistant.chosen`). Open question for Boris: a `/model` switch inside a Claude Code session is still remembered as the project's model (BUG-048, `AIAssistantPreferences.remember`), so QA follows it after such a switch; stopping that reverses BUG-048. A live QA run was not made.

# Antigravity usage next to Claude and Codex in the top bar (2026-11-14, 6.24.0)

Boris: show how much Antigravity quota is left in the top bar, in parallel with Claude and Codex. Research (memory `antigravity-usage-source-agy-usage`): `agy --output-format json -p "/usage"` is a free, structured source (about 2 s, no model tokens, no conversation). Boris approved the proposal as written ("Да, делай так, как предложил"); the headline window is the most used one, like Claude and Codex.

- [x] Records: DEC-020 in ai-agent-usage-quota-tracker-codex-claude-code (Antigravity source, supersedes DEC-010 of flexible-files-views-and-visible-agent-usage for Antigravity), a requirement with criteria ticked only for what is proven.
- [x] 1. Model: `UsageAgent.antigravity` (display name, short name, `hasLocalLogs` false, detection by `agy` or `~/.gemini/antigravity-cli`), `OfficialUsageParser.antigravity` (groups of buckets to windows, group in `modelScope`, a bucket nobody used yet has no reset time because `agy` reports now + window).
- [x] 2. Source: `agy --print-timeout 20s --log-file /dev/null --output-format json -p "/usage"` run off the main thread with our own 25 s timeout; signed out ("Authentication required") is `signedOut` and the login URL is never kept or logged; unrecognised output is `failed`.
- [x] 3. Tracker: no local-log scan for an agent without logs (no reader, no watched folders, no fallback limit); state is official, or unavailable with the note.
- [x] 4. Views: the third chip, a hide switch in Settings, the group name in the popover and tooltip, no "Set a limit" / "Today (local logs)" rows for Antigravity.
- [x] Checks: pure parser tests on the real output, mutation check, `agent-usage-tests.sh`, every script the diff triggers, Debug build, a live read of the real `agy`.
- [x] 6.24.0: PR #410 merged (`777529b`); signed release v6.24.0 (see Review); install only on Boris's "reinstall".
- Not included: the Antigravity IDE's own quota if it is a different Google account than the CLI (not verified), notifications (DEC-004).

## Review (6.24.0, 2026-11-14)

- Verified: 124 pure checks on the real `/usage` output (10 turn red when the rules are turned off: percent used, unused buckets without a reset time, sign-in classification, headline, pace); every script of every triggered workflow (pdf-book, pdf-reader, themes) and `project-ai-choice-tests.sh`; Debug build.
- Verified in the real Debug app, invisibly (app-probe with only `agy` linked into the empty home): the chip reads "Antigravity 17% used Gemini 4 Argon wk · 6d 23h", equal to the CLI's 83% remaining read at the same moment; without the Keychain the chip says "usage unavailable" (the call was cut at 25 s).
- `agy` keeps its sign-in in the OS Keychain, so a probe with an empty home is signed out unless `Library/Keychains` is linked. Signed out, `agy -p` prints a Google login link and waits 60 s ("Print mode: triggering interactive OAuth"); a sandbox run that denied `/usr/bin/open` recorded no attempt to open a browser. Killing it with SIGTERM leaves no orphan process.
- Not seen: the popover (a separate window the probe does not capture), the Settings switch, the chip beside Claude and Codex, the installed app, the Antigravity IDE's quota when it uses another Google account than the CLI.
- DEC-020 accepted (Boris approved the proposal), REQ-007 criterion 7 ticked, DEC-010 of flexible-files-views-and-visible-agent-usage carries an update note.

## 6.24.1 (2026-11-14): the same rhythm as Claude and Codex

- Boris answered "так же как и claude + codex" (headline window: the most used one, no change) and "И побыстрее" (asked: the poll rhythm; he chose every 5 minutes). Antigravity is read every 5 minutes like the other two: `UsageAgent.pollInterval` is gone, `signedOutInterval` is optional and set only for Antigravity (30 minutes). PR #411 merged (`0558c91`).
- Verified: 123 pure checks (the signed-out interval check turns red when the rule is off), every script of the triggered workflows, Debug build, the real Debug app invisibly (chip "Antigravity 31% used Gemini 4 Argon wk · 6d 23h"). Not seen: the five-minute rhythm in a running app, the installed app.

# UI Studio: the simulator answers in the application's own response envelope (2026-11-14, 6.23.0)

Boris installed 6.22.0 and wrote "Не работает" with two screenshots (product-promotion-desk, screen "Products – list and detail"): the Products page shows `undefined is not an object (evaluating 'envelope.error.code')`, every screen is covered by the dialog "The AI is waiting for you", the screen request ends `failed` ("Override 1 names POST .../passport.get, which no rule serves"), Fix problems is greyed. Plan `/Users/boris/.claude/plans/calm-whistling-eich.md` APPROVED. This is finding (a) of the 6.22.0 report that I had left as "needs approval"; it blocks his two requests for any Electron/IPC app.

- [x] Records: DEC-015 (service envelope), REQ-022 (answers in the application's envelope), criteria ticked only for what is proven.
- [x] 1. Model + simulator: `StudioEnvelope`, optional `envelopes` in the environment; generated answers wrapped by prefix, `respond` and overrides verbatim, no double wrap when the rule's `envelope` equals the result key.
- [x] 2. Assistant contract: `envelope` explained, `envelopes` in the preparation schema, validator rejects a template string in `envelope`.
- [x] 3. One-time detection for existing environments (`envelopes == nil`), cleans template `envelope` strings, after the map, respects `autoRepair`.
- [x] 4. A context change naming a request no rule serves prepares that rule and retries.
- [x] 5. Screen request / preparation prompt: a screen is not covered by a blocking dialog (prompt-level, model-dependent).
- [x] Checks: pure, session, live run on a clone of product-promotion-desk with the real assistant; every script of every triggered workflow; Debug build.
- [x] 6.23.0: PR #409 merged (`d6a0510`); `Build & Release` of the merge commit passed. Release https://github.com/t-boris/MarkView/releases/tag/v6.23.0 (Latest, signed, notarized, stapled, `spctl` accepted), copy `build/MarkView-6.23.0.dmg`. NOT installed (6.22.0 is running): waiting for Boris's "reinstall".
- Not included: the page rendering its own caught error as a problem (no event to repair); `{{studio.records}}` placeholders; the mapper's 240 s timeouts.

## Review (6.23.0, 2026-11-14)

- Verified on an APFS clone of product-promotion-desk with the app's own assistant: the one-time review found the `{ok, result}` envelope (transport.ts `unwrap`) and re-modelled `agent.questions` / `agent.answer` / `agent.stop` as an entity `agentQuestions` with a channel link `{type: "changed", scope: "accounts"}` (the event hooks.ts `useQuery` listens to); the Products page renders; pressing "I'm done" took the dialog from 1 of 6 to 5, 4, 3, 2. The automatic repair of 6.22.0 then fixed the `opportunity.kind` data error by itself ($0.03). The review costs about $0.1-0.2 once per project (one call, 30-50 s, background banner).
- Mutation checks: wrap and body id disabled turned 10 pure checks red; review and unserved-rule preparation disabled turned 13 session checks red.
- The first design held the busy state during the review and broke the existing Map Again check; it is background work now (banner, screens wait for it).
- Prompt-level and model-dependent: how the assistant models a dialog's write rule and which event it links (the deterministic parts are the validator, the atomic apply and the replay in the harness). A second real run of the review gave one envelope instead of two (`/api/` was added the first time): another review of the same project may differ in detail.
- Not hand-checked: the installed app (banner "Checking how the application reads responses", the Screens menu after the review), a project whose transport is not wrapped (the review answers "none" and is not repeated), the Products page on Boris's own project (only on a clone).
- Still open, needs Boris's approval: pages crash on records that lack nested fields the application reads (`reason.startsWith`, `card.data.opportunity.channelId` in the Attention page); the auto repair handles one error at a time and only when the page logs it; scenarios incompatible with the environment ("needs update") are not updated automatically; DEC-015 is `proposed`.

# UI Studio: Problems with Fix, automatic repair at open, main screens ready (2026-11-14, 6.22.0)

Boris, dictated: UI Studio very often shows an error at open (a sign-in is needed, or the simulated data is wrong); it should repair such errors itself. He cannot find where Fix is (his case: scenario "Accounts: all tabs filled" in product-promotion-desk showed "Error invoking remote method accounts.list", "Failed to fetch", "Rejected a message of an earlier generation 20"); he wants Fix in Problems in the Log. Idea: the main screens selectable and already filled. Decisions of 2026-11-14: repair automatically with Undo (replaces REQ-017 criterion 5, "nothing happens without the click", Boris 2026-11-04); save the screens list and prepare the main screens ahead. Plan: `~/.claude/plans/calm-whistling-eich.md`; branch `feat/ui-studio-auto-repair-screens`, one PR, one release.

- [x] Records: DEC-013 (automatic repair replaces click-only), DEC-014 (screens.json, ahead preparation without a page), REQ-019 (Problems with Fix), REQ-020 (automatic repair at open), REQ-021 (main screens saved and ready), all proposed/draft; REQ-017 criterion 5 marked superseded.
- [x] A. Problems: `StudioProblem` classification (data error, missing rule, sign-in redirect, blocked service, not data, noise), Fix problems in the Log drawer, a row action per problem (also for older page generations), the toolbar Log button opens Problems; stale-generation rejections answered silently and not counted.
- [x] B. Automatic repair: `autoRepair()` after `launch`'s restore and debounced from page errors; gate, ledger (no repeat of not-data/refused, 2 attempts per error, 3 per open), missing-rule retry with a reload, sign-in through the assistant-made scenario, banner with Undo, switch "Repair errors automatically".
- [x] C. Screens: `.markview/studio/screens.json`, list kept across launches and found automatically after the map, `StudioScreenPreparer` (main screens, up to 8, assistant phase + static validator, no page), menu with statuses, first activation verifies, fallback to the current correction path, "needs refresh" by source hashes.
- [x] Checks: pure (792), session (365) and web (128) harnesses extended; every script of every workflow triggered by the diff plus gateway (59) and node (89) by hand; Debug build; live runs with the app's own assistant on isolated clones of product-promotion-desk (not on vivaa master-portal, no sign-in run live; no hidden-window pictures).
- [x] 6.22.0: PR #408 merged (`1242a6a`), release https://github.com/t-boris/MarkView/releases/tag/v6.22.0 (Latest, signed, notarized, stapled, `spctl` accepted), copy `build/MarkView-6.22.0.dmg`; NOT installed (6.20.0 is), waiting for Boris's "reinstall".
- Not included: AI repair of code errors and blocked third-party scripts (reported only); Undo after the session ends; verification of screens ahead on a hidden page (there is only one page).

## Review (6.22.0, 2026-11-14)

- Root cause of Boris's three errors: a fragment-only load (`/#/attention` to `/#/accounts`) keeps the old document and generation, so every request was rejected as stale. Found by a live run on a clone of product-promotion-desk, not by the harness (its check accepted "degraded"); fixed with `about:blank` first, plus the `waitForLoad` cancelled-timer bug.
- Live numbers on product-promotion-desk: discovery + 6-7 main screens prepared ahead about 2 minutes, 7 assistant calls, about $0.6-0.7. Opening the prepared screens afterwards: some open directly in 1-2 s without the assistant, the rest fail the check on the page and go through the assistant (3 live runs: 3 of 6, 3 of 6 and 2 of 7 direct). Whether a screen opens directly depends on the assistant's scenario matching the page.
- Not built, needs Boris's approval: (a) project list rules with `envelope: "result"` cannot express `{ok:true,result}`, so the page shows an envelope error with no logged problem (simulator gap); (b) scenarios incompatible with the environment ("needs update") are not updated automatically; (c) the assistant's prepared scenario may carry a route the page does not use (`/publications` in a hash-routed app); forcing the screen's own route when the scenario has no steps would avoid that fallback.
- Not hand-checked: the installed app (Log drawer with Fix problems, Screens menu), data-fix auto repair live with the real assistant (an attempt to induce an error failed), sign-in repair on a real sign-in project (vivaa master-portal), automatic missing-rule repair in a live session.

# Tab bar: "Close Documents" and scroll arrows (2026-11-14, 6.21.0)

Boris, dictated: (1) the right-click menu of a tab gets "Close Documents": every document closes, the tool tabs (End-to-End QA, Workflow, Build & Deployment, Git, X-Ray, ...) stay; (2) with many tabs he cannot scroll them: small arrows at the left and the right of the tabs that move the strip. Plan: `~/.claude/plans/calm-whistling-eich.md`; branch `feat/tab-close-documents-scroll`, one PR, one release.

- [x] Model: `TabClosing.activeIndex` (pure, checked), `OpenTab.isDocument` (file, image, pdf, archive, data), `WorkspaceTabsStore.keepTabs(where:)`, `closeDocuments()` with one "Save changes to N documents?" question shared with `closeFolder` (the prompt moved out of `closeFolder` into one private helper).
- [x] Tab bar: "Close Documents" in the tab context menu (greyed out with no document open); arrows on both ends of the strip, shown only while the tabs overflow, the reached end dimmed, a click moves the strip by 60% of its width. `TabStripScroller` + `TabStripScrollHook` replace `WheelScrollsHorizontally` (wheel handling kept).
- [x] Checks: `tab-closing-tests.sh` (15 checks of the active-tab rule, added to the pdf-reader workflow step) and `TabClosingStoreTests` inside the pdf-reader harness (the shipping `OpenTab` and `WorkspaceTabsStore`: all 19 tab kinds classified, tool tabs stay in order, active tab handed over); every script of the pdf-book, pdf-reader and themes workflows; the real app on hidden windows (app probe, which now also prints `enabled=`): 7 tabs show no arrows; 11 and 16 tabs show both, a click moves the strip by 476 of 794 px (60%), the left arrow is dimmed at the start and the right one at the end, both vanish in a wide window; pictures dark, and light at 150% text.
- [x] 6.21.0: PR #407 merged (`69f888b`); its three checks (pdf-book, pdf-reader, themes) and `Build & Release` of the merge commit passed. Release v6.21.0 published from the merged main (signed, notarized, stapled, `spctl` accepts it): https://github.com/t-boris/MarkView/releases/tag/v6.21.0 (Latest); copy at `build/MarkView-6.21.0.dmg`.
- [ ] Install: waiting for Boris's "reinstall" (the running app, 6.20.0, is not touched).
- Not included: the existing Close Others / Tabs to the Right / All still drop unsaved documents without asking; Close Documents in the ▾ menu or the menu bar.

Review (2026-11-14):
- With the arrows on, the strip is shorter by their width, so the arrows themselves change whether the tabs fit: the flags are published only on change and the active tab is revealed again when they appear.
- First version counted the empty 40 pt drop zone after the last tab as "more to see": the right arrow stayed enabled at the end and a click did nothing. The probe caught it; the drop zone is now an inset of the scroller.
- The first overflow probe never overflowed (a 900 px window holds 7 tabs, and Open Terminal tiles did not open a tab in the hidden app); Browser tiles and a taller window were needed to get 16 tabs.
- `pdf-reader-tests.sh` compiles `WorkspaceTabsStore` out of `WorkspaceManager.swift`, so it failed to find `TabClosing` until `TabClosing.swift` was added to its source list.
- Not hand-checked: clicking the Close Documents menu item in the real app (a right-click menu is a real pop-up the probe cannot hide), the unsaved-documents prompt, a real mouse or trackpad on the arrows, the install.
- Honest limits: "document" is five tab kinds (file, image, PDF, archive, data); X-Ray, Git, Insight, GitHub, Browser, Terminal and the rest stay. Close Others / Tabs to the Right / All still drop unsaved documents without asking, and `closeTabs(under:)` lacks `.data`. The arrows move by 60% of the visible width, not tab by tab, and do not change the active tab.

# Cockpit: the AI names the run (2026-11-14, 6.20.0)

Boris, dictated: at the top of the Cockpit, where the name of the run is written, show the AI's own understanding of what the flow is, not the text he originally typed; "let the AI decide what is written". Plan: `~/.claude/plans/calm-whistling-eich.md`; branch `feat/cockpit-ai-title`, one PR, one release.

- [x] Model: optional `CockpitPlan.title` (omitted when nil, so the fingerprint of every saved plan is unchanged), `displayTitle` (title, else the goal's first line), one shared first-line helper (`CockpitText.firstLine`, three copies removed).
- [x] Planner: `title` in the schema (required) and in the prompt (3 to 8 words, the goal's language, not a copy of the goal, kept on a refinement); `parse` cleans it and never fails the plan over it.
- [x] Views: run header (goal as a hover tooltip), run list row, QA evidence line, plan screen header, notification body.
- [x] Checks: planning, plan and run scripts extended; every `cockpit-*-tests.sh` (with the runtime integration and watchdog), the qa-tests, feature-review-gate, qa-retention checks and every script of the pdf-book, pdf-reader and themes workflows; e2e S18 (new), S5 (no title falls back to the goal), S7, S13-S17; pictures of the plan screen and the finished run; one real planning call (Russian goal, the app's own schema and prompt) returned a Russian title.
- [x] 6.20.0: PR #406 merged (`603fbbf`); its four checks (cockpit, pdf-book, pdf-reader, themes) and `Build & Release` and `Copilot Cockpit Checks` of the merge commit passed. Release v6.20.0 published from the merged main (signed, notarized, stapled, `spctl` accepts it): https://github.com/t-boris/MarkView/releases/tag/v6.20.0 (Latest); copy at `build/MarkView-6.20.0.dmg`.
- [ ] Install 6.20.0: waiting for Boris's "reinstall" (the running app is not touched). 6.19.0 is also not installed yet.
- Not included: a manual rename field; AI titles for runs saved before this release (they keep the first line of their goal).

Review (2026-11-14):
- A title is a suggestion: a missing, blank or wrong-typed one gives no title and the plan still parses (same rule as a proposed model the agent does not offer).
- The e2e dump shows static text as `value=` and buttons as `label=`; my first S5/S18 checks looked for `label=` and failed on a working feature. The hover tooltip is not in the dump, so the check is "the goal text is not on the run screen".
- I staged a Python bytecode file with `git add -A` and removed it in a second commit; stage named files after an e2e run.
- Not hand-checked: the installed app, a run saved before this release reopened (by code and by S5's no-title path only), a refinement keeping the title on a real model (the prompt asks; not run), whether the title reads well for long mixed-language goals.

# Toolbar "open tab" marks and the Cockpit instrument panel (2026-11-14, 6.19.0)

Boris, dictated: (1) the toolbar buttons of singleton tabs (Git, Build & Deployment, Workflow, End-to-End QA, UI Studio, Cockpit, Discussions) must stay highlighted while their tab is open, because he cannot tell whether it is open without clicking; (2) the Cockpit run should look like a cockpit: altitude, turns, wind strength, distance to destination, levers to switch things on and off, and messages to the supervisor ("curator"). Decisions of 2026-11-14: two-level toolbar marks (current = filled, open in the background = dot); the dials show real values of the run; levers can only switch OFF what the approved plan allows, at once, never beyond it; a message to the supervisor is a note (kept in the run, used in its later answers and in the next step's briefing, never interrupts the running agent). Plan: `~/.claude/plans/calm-whistling-eich.md`; one branch `feat/cockpit-instrument-panel`, one PR, one release.

- [x] Docs: DEC-028 (proposed), REQ-009 (draft), REQ-008 updated, in `copilot-cockpit`.
- [x] Toolbar: `open` mark next to `selected` in `ContentView.workspaceHeader` for the 7 singleton buttons; Browser and New Prototype unchanged; accessibility value "open"/"current". Checked in the real app (S17): all six states (none open, current, current + open, hidden behind Tasks, re-chosen, closed).
- [x] Readings: `Models/Cockpit/CockpitInstruments.swift` (Foundation only) + `tools/tests/cockpit-instruments-tests.sh`.
- [x] Levers: `CockpitLiveSwitches` (cuts only), `CockpitStepPolicy.narrowed(by:)`, registry evaluates the narrowed policy on every call, supervisor checks its cut, `CockpitExecution.setSwitches`, event kind `switched`; checks in `cockpit-policy-tests.sh` and `cockpit-run-tests.sh`.
- [x] Notes: `CockpitRun.notes`, event kind `note`, supervisor prompt block, next-step briefing, `DictationInput` field.
- [x] Views: `CockpitInstrumentPanel`, `CockpitFlightPath` (replaces the flow strip), `CockpitLeverPanel`; the four role cards removed, their facts moved; saved runs parked; labels kept for `tools/tests/cockpit-e2e` and `scenarios.py` updated.
- [x] Checks: Debug build; every `cockpit-*-tests.sh` (new `cockpit-instruments-tests.sh`, extended policy and run checks), the packaged-runtime integration and watchdog checks, every script of the pdf-book, pdf-reader and themes workflows; cockpit-e2e S5, S7-S17 on a hidden copy of the Debug app; pictures of running, lever cut, note sent, finished and failed, dark and light, text 100% / 150% / 200%; CPU compared with main.
- [x] 6.19.0: PR #405 merged (`bc0c54c`); its four checks (cockpit, pdf-book, pdf-reader, themes) and `Build & Release` passed. Release v6.19.0 published from the merged main (signed, notarized, stapled, `spctl` accepts it): https://github.com/t-boris/MarkView/releases/tag/v6.19.0 (Latest); copy at `build/MarkView-6.19.0.dmg`.
- [ ] Install 6.19.0: waiting for Boris's "reinstall" (the running app is not touched).
- Not included: a graceful hold after the current step and a Resume (the runtime accepts only pause, stop and retry), live change of limits and of create scenarios / build / checks, pasting a note into the running agent's terminal.

Review (2026-11-14):
- A first pulse trace redrawn four times a second by a SwiftUI `TimelineView` raised the CPU of a live run from 5.5% (main) to 16%; found by comparing with a build of main, fixed by drawing the trace as a Core Animation layer (back to 5.6-6.4%).
- `cockpit-policy-tests.sh` was not run by any CI job; it and `cockpit-instruments-tests.sh` now run in the existing Cockpit job.
- The lamps and dials carry their reading in the accessibility label: an element without children exposes no separate value to the probe.
- Not hand-checked: a saved run reopened later (parked panel, levers and notes disabled: by code, no picture), two windows of the same project, the silent state on a live run (its rule is checked, no 20-minute run), a real mouse on the switches, the panel in the installed app. REQ-009 criteria stay unticked until Boris has seen it; DEC-028 stays proposed.
- Honest limits: a note reaches an agent only on its next question or at the next step; wind counts refusals and unanswered questions of the last hour only; the Distance estimate appears after the first step has passed.

# Copilot Cockpit: an editable plan screen and a run control room (2026-11-14, 6.18.0)

Boris, with a screenshot: the plan "looks terrible" (a text scroll, only `Claude Code` per step, raw JSON for QA, nothing editable) and the run is just as unclear although it may last days. Decisions of 2026-11-14: a list of runs on the left plus two screens; the model is chosen for every step, the supervisor and the planner (the planner may propose one per step); macOS notifications and a silence warning (the Mac is not kept awake). PR #404 merged (d6d1b4a), branch `feat/cockpit-plan-editor`.

- [x] Plan screen: steps on a rail, agent and model menu per step, inline editor, move/duplicate/insert/delete, editable criteria, structured QA view decoded from `exactPlan`, blockers shown on their step, controls folded once a plan exists.
- [x] Run screen: run list, control room (coordinator, step agent, supervisor, guard), attention banner, flow strip, Timeline / Steps / Questions / Findings.
- [x] Data: `CockpitStep.model`, `CockpitControls.supervisorAgent/Model`, run `startedAt/lastSignal/events`, step `startedAt/endedAt`; all optional, 6.17 runs load. The model reaches the agent as `--model` (looked up by step id; Go untouched).
- [x] Notifications: `CockpitNotice` (pure, checked) and `CockpitNotifier`; clicking one opens the run.
- [x] Checks: plan, planning, run (timeline, silence, notifications), QA decode; every script of the cockpit, pdf-book, pdf-reader and themes workflows, `go test`, the packaged-runtime integration and watchdog checks; e2e S5, S7-S12 on the new screens, S13 (model flag, timeline), S14 (pictures).
- [x] Docs: DEC-027 (proposed, supersedes DEC-018), REQ-007 and REQ-008 (draft) in `copilot-cockpit`.
- [x] Release v6.18.0 published from the merged main (signed, notarized, stapled DMG, `spctl` accepts it): https://github.com/t-boris/MarkView/releases/tag/v6.18.0 (Latest); copy at `build/MarkView-6.18.0.dmg`. PR #404 checks (cockpit, pdf-book, pdf-reader, themes) and the merge commit's Build & Release and Copilot Cockpit Checks all passed.
- [ ] Install 6.18.0: waiting for Boris's "reinstall" (the running app is not touched). Boris wrote "done" on 2026-11-14 without saying what; not taken as "reinstall".
- [ ] Boris accepts or rejects DEC-027 (DEC-018 and the scope line "no direct editing" stop holding if accepted) and DEC-026; REQ-001/REQ-003 still say the controls are advisory.
- [ ] Not verified: the notification permission prompt, a real multi-day run, per-CLI model flags beyond the fake agent, the supervisor's own model override end to end, the silence banner on a live run (its rule is checked as a pure function), a light-theme picture.
- [ ] Known gaps: a question or permission prompt in a step agent's own terminal is not seen (the silence warning is the mitigation); Pause interrupts the running step and the run can then only be stopped and continued from a chosen step (existing runtime behaviour, now stated on the screen); the Mac sleeping or MarkView quitting pauses a run.

