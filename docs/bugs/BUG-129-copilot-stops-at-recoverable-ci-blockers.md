---
type: bug
id: BUG-129
title: Copilot stops at recoverable CI blockers
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-25
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Откуда вы запустили работу в последнем случае, когда агент остановился на CI?
    why: "От точки запуска зависит, кто управляет остановкой и повтором: Cockpit или сам агент."
    options:
      - label: Build → Cockpit
        text: Управляемый запуск из карточки задачи или фичи.
      - label: План в Cockpit
        text: План запущен непосредственно в Cockpit.
      - label: Терминал агента
        text: Задание отправлено напрямую в терминал.
    status: answered
    answer: План в Cockpit. План запущен непосредственно в Cockpit.
  - id: BQ-2
    text: Можете прислать точный текст сообщения об остановке или ссылку на запуск, PR либо проверку GitHub Actions?
    why: По сообщению и состоянию проверок можно отличить сбой CI, отсутствие проверок, проблему доступа и запрос подтверждения.
    status: open
  - id: BQ-3
    text: Если сохранился план, что было написано в шаге CI и в его разделе восстановления, если такой раздел был?
    why: По сохранённому шагу можно проверить, было ли предусмотрено исправление сбоя и какую задачу Cockpit должен был выполнить перед повторной проверкой.
    status: open
issue: "#449"
schema: 1
---

# Copilot stops at recoverable CI blockers

## Summary

Cockpit reportedly hands control back after a CI blocker in a plan launched directly from Cockpit. Direct plans support bounded prerequisite recovery when the approved plan includes it. The affected step and pause reason remain unknown. Static inspection also confirms a recovery gap in the separate managed feature path.

## Steps to reproduce

1. Candidate reproduction from code inspection. In a GitHub-backed test repository, prepare a feature-branch PR with a deterministic failing check that can be fixed by editing and committing on that branch.
2. Create and launch a plan directly in Cockpit with a CI prerequisite before delivery. Inspect the approved plan and record its recovery assignment and source-change controls. Start with a CI prerequisite that has no recovery assignment.
3. Let the check fail. Capture the Cockpit step status, pause reason, any agent question, and whether Cockpit attempts a repair and verifies the resulting PR head.
4. Repeat with an explicit recovery assignment and controls that permit the repair to isolate planning from execution. Separately, try a repository where CI is required by the approved plan and no checks are configured. Confirm that checks are absent before comparing that result with pending checks or unavailable GitHub evidence.

## Expected

When the approved Cockpit plan requires green CI, Cockpit diagnoses the check state, routes an authorized repair to a step that can edit and commit on the feature branch, and confirms that checks pass on the updated PR head before continuing delivery. It waits for pending checks, distinguishes missing checks from unavailable evidence, and provisions confirmed missing CI when the approved scope, repository rules, and permissions allow it. It follows the plan when CI is optional and asks for input when approval, access, or a user decision is required, or when authorized recovery is exhausted. Any handoff identifies the specific blocker.

## Actual

The reporter launched the plan directly in Cockpit and says Copilot stopped and asked for help when it could not get through CI. The exact message, step result, and recovery attempts are unknown. Missing CI was raised as a possible case. The reported incident has not been reproduced.

## Environment

MarkView on macOS. The reporter confirmed launching the plan directly in Cockpit. Installed version, selected assistant, and affected repository are unknown. Static inspection covered local HEAD 1b5acbe1 and the locally available origin/main at 9f7863d5. The affected run's saved plan was unavailable.

## Suspected code

- `MarkView/Models/Cockpit/CockpitPlanning.swift` — The direct planner treats prerequisite recovery as optional. The parser attaches it only when the prerequisite supplies a nonempty recovery assignment.
- `MarkView/Models/Cockpit/CockpitRun.swift` — A failed prerequisite can retry through its configured recovery assignment. Without available recovery, the run pauses.
- `MarkView/Models/Cockpit/CockpitStepAudit.swift` — The source-change audit can flag edits or commits made during a direct plan step when Fix bugs is off and changes are not allowed.
- `MarkView/Models/Cockpit/CockpitSession.swift` — Adds managed delivery steps only when feature context is present. Managed verification instructions prohibit source edits and commits, and the managed approval path can pause before a step configured to ask.
- `MarkView/Models/Cockpit/CockpitManagedRun.swift` — Adds the managed CI prerequisite without recovery. The earlier writable step is scoped to review findings. The evidence gate requires passing checks tied to the expected PR revision.
- `MarkView/Models/Cockpit/CockpitDeliveryProbe.swift` — Reads GitHub PR check evidence and tracks passed, failed, pending, and empty check results separately from unavailable GitHub evidence. An empty rollup alone does not establish that CI is unconfigured.
- `MarkView/Models/Lifecycle/DefinitionOfDone.swift` — The default CI instruction tells the agent to fix failures and wait for green checks, which conflicts with the managed verification step's write restrictions.
- `docs/features/agent-aware-implementation-runs/decisions/DEC-036.md` — Defines the managed boundary between writable steps and audited verification, including CI, and retains the existing audit for plans made outside Build.

## Likely causes

- For a plan created directly in Cockpit without a managed feature context, recovery is optional. The planner can attach a bounded recovery assignment to a prerequisite. If the approved plan omitted it, a failed CI prerequisite can pause the run immediately. Whether the affected plan omitted recovery is unknown.
- A direct plan's recovery must obey the run controls. A recovery assignment alone may be insufficient when the source-change audit disallows the feature-branch edits or commit needed to repair CI.
- The managed feature path has a separate, confirmed gap. It adds a CI verification prerequisite without recovery, the default checklist instruction tells the agent to fix failures, and the verification audit can fail the step for making those edits or commits. The earlier writable fix step handles review findings. This gap does not establish which path caused the reported stop.

## Missing information

- The affected run or exact stop message is still outstanding under BQ-2.
- The approved CI step, including whether it was a prerequisite, its recovery assignment, and the run's source-change controls.
- The affected PR head and check state at the time of the stop, including failed, pending, absent, or unavailable checks.
- The installed MarkView version and selected assistant would help match the incident to the inspected behavior.

## Validity check

**Outcome:** Still present on main (checked 2026-11-25).

**Verified against:** `origin/main` @ `9f7863d599` (2026-11-25) — Merge pull request #448 from t-boris/fix/manifest-suite-count

**Reason:** The managed Cockpit plan still adds “CI is green” as a verification prerequisite without a recovery assignment. Its prompt prohibits source edits and commits, and the earlier writable step only handles review findings. The delivery probe distinguishes failed, pending, absent, and inaccessible check evidence, but the CI gate routes neither a repairable failure nor confirmed missing CI to a writable step that can fix or provision checks and then verify the updated PR revision. If the CI step reports failure, the workflow pauses because no recovery is configured. The exact message from the reported run remains unknown.

## Clarifications

**BQ-1** Откуда вы запустили работу в последнем случае, когда агент остановился на CI?
→ План в Cockpit. План запущен непосредственно в Cockpit.

**Fix design, 2026-11-25** (asked while fixing; answered by Boris in the session)

**Q1** How should recovery for the CI step be made deterministic, independent of the model?
→ "For the CI step, with a check" (recommended option): `CockpitPlanning.parse` attaches a bounded recovery to a prerequisite that verifies CI. It is visible on the plan card and can be removed before approval. Not chosen: recovery for every prerequisite; a planner-prompt change alone.

**Q2** What should happen when repairing CI needs source changes but Fix bugs is off?
→ "Ask specifically" (recommended option): a warning before approval and a pause that names the control to change. The controls stay the person's; Fix bugs is not widened for a direct plan.

**Q3** Scope: the report also describes a confirmed gap in the managed (Build → Cockpit) path.
→ "Both paths in one release". Fixed together in PR #450 (one finding, two paths); the managed repair is recorded as DEC-037 (proposed) of agent-aware-implementation-runs.

**BQ-2** and **BQ-3** (the exact stop message, the saved plan) are still unanswered; the cause on the reported run is inferred from the code.

## Original description

У нас копайлот, не совсем копайлот, он много чего делает, он выполняет все, но понимаешь, он останавливается. Он останавливается и начинает меня спрашивать, там, я не знаю, не могу пройти CI. Ну, блин, неужели невозможно догадаться, что надо починить CI, или если вообще нет CI, а, например, сделать CI. То есть, это копайлот, он должен понимать, у него координаторы есть для этого, я не понимаю, почему он меня останавливает, почему он вообще может остановиться. Почему он не фиксует это, я понимаю, что если надо фиксовать там что-то, он мне может спросить, я могу там сделать это-сделать, окей, подтвердить, это я бы понял. Но не могу пройти уровень этот, почему, причем, как правило, это абсолютно тривиальные вещи. И как это не понимает, я не знаю, разберись с копайлотом, он должен работать точнее.
