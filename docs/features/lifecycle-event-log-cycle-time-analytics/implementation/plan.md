---
type: plan
feature: lifecycle-event-log-cycle-time-analytics
title: Lifecycle event log & cycle-time analytics
issues:
  - id: I-1
    title: Local lifecycle event store and event model
    summary: "Build the append-only event log in MarkView's local application storage. Each event is keyed by the project root's absolute path plus the feature id. It carries the fixed field set: event type (limited to the nine canonical stages), timestamp, actor, capture source, an optional AI model and an optional note. There is no API to edit, void or delete events. Orphaned events after a repo move, rename or feature deletion behave as defined in DEC-012. Other issues query the log through a read API."
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-006, DEC-005, DEC-012, DEC-015, DEC-002]
    github: 3
  - id: I-2
    title: Actor resolution and AI model registry
    summary: Work out the actor from the project repository's git user.name, falling back to the OS user name. Keep a per-machine list of previously used AI model names. New names are trimmed and deduplicated case-insensitively, and the user can add a new name. The list feeds the combo box used when marking stages manually.
    requirements: [REQ-002]
    decisions: [DEC-011, DEC-015]
    github: 4
  - id: I-3
    title: Automatic capture of idea created, questions resolved and spec ready
    summary: Hook into MarkView's state changes. Record 'idea created' when a feature is created. Record 'questions resolved' when the open-question count goes from 1 or more to 0. Record 'spec ready' whenever the feature status moves into 'ready'. Both repeat on every such transition. These events are stored with capture source 'automatic' and the resolved actor. There is no backfill for features that already exist.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-002, DEC-006, DEC-008, DEC-013]
    github: 5
  - id: I-4
    title: Manual stage marking UI with confirmation
    summary: "Add a feature-page action to mark the six manual stages: implementation started, implementation finished, review done, CI passed, merged to main and verified. Automatic stages cannot be marked manually. Each mark uses the current time (no back-dating) and goes through a confirmation dialog showing the feature, stage, actor and model, with a warning if that stage already has an event. The AI model is required on 'implementation started' and prefilled on 'implementation finished'. The user can add an optional note."
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-002, DEC-006, DEC-010, DEC-011, DEC-013, DEC-015]
    github: 6
  - id: I-5
    title: Duration calculation engine
    summary: A pure, unit-tested module that turns a feature's events into step durations. A step is a pair of adjacent canonical stages. Its duration runs from the earliest start event to the latest end event. Skipped stages are not bridged. A negative result is flagged as 'inconsistent'. Total idea-to-verified runs from the earliest 'idea created' to the latest 'verified'. Durations are calendar time. The module also formats durations as 'Xd Yh Zm', rounded to the minute.
    requirements: [REQ-003, REQ-004]
    decisions: [DEC-009, DEC-006, DEC-013, DEC-014]
    github: 7
  - id: I-6
    title: Feature page event timeline
    summary: Show all raw events on the feature page in chronological order, repeats included, with timestamp, actor, model, capture source and note. Show each step's duration, or no duration or 'inconsistent' where it applies, and the total idea-to-verified time when both events exist.
    requirements: [REQ-003]
    decisions: [DEC-004, DEC-009, DEC-014]
    github: 8
  - id: I-7
    title: Per-project summary table by step and AI model
    summary: Add a per-project report listing each canonical step with its median, mean and feature count, counting only valid durations. The 'implementation started → implementation finished' step is also broken down by the model on its start event. Only the current project is included, with no charts.
    requirements: [REQ-004]
    decisions: [DEC-004, DEC-009, DEC-011, DEC-014]
    github: 9
updated: 2026-09-26
epic: 10
---

# Implementation plan — Lifecycle event log & cycle-time analytics

## I-1: Local lifecycle event store and event model (#3)

Build the append-only event log in MarkView's local application storage. Each event is keyed by the project root's absolute path plus the feature id. It carries the fixed field set: event type (limited to the nine canonical stages), timestamp, actor, capture source, an optional AI model and an optional note. There is no API to edit, void or delete events. Orphaned events after a repo move, rename or feature deletion behave as defined in DEC-012. Other issues query the log through a read API.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-006, DEC-005, DEC-012, DEC-015, DEC-002

## I-2: Actor resolution and AI model registry (#4)

Work out the actor from the project repository's git user.name, falling back to the OS user name. Keep a per-machine list of previously used AI model names. New names are trimmed and deduplicated case-insensitively, and the user can add a new name. The list feeds the combo box used when marking stages manually.

Requirements: REQ-002
Decisions: DEC-011, DEC-015

## I-3: Automatic capture of idea created, questions resolved and spec ready (#5)

Hook into MarkView's state changes. Record 'idea created' when a feature is created. Record 'questions resolved' when the open-question count goes from 1 or more to 0. Record 'spec ready' whenever the feature status moves into 'ready'. Both repeat on every such transition. These events are stored with capture source 'automatic' and the resolved actor. There is no backfill for features that already exist.

Requirements: REQ-001, REQ-002
Decisions: DEC-002, DEC-006, DEC-008, DEC-013

## I-4: Manual stage marking UI with confirmation (#6)

Add a feature-page action to mark the six manual stages: implementation started, implementation finished, review done, CI passed, merged to main and verified. Automatic stages cannot be marked manually. Each mark uses the current time (no back-dating) and goes through a confirmation dialog showing the feature, stage, actor and model, with a warning if that stage already has an event. The AI model is required on 'implementation started' and prefilled on 'implementation finished'. The user can add an optional note.

Requirements: REQ-001, REQ-002
Decisions: DEC-002, DEC-006, DEC-010, DEC-011, DEC-013, DEC-015

## I-5: Duration calculation engine (#7)

A pure, unit-tested module that turns a feature's events into step durations. A step is a pair of adjacent canonical stages. Its duration runs from the earliest start event to the latest end event. Skipped stages are not bridged. A negative result is flagged as 'inconsistent'. Total idea-to-verified runs from the earliest 'idea created' to the latest 'verified'. Durations are calendar time. The module also formats durations as 'Xd Yh Zm', rounded to the minute.

Requirements: REQ-003, REQ-004
Decisions: DEC-009, DEC-006, DEC-013, DEC-014

## I-6: Feature page event timeline (#8)

Show all raw events on the feature page in chronological order, repeats included, with timestamp, actor, model, capture source and note. Show each step's duration, or no duration or 'inconsistent' where it applies, and the total idea-to-verified time when both events exist.

Requirements: REQ-003
Decisions: DEC-004, DEC-009, DEC-014

## I-7: Per-project summary table by step and AI model (#9)

Add a per-project report listing each canonical step with its median, mean and feature count, counting only valid durations. The 'implementation started → implementation finished' step is also broken down by the model on its start event. Only the current project is included, with no charts.

Requirements: REQ-004
Decisions: DEC-004, DEC-009, DEC-011, DEC-014
