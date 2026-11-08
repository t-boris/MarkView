---
type: plan
feature: x-ray-comparison-by-date
title: X-Ray Comparison by Date
issues:
  - id: I-1
    title: Select a historical commit by date
    summary: Add a date-first baseline picker that lists matching commits reachable from locally available branches. Determine day membership from each commit’s committer timestamp in the user’s local time zone, and show an empty state when the selected day has no matching commits.
    requirements: [REQ-001]
    decisions: [DEC-001, DEC-003, DEC-005]
  - id: I-2
    title: Compare the selected commit with the working copy
    summary: Compare the selected commit as the baseline against the current working copy, including committed differences, uncommitted changes, and new files, and make the resulting file changes available to X-Ray.
    requirements: [REQ-002]
    decisions: [DEC-002]
  - id: I-3
    title: Show historical changes on focused and full maps
    summary: Present the historical comparison in focused and full architectural maps, highlight affected parts, and allow users to inspect file changes. Represent deleted files as clearly marked nodes with diff access on both maps, including necessary context in the focused map.
    requirements: [REQ-003]
    decisions: [DEC-004, DEC-006]
  - id: I-4
    title: Combine historical comparison with existing overlays
    summary: Enable existing applicable X-Ray overlays, including complexity and size, during historical comparison while keeping changed parts identifiable in both map modes.
    requirements: [REQ-004]
    decisions: [DEC-004, DEC-006]
updated: 2026-11-08
---

# Implementation plan — X-Ray Comparison by Date

## I-1: Select a historical commit by date

Add a date-first baseline picker that lists matching commits reachable from locally available branches. Determine day membership from each commit’s committer timestamp in the user’s local time zone, and show an empty state when the selected day has no matching commits.

Requirements: REQ-001
Decisions: DEC-001, DEC-003, DEC-005

## I-2: Compare the selected commit with the working copy

Compare the selected commit as the baseline against the current working copy, including committed differences, uncommitted changes, and new files, and make the resulting file changes available to X-Ray.

Requirements: REQ-002
Decisions: DEC-002

## I-3: Show historical changes on focused and full maps

Present the historical comparison in focused and full architectural maps, highlight affected parts, and allow users to inspect file changes. Represent deleted files as clearly marked nodes with diff access on both maps, including necessary context in the focused map.

Requirements: REQ-003
Decisions: DEC-004, DEC-006

## I-4: Combine historical comparison with existing overlays

Enable existing applicable X-Ray overlays, including complexity and size, during historical comparison while keeping changed parts identifiable in both map modes.

Requirements: REQ-004
Decisions: DEC-004, DEC-006
