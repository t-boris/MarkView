# Project Cycle Time — review and proposal (2026-11-09)

Status: **proposal, nothing is implemented.** Section 9 lists the decisions Boris has to make before any code changes.

Sources read: `LifecycleAnalytics.swift`, `LifecycleLog.swift`, `LifecycleCapture.swift`, the lifecycle part of `FeatureStore.swift`,
`LifecycleViews.swift`, the workflow model (`ProjectWorkflow.swift`, `IssueTransitionLog.swift`, `FeatureStore+Lifecycle.swift`), the
feature record `docs/features/lifecycle-event-log-cycle-time-analytics/` (DEC-001…DEC-017), and the real event log and transition
journal of this Mac (2026-09-26 … 2026-11-09). Numbers below were computed with an independent re-implementation of the app's duration
rules on that data, not by running the app.

## 1. How it works today

Two logs describe the same fact — "an item changed state" — and know nothing about each other.

| | Cycle-time log | Workflow transition journal |
|---|---|---|
| File | `~/Library/Application Support/MarkView/lifecycle-events.jsonl` (per Mac, all projects) | `<project>/.dde/lifecycle/transitions.jsonl` (per project; `.dde/` is git-ignored in this repository, so it is also per clone) |
| Key | project path + feature slug | item kind + id (features **and bugs**) |
| Vocabulary | 9 fixed stages + 2 CI details (`LifecycleStage`) | the project's own statuses, roles, rules, process variants |
| Written by | a second observer that diffs every reload (`observeLifecycle`), hand-offs, GitHub/git polls, manual marks | `IssueLifecycleCoordinator`, "the one place where a status changes" |
| Carries | actor (git user), model, note, source | actor kind (human/ai/system), evidence, override, workflow revision, variant, `replace`/`baseline`/`external` causes |
| Corrections | none by design (DEC-005) | append-only, but every record says why it exists |

Capture channels of the cycle-time log:

- **Automatic from MarkView**: `idea_created` at feature creation; `questions_resolved` (open questions 1→0), `spec_ready` (status becomes
  `ready`, or readiness reaches 100 %, or the feature is handed to implementation) and `implementation_finished` (status role becomes
  completed) by diffing each reload; `implementation_started` only from **Implement with AI** (model read from the CLI's own session log).
- **Automatic from GitHub/git** (only after `implementation_started`): PR opened → `implementation_finished`, approval → `review_done`,
  checks green → `ci_passed`, merge or a commit naming the feature → `merged_to_main`, plus CI queue/start/re-run details.
- **Manual**: six stages through *Mark stage…* (confirmation sheet, stamped now, cannot be edited).

Durations (DEC-009, DEC-014): a step is two adjacent stages; duration = **earliest** event of the start stage → **latest** event of the end
stage, calendar time; skipped stages are not bridged; negative = "inconsistent". The sheet shows median, mean and the feature count per
step, the implementation step also per model, and a CI block. The only colour that carries meaning for a metric is orange for
"inconsistent"; there is no red/green anywhere, no threshold and no drill-down from a number to the items behind it.

## 2. What the real data says

| Finding | Evidence |
|---|---|
| `review_done` and `verified` are **never recorded** | 0 of 2313 events. 3 of the 8 steps and the "Idea → verified" total are empty for every feature. |
| Manual marking is not used | 6 manual events in six weeks (3 implementation finished, 2 merged, 1 implementation started); the "Mark stage" menu has 6 entries. |
| A flow change is read as work | On 2026-11-09 at 12:52:59 the Kanban flow replaced the old statuses (144 `replace` records in the journal). The same second the cycle-time log gained 33 events (29 `implementation_finished` "Status done", 4 `spec_ready` "Handed to implementation") for 29 features. They became the *latest end* of the implementation step: the median of **Implementation started → finished** for this project is **997 h**; without those 33 events it is **1.0 h**. The log is immutable, so the damage is permanent. |
| "Latest end" inflates repeated work | `implementation_finished` is recorded for every PR and again on completion. Across all projects, 46 of 91 features with several such events have them ≥ 2 days apart. Even without the migration artefact the all-projects median is 3.5 h with earliest→latest and 1.25 h with first start → first finish. |
| Most features never reach a step | Over about 300 feature histories the valid counts per step are 104, 114, 106, 100, 0, 0, 45, 0 (coverage 0–38 %). 44 histories have no `idea_created`. The sheet shows only the numerator ("Features 104"). |
| The step order is wrong for direct-to-main work | `ci_passed → merged_to_main` is inconsistent in 9 of 54 histories (4 of 6 in this project): a commit made straight on `main` gets its CI *after* it. The workflow already knows this per process (`IntegrationPath.directToMain` vs `.pullRequest`). |
| Model names fragment | 13 distinct strings stand for about 5 models (`opus`, `claude-opus-5-5`, `Claude Opus 5.5`, `anthropic/claude-opus-5.5`, …), 1–26 items each. Per-model rows compare samples that are too small, and tasks are not normalised for size. |
| Bugs are invisible | This project has 117 bugs (541 of 720 journal records). Cycle time reads features only. |
| Bulk creation | 36 and 17 `idea_created` events within one minute in two projects: every duration from "idea" starts at the batch time. |

## 3. Pitfalls

1. **Second observer, no cause.** Diffing statuses cannot tell work from a migration, a baseline or an unverified outside edit; the
   journal can, because every record has a cause. Any new flow change repeats the 2026-11-09 artefact. (Defect, found.)
2. **Hard-coded vocabulary.** `ready`, `implementing`, readiness 100 % and a fixed list of stage names are assumptions of the standard
   feature flow. The Kanban flow works only because `ready` happens to exist; its `in-review` column is not a step anywhere.
3. **Survivorship bias.** Only finished steps are counted. An item that has been `in-progress` for 20 days contributes nothing and is
   not shown anywhere.
4. **Calendar time is not agent time.** The original problem ("how long did the AI spend implementing") is answered with elapsed time
   that includes nights, review waits and Boris's own pauses. No source of agent-active time has been checked yet.
5. **Rework is hidden.** Reopen and rollback make a step longer instead of being counted as rework.
6. **Immutable and per Mac.** No way to ignore a bad period or item; moving a repository orphans its history; a second Mac has a
   different log; the journal is not shared either (`.dde/` ignored).
7. **No window, no trend.** All time, one number per step; the mean is dragged by outliers (mean 232 h vs median 19 h for implementation
   across projects before the cleaning above).
8. **Silent write failure.** A failed append shows an error only inside the feature's Lifecycle row, not in the sheet.

## 4. What is not recorded

- Bug lifecycle (open → fixing → fixed → closed) and its time to fix, although it is the larger part of the work.
- Time in a status of the project's own flow (Kanban `in-review`, `ready`; any custom status).
- Reopen / rollback counts, overrides, blocked transitions, unverified external edits (all are in the journal already).
- Acceptance lag (completed → verified/closed) and the delivery event of the process (release, "Installed on mac"). This is the real
  replacement for the manual `verified` nobody marks.
- Which agent session worked on an item (the journal's `sessions.jsonl` knows) and for how long it was active.
- Age of items that are in progress now.

## 5. Proposal: cycle time as a view over the workflow

**Principle.** The workflow journal is the single record of state changes. Cycle time becomes a read-only projection of it, so that
(a) it follows whatever flow the project uses, (b) a rule fix repairs history because everything is recomputable, and (c) the second
observer and the fixed stage list can be deleted instead of patched.

**Layers** (each can ship alone):

1. **Status layer — features and bugs, any flow.** From the journal build per item the *stays*: status, role, entered, left, actor kind,
   cause. Records with cause `replace` and `baseline` are not events; `external` is shown with a data-quality mark. Metrics by role, so
   they work in the standard, Kanban and any custom flow:
   - *Lead time*: created → first `completed`.
   - *Cycle time*: first `active` → first `completed` of the current round (a reopen starts a new round and increments *rework*).
   - *Waiting*: created → first `active`.
   - *Time in status*: one row per status of the project's own flow.
   - *Acceptance lag*: completed → accepted, only when the flow has an acceptance step.
2. **Evidence layer — optional, needs GitHub/git.** Keep what `LifecycleCapture` already does well (PR opened, approval, checks, merge,
   CI queue, CI time, re-runs) but attach it to the item as evidence times and let the **process variant** choose what applies: no
   "CI before merge" for a direct-to-main process, no "review" row when the process has no pull request.
3. **Agent layer.** Item → agent session (journal sessions) → model, with an alias table (`opus` = `claude-opus-5-5` = …). Per-model
   rows appear only above a sample size and carry the "not size-normalised" caveat. A spike decides whether agent-active time can be
   read from the CLI logs.
4. **Specification signals — only for flows that have specification statuses.** `questions_resolved` stays as an optional marker
   (the `isPastExplore` rule already decides whether a flow has them).

**What happens to existing code.** `observeLifecycle`, `recordSpecReadyIfMissing`, the manual *Mark stage* sheet and the fixed
`LifecycleStage` chain are deleted (no old code left). `AgentModelProbe`, `LifecycleGitHub`, `LifecycleGit` and `LifecycleCICapture` stay
as the evidence layer. The existing 2313 events are read once: model and hand-off time of `implementation_started`, PR/CI/merge evidence;
the status-derived stages (and the 33 artefacts) are not carried over. History older than the journal (before 2026-11-05) can optionally
be rebuilt from the git history of the `status:` front-matter lines — a spike, not a promise.

## 6. Red, amber, green

Three signals, never mixed in one colour:

1. **Pace** — a duration against this project's own history of the same metric and process. Finished: ≤ P50 green, ≤ P85 amber, above
   red. In progress: age in the current status against the finished time in that status (above P85 = "stuck", red). Fewer than 8
   samples: grey "not enough history", no colour. Backlog (`not-started`) is neutral by default.
2. **Facts** — need no history: checks failing now, a pull request open for a long time, an item reopened (1 amber, 2+ red), a blocked
   transition, a completed item waiting for acceptance.
3. **Data quality** — not red/green, a separate marker: inconsistent order, missing boundary, bulk-created, external edit not confirmed,
   forced by override, excluded.

Layout: a **Needs attention** list first (red, then amber, with one sentence each: "in-progress 9 d; usually 1.3 d, 85 % finish in
3 d; PR #345 open, CI re-run twice"), then the metrics table with a trend arrow (median of the last 30 days against the 30 before,
coloured only with ≥ 5 samples each and a change over 20 %). Green stays quiet (small dot); the eye goes to red.

## 7. Dig in

Every number opens its explanation, three levels deep:

1. **How this number is made**: the definition in words, rule, items used, items excluded *with reasons* (missing start 205, inconsistent
   5, excluded by you 1 — each clickable), and a min / P50 / P85 / max bar.
2. **The items behind it**, sorted by value, each with its own colour and bar.
3. **The item**: its stays and evidence on one timeline, the two records that formed the duration highlighted, and a button that opens
   the feature or bug (the existing Lifecycle section stays the full history).

## 8. Reset

Nothing here deletes data; the exception is the last row, and it asks.

| Need | Mechanism |
|---|---|
| Ignore an old or bad period | **Measure since…** per project (last 30 / 90 days, since a date, all time); stored in the project's `.dde/lifecycle`. |
| Ignore one item | **Exclude from statistics** with a reason; reversible; shown with the data-quality marker. |
| An item starts over | A reopen or *Restart* starts a new *round* of the item automatically; earlier rounds stay in its timeline. |
| A rule or parser was wrong | **Recompute** — free, because the numbers are a projection. This is what the immutable log could not offer on 2026-11-09. |
| Wipe | **Delete cycle-time data of this project…** removes that project's lines from the legacy per-Mac log, after a confirmation. |

## 9. Decisions needed from Boris

1. **Direction.** A — projection over the workflow journal, delete the fixed-stage observer (recommended). B — keep the log and patch
   its rules (ignore replacements, change the aggregation); cheaper, but keeps two logs and the hard-coded vocabulary.
2. **DEC-005 (no corrections).** Allow non-destructive *measure since*, *exclude item* and *recompute*, keeping the log append-only.
3. **DEC-009 (earliest start → latest end).** Replace by *first start → first completion of the current round*, with rework counted.
4. **Scope.** Bugs from the start on the same engine (recommended).
5. **Backfill.** Spike a rebuild from git history for items older than the journal (reverses DEC-013 for status-derived steps only)?
6. **Manual marks.** Remove *Mark stage…* (6 uses in six weeks); delivery and acceptance come from the workflow's confirm-delivery
   and acceptance steps.
7. **Thresholds.** Per-project percentiles (P50/P85, ≥ 8 samples) or a configurable limit per status?

Phases, if A is approved: **1** status layer + bugs + windows/exclusions/recompute (removes the artefact for good); **2** colours,
needs-attention list, dig-in; **3** evidence layer per process, agent layer and alias table, optional git backfill.

Until phase 1 ships, this project's implementation step keeps showing about 997 h. Patching the observer alone is possible but is
exactly the quick fix the project rules ask to avoid, so it waits for decision 1.

## 10. Not verified

- The screens were not opened in the running app; the description of the UI comes from reading `LifecycleViews.swift` and
  `ContentView.swift`.
- The numbers come from a Python re-implementation of the rules on the real files, not from the Swift code; a few events arrived
  while the review ran.
- Agent-active time, rebuild from git history and the alias table are untested ideas.
