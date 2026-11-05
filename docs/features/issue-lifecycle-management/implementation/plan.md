---
type: plan
feature: issue-lifecycle-management
title: Issue Lifecycle Management
issues:
  - id: I-1
    title: Implement shared lifecycle rules and actor permissions
    summary: Implement a shared lifecycle policy engine with explicit transition tables for the existing feature and bug vocabularies. Evaluate evidence and actor permissions consistently, distinguish implementation completion from acceptance verification, and support human overrides only with a non-empty reason. Return explainable rejections without changing status. Define regression reopening destinations and linked independent-work behavior; cover permitted, rejected and overridden transitions with focused checks.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-007]
  - id: I-2
    title: Persist lifecycle transitions and recoverable audit history
    summary: Implement durable transition execution and history recording around the shared policy engine. Record previous and resulting status, actor, time, reason, evidence and bypassed conditions. Prevent stale concurrent writes and duplicate commands, and preserve recoverable operation state when status persistence and history recording fail separately. Verify concurrent requests, repeated execution, interruption and storage failures without treating an incomplete operation as confirmed success.
    requirements: [REQ-004, REQ-005]
    decisions: [DEC-007]
  - id: I-3
    title: Integrate lifecycle enforcement across UI, MCP and existing workflows
    summary: Route UI, project MCP and existing automatic status-writing workflows through the shared transition service, including creation, preparation, readiness, implementation handoff, bug validation, restart and Studio workflows. Apply identical lifecycle conditions and actor permissions across entry points, return actionable rejection details, and prevent MCP callers from claiming human override authority. Make successful handoff provide start evidence; failed single or batch handoffs must not leave issues marked implementing or fixing. Verify coverage of existing status writers and partial handoff failures.
    requirements: [REQ-001, REQ-002, REQ-004]
    decisions: [DEC-007]
  - id: I-4
    title: Evaluate implementation, delivery and acceptance evidence
    summary: Collect and associate implementation work, PR merges, required checks, project-required delivery and acceptance-verification evidence with features and bugs. Complete implementation only when all associated work satisfies the applicable merge, check and release conditions; preserve the separate feature implemented and verified stages and the existing bug vocabulary. Keep ambiguous associations, incomplete source coverage and stale evidence from triggering completion. Verify multiple PRs, changed commit heads, pending delivery, regressions and separate acceptance evidence.
    requirements: [REQ-002, REQ-005]
    decisions: [DEC-007]
  - id: I-5
    title: Provide lifecycle context throughout connected AI sessions
    summary: Provide supported MarkView AI sessions with issue operations, lifecycle guidance and linked issue context identifying current status, outstanding work and next-transition conditions. Refresh context as linked work changes and direct lifecycle operations through project MCP without granting human approval or override authority. Include external sessions only after explicit connection and issue association, and distinguish MCP registration from observable workflow participation. Verify session launch, continuation, context refresh and disconnected external sessions.
    requirements: [REQ-003]
    decisions: [DEC-007]
  - id: I-6
    title: Reconcile external edits, conflicting evidence and interrupted work
    summary: Reconcile stored Markdown status, transition history and current work evidence after external edits, delayed observations, interruption and dependency recovery. Detect unsupported edits and discrepancies without accepting them as proof of lifecycle conditions, distinguish unavailable sources from confirmed absence, and prevent older observations from overwriting newer valid state. Reevaluate pending operations before retrying, apply confirmed regression reopening through the shared rules, and expose unresolved conflicts. Verify duplicate events, restart recovery, external edits and unavailable services.
    requirements: [REQ-002, REQ-004, REQ-005]
    decisions: [DEC-007]
  - id: I-7
    title: Expose lifecycle history, blocked transitions and human overrides
    summary: Expose lifecycle inspection and transition requests for features and bugs in MarkView. Present transition history, supporting evidence, blocked requests, missing conditions and discrepancies with observed work. Clearly identify human overrides, their required reason and the conditions bypassed, and display GitHub outcomes as confirmed success, failure or unconfirmed. Verify that rejected actions preserve status and that users can understand why an issue remains unfinished.
    requirements: [REQ-001, REQ-004]
    decisions: [DEC-007]
  - id: I-8
    title: Synchronize verified lifecycle state to linked GitHub issues
    summary: Automatically close linked GitHub issues only when every linked feature and bug has verified completion, and reopen them when linked work is confirmed reopened. Exclude unknown state, cancellation without verified completion and human overrides alone from closure eligibility. Recheck current links, work evidence, remote state and access before writes; reconcile uncertain remote outcomes before retries. Keep manual GitHub changes from directly changing local lifecycle status, show discrepancies, and align manual Sync with the same eligibility rules. Verify mixed linked work, link changes, remote manual edits, permission failures and responses lost after successful writes.
    requirements: [REQ-004, REQ-005, REQ-006]
    decisions: [DEC-007]
updated: 2026-11-05
---

# Implementation plan — Issue Lifecycle Management

## I-1: Implement shared lifecycle rules and actor permissions

Implement a shared lifecycle policy engine with explicit transition tables for the existing feature and bug vocabularies. Evaluate evidence and actor permissions consistently, distinguish implementation completion from acceptance verification, and support human overrides only with a non-empty reason. Return explainable rejections without changing status. Define regression reopening destinations and linked independent-work behavior; cover permitted, rejected and overridden transitions with focused checks.

Requirements: REQ-001, REQ-002
Decisions: DEC-007

## I-2: Persist lifecycle transitions and recoverable audit history

Implement durable transition execution and history recording around the shared policy engine. Record previous and resulting status, actor, time, reason, evidence and bypassed conditions. Prevent stale concurrent writes and duplicate commands, and preserve recoverable operation state when status persistence and history recording fail separately. Verify concurrent requests, repeated execution, interruption and storage failures without treating an incomplete operation as confirmed success.

Requirements: REQ-004, REQ-005
Decisions: DEC-007

## I-3: Integrate lifecycle enforcement across UI, MCP and existing workflows

Route UI, project MCP and existing automatic status-writing workflows through the shared transition service, including creation, preparation, readiness, implementation handoff, bug validation, restart and Studio workflows. Apply identical lifecycle conditions and actor permissions across entry points, return actionable rejection details, and prevent MCP callers from claiming human override authority. Make successful handoff provide start evidence; failed single or batch handoffs must not leave issues marked implementing or fixing. Verify coverage of existing status writers and partial handoff failures.

Requirements: REQ-001, REQ-002, REQ-004
Decisions: DEC-007

## I-4: Evaluate implementation, delivery and acceptance evidence

Collect and associate implementation work, PR merges, required checks, project-required delivery and acceptance-verification evidence with features and bugs. Complete implementation only when all associated work satisfies the applicable merge, check and release conditions; preserve the separate feature implemented and verified stages and the existing bug vocabulary. Keep ambiguous associations, incomplete source coverage and stale evidence from triggering completion. Verify multiple PRs, changed commit heads, pending delivery, regressions and separate acceptance evidence.

Requirements: REQ-002, REQ-005
Decisions: DEC-007

## I-5: Provide lifecycle context throughout connected AI sessions

Provide supported MarkView AI sessions with issue operations, lifecycle guidance and linked issue context identifying current status, outstanding work and next-transition conditions. Refresh context as linked work changes and direct lifecycle operations through project MCP without granting human approval or override authority. Include external sessions only after explicit connection and issue association, and distinguish MCP registration from observable workflow participation. Verify session launch, continuation, context refresh and disconnected external sessions.

Requirements: REQ-003
Decisions: DEC-007

## I-6: Reconcile external edits, conflicting evidence and interrupted work

Reconcile stored Markdown status, transition history and current work evidence after external edits, delayed observations, interruption and dependency recovery. Detect unsupported edits and discrepancies without accepting them as proof of lifecycle conditions, distinguish unavailable sources from confirmed absence, and prevent older observations from overwriting newer valid state. Reevaluate pending operations before retrying, apply confirmed regression reopening through the shared rules, and expose unresolved conflicts. Verify duplicate events, restart recovery, external edits and unavailable services.

Requirements: REQ-002, REQ-004, REQ-005
Decisions: DEC-007

## I-7: Expose lifecycle history, blocked transitions and human overrides

Expose lifecycle inspection and transition requests for features and bugs in MarkView. Present transition history, supporting evidence, blocked requests, missing conditions and discrepancies with observed work. Clearly identify human overrides, their required reason and the conditions bypassed, and display GitHub outcomes as confirmed success, failure or unconfirmed. Verify that rejected actions preserve status and that users can understand why an issue remains unfinished.

Requirements: REQ-001, REQ-004
Decisions: DEC-007

## I-8: Synchronize verified lifecycle state to linked GitHub issues

Automatically close linked GitHub issues only when every linked feature and bug has verified completion, and reopen them when linked work is confirmed reopened. Exclude unknown state, cancellation without verified completion and human overrides alone from closure eligibility. Recheck current links, work evidence, remote state and access before writes; reconcile uncertain remote outcomes before retries. Keep manual GitHub changes from directly changing local lifecycle status, show discrepancies, and align manual Sync with the same eligibility rules. Verify mixed linked work, link changes, remote manual edits, permission failures and responses lost after successful writes.

Requirements: REQ-004, REQ-005, REQ-006
Decisions: DEC-007
