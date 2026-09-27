---
type: plan
feature: batch-fix-with-ai-for-multiple-bugs
title: Batch "Fix with AI" for multiple bugs
issues:
  - id: I-1
    title: In-memory bug basket state per workspace window
    summary: "Add a basket model owned by the workspace window. It holds bug references (feature ID + bug ID) from any feature, survives navigation between features, and is discarded on window close, app quit or workspace switch. Stale items are cleaned up when the basket is shown and when a batch starts: deleted bugs and bugs that are no longer open are removed, with a count notice. Bugs in 'fixing' status stay in the basket, are marked unavailable and do not count toward the batch."
    requirements: [REQ-001]
    decisions: [DEC-004, DEC-005, DEC-008, DEC-010]
  - id: I-2
    title: Issues panel basket controls and basket view
    summary: Show 'Add to basket' / 'Remove from basket' only on bugs with status 'open' in the Issues panel. Add a visible basket view with the item count, the bugs and their features, and controls to remove single items or clear the basket. Show the stale-item notice and mark 'already being fixed' items. When the basket has exactly 1 bug, point the user to the existing per-bug Fix with AI.
    requirements: [REQ-001]
    decisions: [DEC-005, DEC-008, DEC-010, DEC-011]
  - id: I-3
    title: "Batch Fix with AI action: enablement, busy-terminal guard, start flow"
    summary: Add the batch 'Fix with AI' button to the basket. It is enabled only when at least 2 eligible 'open' bugs remain, and it is disabled with a tooltip while the AI terminal has an active run (this needs a way to detect a busy terminal). On start, the app re-checks statuses, excludes bugs that are no longer eligible, sets every included bug to 'fixing', sends the batch prompt and clears the basket. There is no persistent batch record. The single-bug fixBugWithAI stays unchanged.
    requirements: [REQ-001, REQ-002, REQ-004]
    decisions: [DEC-010, DEC-011, DEC-013]
  - id: I-4
    title: Batch prompt builder
    summary: "Build one combined prompt that works for both backends (claude /goal and generic, as fixBugWithAI does). For each bug it gives the workspace-relative file path, the feature ID and the title, and paths resolve correctly no matter which feature is open. For each bug it tells the AI to reproduce the bug, find the root cause, fix it and verify the fix. It also contains the branch instructions (check for a dirty tree or an existing branch and ask the user before continuing, create and check out a descriptive branch, report its name), one commit per fixed bug that references the bug ID, no commit for bugs that were not fixed, and frontmatter updates: 'fixed' only after that bug's commit exists, or 'open' plus an 'AI fix attempt' note with the reason. The AI must not touch bugs outside the batch and must report a per-bug outcome. The builder should be unit-testable on its own."
    requirements: [REQ-002, REQ-003, REQ-004, REQ-005]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-006, DEC-012]
  - id: I-5
    title: Status reflection via file watching and manual recovery
    summary: "Check that status changes the AI writes into bug files (fixing to fixed/open) appear in the Issues panel through normal file watching, with no parsing of terminal output. Confirm that bugs left in 'fixing' after an interrupted run can be reset to 'open' with the existing status control and can then be added to the basket again. Check the DEC-006 caveat: bug-file edits made on the batch branch stay on that branch until it is merged."
    requirements: [REQ-004]
    decisions: [DEC-006, DEC-013]
  - id: I-6
    title: AI 'Suggest similar' bugs for the basket
    summary: "When the basket is not empty, offer 'Suggest similar'. It returns open bugs that are not already in the basket, each with its own 'Add' control. Nothing is added automatically, and the panel says so when no similar bugs are found. Decided by DEC-014: a read-only structured AI call."
    requirements: [REQ-006]
    decisions: [DEC-005]
updated: 2026-09-27
---

# Implementation plan — Batch "Fix with AI" for multiple bugs

## I-1: In-memory bug basket state per workspace window

Add a basket model owned by the workspace window. It holds bug references (feature ID + bug ID) from any feature, survives navigation between features, and is discarded on window close, app quit or workspace switch. Stale items are cleaned up when the basket is shown and when a batch starts: deleted bugs and bugs that are no longer open are removed, with a count notice. Bugs in 'fixing' status stay in the basket, are marked unavailable and do not count toward the batch.

Requirements: REQ-001
Decisions: DEC-004, DEC-005, DEC-008, DEC-010

## I-2: Issues panel basket controls and basket view

Show 'Add to basket' / 'Remove from basket' only on bugs with status 'open' in the Issues panel. Add a visible basket view with the item count, the bugs and their features, and controls to remove single items or clear the basket. Show the stale-item notice and mark 'already being fixed' items. When the basket has exactly 1 bug, point the user to the existing per-bug Fix with AI.

Requirements: REQ-001
Decisions: DEC-005, DEC-008, DEC-010, DEC-011

## I-3: Batch Fix with AI action: enablement, busy-terminal guard, start flow

Add the batch 'Fix with AI' button to the basket. It is enabled only when at least 2 eligible 'open' bugs remain, and it is disabled with a tooltip while the AI terminal has an active run (this needs a way to detect a busy terminal). On start, the app re-checks statuses, excludes bugs that are no longer eligible, sets every included bug to 'fixing', sends the batch prompt and clears the basket. There is no persistent batch record. The single-bug fixBugWithAI stays unchanged.

Requirements: REQ-001, REQ-002, REQ-004
Decisions: DEC-010, DEC-011, DEC-013

## I-4: Batch prompt builder

Build one combined prompt that works for both backends (claude /goal and generic, as fixBugWithAI does). For each bug it gives the workspace-relative file path, the feature ID and the title, and paths resolve correctly no matter which feature is open. For each bug it tells the AI to reproduce the bug, find the root cause, fix it and verify the fix. It also contains the branch instructions (check for a dirty tree or an existing branch and ask the user before continuing, create and check out a descriptive branch, report its name), one commit per fixed bug that references the bug ID, no commit for bugs that were not fixed, and frontmatter updates: 'fixed' only after that bug's commit exists, or 'open' plus an 'AI fix attempt' note with the reason. The AI must not touch bugs outside the batch and must report a per-bug outcome. The builder should be unit-testable on its own.

Requirements: REQ-002, REQ-003, REQ-004, REQ-005
Decisions: DEC-001, DEC-002, DEC-003, DEC-006, DEC-012

## I-5: Status reflection via file watching and manual recovery

Check that status changes the AI writes into bug files (fixing to fixed/open) appear in the Issues panel through normal file watching, with no parsing of terminal output. Confirm that bugs left in 'fixing' after an interrupted run can be reset to 'open' with the existing status control and can then be added to the basket again. Check the DEC-006 caveat: bug-file edits made on the batch branch stay on that branch until it is merged.

Requirements: REQ-004
Decisions: DEC-006, DEC-013

## I-6: AI 'Suggest similar' bugs for the basket

When the basket is not empty, offer 'Suggest similar'. It returns open bugs that are not already in the basket, each with its own 'Add' control. Nothing is added automatically, and the panel says so when no similar bugs are found. Decided by DEC-014: a read-only structured AI call.

Requirements: REQ-006
Decisions: DEC-005
