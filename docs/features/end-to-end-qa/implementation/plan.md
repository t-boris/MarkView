---
type: plan
feature: end-to-end-qa
title: End-to-End QA
issues:
  - id: I-1
    title: Design and persist branching QA scenarios
    summary: Generate a branching QA scenario from a natural-language goal, including actions, expected checks, alternatives, and possible failures. Provide a visual editor for inspecting and extending branches, modifying actions, and selecting paths or options. Persist scenarios and edits as reusable project assets that can be reopened, edited, and run across MarkView sessions.
    requirements: [REQ-001]
    decisions: [DEC-006]
  - id: I-2
    title: Prepare environments, actors, and branch conditions
    summary: Provide preparation for local, development, and production targets, including actor definitions and supplied credentials or test-account creation where possible. Present preparation and the scenario for approval, and obtain explicit confirmation for production actions that change data. For each selected branch, establish its prepared baseline and attempt to establish and verify its condition; leave the branch unexecuted and report it as uncovered when the condition is not achieved.
    requirements: [REQ-002, REQ-003]
    decisions: [DEC-002, DEC-011]
  - id: I-3
    title: Execute and report multi-actor QA checks
    summary: Implement run orchestration for multiple user-selected branches as separate checks, with a separate outcome for each and distinct failed, blocked, and interrupted outcomes. Execute each branch only after its approved baseline and condition have been established; do not report a check as completed when its baseline cannot be established. Support coordinated web actors in independent MarkView browser sessions and native macOS actors against a user-selected installed application launched by MarkView, without mixing application types in one check; handle native launch failure without reporting completion.
    requirements: [REQ-003]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-005, DEC-007, DEC-008, DEC-010, DEC-011]
  - id: I-4
    title: Control sensitive material in QA artifacts
    summary: Let users specify which web pages, native screens, and data may be saved or transmitted before recording and AI analysis. Apply those choices and hide sensitive data in saved recordings and in material transmitted for analysis.
    requirements: [REQ-004, REQ-005]
    decisions: [DEC-004]
  - id: I-5
    title: Record and associate QA execution video
    summary: Record scenario execution for supported web and native macOS checks and associate the resulting video with its run, respecting the user's choices about saved material and sensitive-data handling.
    requirements: [REQ-004]
    decisions: [DEC-001, DEC-003, DEC-004, DEC-005]
  - id: I-6
    title: Analyze QA results and create bug reports
    summary: Analyze permitted key web pages and native macOS screens for UI and UX quality and possible bugs, and create MarkView bug reports for detected bugs in both application types. Automatically create a report for every failed, blocked, or interrupted check, identifying its outcome even when the issue may not be a product defect.
    requirements: [REQ-005]
    decisions: [DEC-004, DEC-009, DEC-010]
updated: 2026-11-09
---

# Implementation plan — End-to-End QA

## I-1: Design and persist branching QA scenarios

Generate a branching QA scenario from a natural-language goal, including actions, expected checks, alternatives, and possible failures. Provide a visual editor for inspecting and extending branches, modifying actions, and selecting paths or options. Persist scenarios and edits as reusable project assets that can be reopened, edited, and run across MarkView sessions.

Requirements: REQ-001
Decisions: DEC-006

## I-2: Prepare environments, actors, and branch conditions

Provide preparation for local, development, and production targets, including actor definitions and supplied credentials or test-account creation where possible. Present preparation and the scenario for approval, and obtain explicit confirmation for production actions that change data. For each selected branch, establish its prepared baseline and attempt to establish and verify its condition; leave the branch unexecuted and report it as uncovered when the condition is not achieved.

Requirements: REQ-002, REQ-003
Decisions: DEC-002, DEC-011

## I-3: Execute and report multi-actor QA checks

Implement run orchestration for multiple user-selected branches as separate checks, with a separate outcome for each and distinct failed, blocked, and interrupted outcomes. Execute each branch only after its approved baseline and condition have been established; do not report a check as completed when its baseline cannot be established. Support coordinated web actors in independent MarkView browser sessions and native macOS actors against a user-selected installed application launched by MarkView, without mixing application types in one check; handle native launch failure without reporting completion.

Requirements: REQ-003
Decisions: DEC-001, DEC-002, DEC-003, DEC-005, DEC-007, DEC-008, DEC-010, DEC-011

## I-4: Control sensitive material in QA artifacts

Let users specify which web pages, native screens, and data may be saved or transmitted before recording and AI analysis. Apply those choices and hide sensitive data in saved recordings and in material transmitted for analysis.

Requirements: REQ-004, REQ-005
Decisions: DEC-004

## I-5: Record and associate QA execution video

Record scenario execution for supported web and native macOS checks and associate the resulting video with its run, respecting the user's choices about saved material and sensitive-data handling.

Requirements: REQ-004
Decisions: DEC-001, DEC-003, DEC-004, DEC-005

## I-6: Analyze QA results and create bug reports

Analyze permitted key web pages and native macOS screens for UI and UX quality and possible bugs, and create MarkView bug reports for detected bugs in both application types. Automatically create a report for every failed, blocked, or interrupted check, identifying its outcome even when the issue may not be a product defect.

Requirements: REQ-005
Decisions: DEC-004, DEC-009, DEC-010
