---
type: bug
id: BUG-132
title: With Fix bugs on, a Cockpit verification step may change source unnoticed
status: backlog
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: agent-aware-implementation-runs
---

# With Fix bugs on, a Cockpit verification step may change source unnoticed

## Summary

A managed Cockpit run tells its verification steps (tests, review, reverify, checks, final) "do not change source files and do not commit. MarkView compares the project before and after this step and fails it if you do" (CockpitSession.swift:1000). But CockpitStepAudit.violations looks for source changes and commits only when `!controls.fixBugs && !changesAllowed` (CockpitStepAudit.swift:37). With Fix bugs on, a verification step (changesAllowed = false) is not checked at all, so a review or re-verification that edits or commits passes. Found by reading the code on 2026-11-27, not reproduced in a run.

## Steps to reproduce

1. Start a managed (feature) Cockpit run with the Fix bugs control on.
2. Let the review or reverify step change a source file or commit.
3. Look at the step's result.

## Expected

The verification step fails and names the changed files or the commit, as its own brief says; Fix bugs loosens only the steps that write the change (and repair attempts).

## Actual

The step passes: the before/after comparison is skipped whenever Fix bugs is on.

## Environment

MarkView main at debbf5a7 (7.12.0), code reading only.
