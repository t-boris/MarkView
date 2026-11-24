---
type: plan
feature: agent-aware-implementation-runs
title: Agent-aware implementation runs from Build
issues:
  - id: I-1
    title: Recommend a launch mode in Build and prepare feature-scoped Cockpit drafts
    summary: After Definition of Done review, recommend direct handoff or Cockpit from the feature specification and selected checklist, explain the reason, and allow an override. Preserve the direct handoff with the selected checklist and mark implementation started only after successful submission. For Cockpit, prepare a feature-scoped draft from the specification, recorded answers, accepted decisions, and checklist. Show each step's assignment, proposed agent and model, and observable completion condition. Preparing or reviewing a draft must preserve other features' drafts and run associations, including during an unfinished run. If planning is blocked, identify the blocker and require an explicit choice before using direct handoff.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-011, DEC-012, DEC-013, DEC-031]
  - id: I-2
    title: Enforce managed run admission and evidence-based step selection
    summary: Separate plan approval from an explicit Start. On every Start request, enforce at most one unfinished Cockpit run per project, including simultaneous requests. Identify the blocking run and preserve the requested plan and its approval so the user can explicitly start it after the blocker ends. On start and resume, use current evidence to select the first unverified step, skip verified steps, and execute the remainder sequentially in dependency order. Apply this rule to managed runs in precedence over Cockpit DEC-016. Mark feature implementation started only after the first Cockpit step starts successfully.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-027, DEC-031]
  - id: I-3
    title: Validate launch-profile capabilities and control within-step delegation
    summary: Use the installed CLI and applicable launch-profile permissions for Claude Code, Codex, GitHub Copilot, and Antigravity to match each step's goal handling, delegation, and review needs to available capabilities. Surface a viable alternative or a visible blocker before execution. Allow independent work to be delegated within the active step only under the approved controls. Keep delegated work within the approved scope and permissions, account for outstanding work before step success, and provide the stop evidence needed to gate interrupted retries. Run without delegation or block the step when the profile cannot meet those conditions.
    requirements: [REQ-002, REQ-003]
    decisions: [DEC-013, DEC-028, DEC-030]
  - id: I-4
    title: Enforce the active time limit and gate retries on delegate shutdown
    summary: Let the user set and review the active execution time limit before plan approval, and carry elapsed active time across interruptions. At the limit, pause the run, interrupt the attempt, and show the reason, latest evidence, and any delegated work with an unconfirmed stop. Identify the delegate or process blocking retry and keep the step paused until every delegate capable of writing to the checkout is confirmed stopped. Then allow a user-initiated retry in the same checkout with existing changes preserved.
    requirements: [REQ-003]
    decisions: [DEC-027, DEC-030]
  - id: I-5
    title: Plan project delivery and enforce scheduled Ask me approvals
    summary: Plan all applicable delivery steps through merge and release, including versioning, PR creation, and CI where required. Surface conflicts between mandatory project rules and the Definition of Done before execution, omit Skip items, and record evidence for Require items. Warn before launch that agents and delegates may perform Ask me actions directly if their launch profiles permit it. Pause each scheduled Ask me action for explicit approval, and show which action blocks delivery if the user declines a mandatory action that remains incomplete.
    requirements: [REQ-002, REQ-004]
    decisions: [DEC-012, DEC-028]
  - id: I-6
    title: Reconcile interrupted and externally completed delivery actions
    summary: Before retrying an interrupted external delivery action, reconcile its recorded or remote result. Reuse confirmed results and leave uncertain actions pending. When Cockpit verifies that a scheduled action was completed externally without its approval, record that status, use the evidence to evaluate step completion, and skip the duplicate action. Track partial delivery and retain verified results for the existing lifecycle checks, including required CI for the relevant revision and applicable merge and release evidence.
    requirements: [REQ-002, REQ-003, REQ-004]
    decisions: [DEC-012, DEC-027, DEC-028]
  - id: I-7
    title: Verify implementation evidence and gate delivery on confirmed review findings
    summary: Present test evidence and independent review findings tied to the changes examined, and verify updated changes after fixes before reporting success. Before each scheduled merge or release, block delivery on confirmed independent findings that identify violations of acceptance criteria or mandatory project rules, and reflect the block in partial delivery status. Record each violated criterion or rule and the reviewed revision. Lift the block with verified fix evidence or explicit user risk acceptance with a rationale where project rules permit an exception. On a later revision, re-verify the finding and require fresh acceptance if it still blocks delivery and the user chooses to accept the risk.
    requirements: [REQ-004]
    decisions: [DEC-012, DEC-027, DEC-029]
updated: 2026-11-24
schema: 1
---

# Implementation plan — Agent-aware implementation runs

## I-1: Recommend a launch mode in Build and prepare feature-scoped Cockpit drafts

After Definition of Done review, recommend direct handoff or Cockpit from the feature specification and selected checklist, explain the reason, and allow an override. Preserve the direct handoff with the selected checklist and mark implementation started only after successful submission. For Cockpit, prepare a feature-scoped draft from the specification, recorded answers, accepted decisions, and checklist. Show each step's assignment, proposed agent and model, and observable completion condition. Preparing or reviewing a draft must preserve other features' drafts and run associations, including during an unfinished run. If planning is blocked, identify the blocker and require an explicit choice before using direct handoff.

Requirements: REQ-001, REQ-002
Decisions: DEC-011, DEC-012, DEC-013, DEC-031

## I-2: Enforce managed run admission and evidence-based step selection

Separate plan approval from an explicit Start. On every Start request, enforce at most one unfinished Cockpit run per project, including simultaneous requests. Identify the blocking run and preserve the requested plan and its approval so the user can explicitly start it after the blocker ends. On start and resume, use current evidence to select the first unverified step, skip verified steps, and execute the remainder sequentially in dependency order. Apply this rule to managed runs in precedence over Cockpit DEC-016. Mark feature implementation started only after the first Cockpit step starts successfully.

Requirements: REQ-001, REQ-002
Decisions: DEC-027, DEC-031

## I-3: Validate launch-profile capabilities and control within-step delegation

Use the installed CLI and applicable launch-profile permissions for Claude Code, Codex, GitHub Copilot, and Antigravity to match each step's goal handling, delegation, and review needs to available capabilities. Surface a viable alternative or a visible blocker before execution. Allow independent work to be delegated within the active step only under the approved controls. Keep delegated work within the approved scope and permissions, account for outstanding work before step success, and provide the stop evidence needed to gate interrupted retries. Run without delegation or block the step when the profile cannot meet those conditions.

Requirements: REQ-002, REQ-003
Decisions: DEC-013, DEC-028, DEC-030

## I-4: Enforce the active time limit and gate retries on delegate shutdown

Let the user set and review the active execution time limit before plan approval, and carry elapsed active time across interruptions. At the limit, pause the run, interrupt the attempt, and show the reason, latest evidence, and any delegated work with an unconfirmed stop. Identify the delegate or process blocking retry and keep the step paused until every delegate capable of writing to the checkout is confirmed stopped. Then allow a user-initiated retry in the same checkout with existing changes preserved.

Requirements: REQ-003
Decisions: DEC-027, DEC-030

## I-5: Plan project delivery and enforce scheduled Ask me approvals

Plan all applicable delivery steps through merge and release, including versioning, PR creation, and CI where required. Surface conflicts between mandatory project rules and the Definition of Done before execution, omit Skip items, and record evidence for Require items. Warn before launch that agents and delegates may perform Ask me actions directly if their launch profiles permit it. Pause each scheduled Ask me action for explicit approval, and show which action blocks delivery if the user declines a mandatory action that remains incomplete.

Requirements: REQ-002, REQ-004
Decisions: DEC-012, DEC-028

## I-6: Reconcile interrupted and externally completed delivery actions

Before retrying an interrupted external delivery action, reconcile its recorded or remote result. Reuse confirmed results and leave uncertain actions pending. When Cockpit verifies that a scheduled action was completed externally without its approval, record that status, use the evidence to evaluate step completion, and skip the duplicate action. Track partial delivery and retain verified results for the existing lifecycle checks, including required CI for the relevant revision and applicable merge and release evidence.

Requirements: REQ-002, REQ-003, REQ-004
Decisions: DEC-012, DEC-027, DEC-028

## I-7: Verify implementation evidence and gate delivery on confirmed review findings

Present test evidence and independent review findings tied to the changes examined, and verify updated changes after fixes before reporting success. Before each scheduled merge or release, block delivery on confirmed independent findings that identify violations of acceptance criteria or mandatory project rules, and reflect the block in partial delivery status. Record each violated criterion or rule and the reviewed revision. Lift the block with verified fix evidence or explicit user risk acceptance with a rationale where project rules permit an exception. On a later revision, re-verify the finding and require fresh acceptance if it still blocks delivery and the user chooses to accept the risk.

Requirements: REQ-004
Decisions: DEC-012, DEC-027, DEC-029
