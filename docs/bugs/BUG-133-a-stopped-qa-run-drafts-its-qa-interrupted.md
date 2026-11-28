---
type: bug
id: BUG-133
title: A stopped QA run drafts its "QA interrupted" bug but never files it
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: end-to-end-qa
schema: 1
---

# A stopped QA run drafts its "QA interrupted" bug but never files it

## Summary

When the person presses Stop in an End-to-End QA run, the run ends and QARunModel.fileBugs drafts a "QA interrupted" bug for the interrupted check, but QABugFiler.file runs in the cancelled run task and refuses every new candidate with "Filing was cancelled." (QABugFiler.swift:164-165). No bug report is written, although the run's rule is to file a bug for every check that failed, was blocked or was interrupted. Found while building the side-by-side QA branches (2026-11-27); present on main before that change.

## Steps to reproduce

1. Open End-to-End QA on a web project with a scenario of at least one branch
2. Run it and press Stop while a check is running
3. Look at the notice under the run and at docs/bugs

## Expected

The interrupted check gets its "QA interrupted" bug report (one per Stop), and the notice names the filed bug.

## Actual

The notice says the bug could not be filed ("Filing was cancelled."), and no bug report is written.

## Environment

MarkView 7.19.0 (main), seen in hosted tests through QARunModel.start with a fake driver; not reproduced by hand in the app
