---
type: plan
feature: sync-github-issues-with-feature-bug-status-from
title: Sync GitHub Issues with Feature/Bug status from the Issues tab
issues:
  - id: I-1
    title: "GitHub sync client: gh CLI pre-flight, issue fetch and close"
    summary: Build a GitHub sync service on top of the existing gh CLI integration. It resolves the default repository from the project's origin remote. Before a run it checks that gh is installed and authenticated and that the user has write (triage or higher) access; if any check fails it returns an actionable error (gh auth login / gh auth refresh) and makes no changes. It can fetch an issue, including whether the target is a pull request and its current state, and close an issue with state_reason 'completed'. It maps per-issue permission, not-found and rate-limit errors to typed failures. On a secondary rate limit it waits the retry-after interval once and then fails; there are no other retries. It never writes to Markdown files.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-004, DEC-003]
  - id: I-2
    title: Resolve Feature/Bug to GitHub issue links and build the issue→items index
    summary: "Read all Features and Bugs and collect explicit links only: the `github` field, front matter `issue`/`issues`, and full GitHub issue URLs. Free-text '#n' and 'issue #n' mentions are ignored. Links to repositories other than the project's repository are marked skipped with reason 'other repository'. Items with no resolvable link are marked 'unlinked'. The output is a list of item–issue pairs plus an index from each issue to all items that link to it, so later steps can apply the shared-issue rule. Unit tests cover multi-issue items, PR-looking links, foreign repos and ignored text mentions."
    requirements: [REQ-002]
    decisions: [DEC-005, DEC-008]
  - id: I-3
    title: "Sync engine: decide and apply issue closures"
    summary: Using the link index and the GitHub client, decide one outcome for each issue, and apply each issue at most once per run. An open issue is closed as completed only if every linked item is implemented, verified or archived. Otherwise it is skipped with reason 'linked to item(s) not yet implemented', listing those items. Already-closed issues are reported 'unchanged'. Targets that the API reports as pull requests are skipped with reason 'pull request'. Missing issues are skipped with reason 'issue not found'. Issues linked only to items with an earlier status are left alone. The engine never reopens issues or modifies docs, and a failure on one issue does not stop the rest. It produces per-pair outcomes for the report.
    requirements: [REQ-003, REQ-001]
    decisions: [DEC-002, DEC-008, DEC-005, DEC-003]
  - id: I-4
    title: Sync button in the Issues tab with progress and a single-run guard
    summary: Add a manual Sync action to the Issues tab. It runs straight away, with no preview or confirmation. When the pre-flight check fails, the action is disabled or aborted with the actionable gh message. During a run the button is disabled and shows 'n of m' progress. Only one run per project can be active, and further clicks are ignored. There is no cancel. When the run finishes, the result report opens.
    requirements: [REQ-001]
    decisions: [DEC-001, DEC-009, DEC-004]
  - id: I-5
    title: Sync result report view
    summary: "Show the report after every run, including runs with failures. A summary header gives counts per outcome. Below it there is one row per item–issue pair: item id/title, issue reference (owner/repo#n), and outcome. Outcomes are updated (with the change applied), unchanged, skipped (with reason) or failed (with the error message). Unlinked items each get one row with outcome skipped/unlinked. The report stays in the Issues tab until the next run or until the tab/window closes, and it is not saved to disk. Updated rows link to the issue so a wrong close can be found and reversed by hand."
    requirements: [REQ-004]
    decisions: [DEC-007, DEC-001]
updated: 2026-09-27
---

# Implementation plan — Sync GitHub Issues with Feature/Bug status from the Issues tab

## I-1: GitHub sync client: gh CLI pre-flight, issue fetch and close

Build a GitHub sync service on top of the existing gh CLI integration. It resolves the default repository from the project's origin remote. Before a run it checks that gh is installed and authenticated and that the user has write (triage or higher) access; if any check fails it returns an actionable error (gh auth login / gh auth refresh) and makes no changes. It can fetch an issue, including whether the target is a pull request and its current state, and close an issue with state_reason 'completed'. It maps per-issue permission, not-found and rate-limit errors to typed failures. On a secondary rate limit it waits the retry-after interval once and then fails; there are no other retries. It never writes to Markdown files.

Requirements: REQ-001, REQ-003
Decisions: DEC-004, DEC-003

## I-2: Resolve Feature/Bug to GitHub issue links and build the issue→items index

Read all Features and Bugs and collect explicit links only: the `github` field, front matter `issue`/`issues`, and full GitHub issue URLs. Free-text '#n' and 'issue #n' mentions are ignored. Links to repositories other than the project's repository are marked skipped with reason 'other repository'. Items with no resolvable link are marked 'unlinked'. The output is a list of item–issue pairs plus an index from each issue to all items that link to it, so later steps can apply the shared-issue rule. Unit tests cover multi-issue items, PR-looking links, foreign repos and ignored text mentions.

Requirements: REQ-002
Decisions: DEC-005, DEC-008

## I-3: Sync engine: decide and apply issue closures

Using the link index and the GitHub client, decide one outcome for each issue, and apply each issue at most once per run. An open issue is closed as completed only if every linked item is implemented, verified or archived. Otherwise it is skipped with reason 'linked to item(s) not yet implemented', listing those items. Already-closed issues are reported 'unchanged'. Targets that the API reports as pull requests are skipped with reason 'pull request'. Missing issues are skipped with reason 'issue not found'. Issues linked only to items with an earlier status are left alone. The engine never reopens issues or modifies docs, and a failure on one issue does not stop the rest. It produces per-pair outcomes for the report.

Requirements: REQ-003, REQ-001
Decisions: DEC-002, DEC-008, DEC-005, DEC-003

## I-4: Sync button in the Issues tab with progress and a single-run guard

Add a manual Sync action to the Issues tab. It runs straight away, with no preview or confirmation. When the pre-flight check fails, the action is disabled or aborted with the actionable gh message. During a run the button is disabled and shows 'n of m' progress. Only one run per project can be active, and further clicks are ignored. There is no cancel. When the run finishes, the result report opens.

Requirements: REQ-001
Decisions: DEC-001, DEC-009, DEC-004

## I-5: Sync result report view

Show the report after every run, including runs with failures. A summary header gives counts per outcome. Below it there is one row per item–issue pair: item id/title, issue reference (owner/repo#n), and outcome. Outcomes are updated (with the change applied), unchanged, skipped (with reason) or failed (with the error message). Unlinked items each get one row with outcome skipped/unlinked. The report stays in the Issues tab until the next run or until the tab/window closes, and it is not saved to disk. Updated rows link to the issue so a wrong close can be found and reversed by hand.

Requirements: REQ-004
Decisions: DEC-007, DEC-001
