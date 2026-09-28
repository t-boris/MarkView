---
type: plan
feature: sync-documented-status-to-github-issues
title: Sync documented Feature and Bug status to GitHub issues
issues:
  - id: I-1
    title: Resolve and classify documented issue links
    summary: Resolve issue references from explicit github, issue, and issues fields and full GitHub issue URLs. Normalize targets against the project's GitHub origin, retain multiple links per item, and distinguish unlinked items from rejected targets. Report foreign repository links and pull requests as skipped without mutating them.
    requirements: [REQ-002, REQ-004]
    decisions: [DEC-001, DEC-006, DEC-010]
  - id: I-2
    title: Determine eligibility for unique linked issues
    summary: Collect all Feature and Bug links before evaluating each unique issue. Mark an issue eligible only when every linked item has status implemented, verified, or archived; retain the items that block closure. Deduplicate targets by repository and issue number so a shared issue receives one outcome while remaining traceable to every linked item.
    requirements: [REQ-003, REQ-004]
    decisions: [DEC-005, DEC-008]
  - id: I-3
    title: Apply documented status to eligible GitHub issues
    summary: Use the project's GitHub origin and gh authentication to check basic prerequisites before mutation. On a manual run, close eligible open issues with reason completed, leave ineligible and already closed issues unchanged, and make no label changes. Abort before mutation when prerequisites fail; record a target-specific failure and continue with other targets when an individual update fails.
    requirements: [REQ-001, REQ-003, REQ-004]
    decisions: [DEC-002, DEC-006, DEC-007]
  - id: I-4
    title: Add the Issues tab Sync action and run state
    summary: Add the manual Sync action to the Issues tab. Start applying changes immediately, without a preview or separate confirmation, and show progress while the run is active. Enforce the accepted single-run behavior so repeated clicks cannot start overlapping syncs.
    requirements: [REQ-001, REQ-004]
    decisions: [DEC-002, DEC-009]
  - id: I-5
    title: Present the sync outcome report
    summary: Show the completed run's per-item and per-issue outcomes as updated, unchanged, skipped, or failed, with reasons or errors where applicable. Count unique issues in the summary while preserving item–issue rows. Show rejected explicit targets once, reserve unlinked for items without explicit issue references, and apply the accepted report lifetime.
    requirements: [REQ-004]
    decisions: [DEC-001, DEC-002, DEC-008, DEC-009, DEC-010]
updated: 2026-09-28
---

# Implementation plan — Sync documented status to GitHub issues

## I-1: Resolve and classify documented issue links

Resolve issue references from explicit github, issue, and issues fields and full GitHub issue URLs. Normalize targets against the project's GitHub origin, retain multiple links per item, and distinguish unlinked items from rejected targets. Report foreign repository links and pull requests as skipped without mutating them.

Requirements: REQ-002, REQ-004
Decisions: DEC-001, DEC-006, DEC-010

## I-2: Determine eligibility for unique linked issues

Collect all Feature and Bug links before evaluating each unique issue. Mark an issue eligible only when every linked item has status implemented, verified, or archived; retain the items that block closure. Deduplicate targets by repository and issue number so a shared issue receives one outcome while remaining traceable to every linked item.

Requirements: REQ-003, REQ-004
Decisions: DEC-005, DEC-008

## I-3: Apply documented status to eligible GitHub issues

Use the project's GitHub origin and gh authentication to check basic prerequisites before mutation. On a manual run, close eligible open issues with reason completed, leave ineligible and already closed issues unchanged, and make no label changes. Abort before mutation when prerequisites fail; record a target-specific failure and continue with other targets when an individual update fails.

Requirements: REQ-001, REQ-003, REQ-004
Decisions: DEC-002, DEC-006, DEC-007

## I-4: Add the Issues tab Sync action and run state

Add the manual Sync action to the Issues tab. Start applying changes immediately, without a preview or separate confirmation, and show progress while the run is active. Enforce the accepted single-run behavior so repeated clicks cannot start overlapping syncs.

Requirements: REQ-001, REQ-004
Decisions: DEC-002, DEC-009

## I-5: Present the sync outcome report

Show the completed run's per-item and per-issue outcomes as updated, unchanged, skipped, or failed, with reasons or errors where applicable. Count unique issues in the summary while preserving item–issue rows. Show rejected explicit targets once, reserve unlinked for items without explicit issue references, and apply the accepted report lifetime.

Requirements: REQ-004
Decisions: DEC-001, DEC-002, DEC-008, DEC-009, DEC-010
