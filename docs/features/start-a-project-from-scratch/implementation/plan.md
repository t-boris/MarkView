---
type: plan
feature: start-a-project-from-scratch
title: Start a Project from Scratch
issues:
  - id: I-1
    title: Reconcile the specification foundation layout
    summary: "Resolve the conflicting storage decisions before implementation: DEC-012 specifies project-level documents under docs/project/, while DEC-014 specifies feature objects under docs/features/ and a root README. Record one authoritative layout and align the requirement references. Apply DEC-022 by treating DEC-007, rather than DEC-004, as the governing clarification decision."
    requirements: [REQ-002, REQ-004]
    decisions: [DEC-012, DEC-014, DEC-022]
  - id: I-2
    title: Enter and recover a new-project draft
    summary: Add an entry point available without an open folder. Accept an initial project description and persist the pre-bootstrap conversation as a local app draft, with resume and discard controls.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-015]
  - id: I-3
    title: Clarify and confirm project intent
    summary: Guide the user through adaptive questions, record the resulting project decisions and requirements, and present a brief for confirmation. Identify unresolved inputs that block the agreed foundation while retaining other questions for later work.
    requirements: [REQ-002]
    decisions: [DEC-003, DEC-007, DEC-016]
  - id: I-4
    title: Bootstrap the local specification workspace
    summary: After confirmation, let the user choose a parent directory and project name, create a folder only at an unused path, write the confirmed specification foundation in the resolved layout, and initialize local Git with the files uncommitted. The resulting folder must open as a MarkView specification workspace without GitHub.
    requirements: [REQ-004]
    decisions: [DEC-002, DEC-005, DEC-006, DEC-008, DEC-009, DEC-011, DEC-013, DEC-018]
  - id: I-5
    title: Choose and create an optional GitHub repository
    summary: Offer GitHub creation during bootstrap and from the created workspace. Require an authenticated owner, repository name, visibility choice, and confirmation; check access and collisions before creating or connecting, and preserve the usable local project when GitHub is skipped.
    requirements: [REQ-003]
    decisions: [DEC-001, DEC-010, DEC-017]
  - id: I-6
    title: Publish and activate the GitHub connection
    summary: Provide a reviewed initial commit and publication path, check the local remote and existing repository history, and report connection complete only after a successful linked push and active authenticated MarkView integration. Keep GitHub issue creation outside clarification and bootstrap.
    requirements: [REQ-003]
    decisions: [DEC-010, DEC-018, DEC-020, DEC-021]
  - id: I-7
    title: Recover safely from partial setup
    summary: Persist progress across local creation and GitHub connection stages. On failure, retain the draft and completed resources, show the incomplete stage, and retry against the same folder or repository without duplicate creation or an inaccurate completion state.
    requirements: [REQ-002, REQ-003, REQ-004]
    decisions: [DEC-015, DEC-019]
updated: 2026-09-27
---

# Implementation plan — Start a Project from Scratch

## I-1: Reconcile the specification foundation layout

Resolve the conflicting storage decisions before implementation: DEC-012 specifies project-level documents under docs/project/, while DEC-014 specifies feature objects under docs/features/ and a root README. Record one authoritative layout and align the requirement references. Apply DEC-022 by treating DEC-007, rather than DEC-004, as the governing clarification decision.

Requirements: REQ-002, REQ-004
Decisions: DEC-012, DEC-014, DEC-022

## I-2: Enter and recover a new-project draft

Add an entry point available without an open folder. Accept an initial project description and persist the pre-bootstrap conversation as a local app draft, with resume and discard controls.

Requirements: REQ-001, REQ-002
Decisions: DEC-015

## I-3: Clarify and confirm project intent

Guide the user through adaptive questions, record the resulting project decisions and requirements, and present a brief for confirmation. Identify unresolved inputs that block the agreed foundation while retaining other questions for later work.

Requirements: REQ-002
Decisions: DEC-003, DEC-007, DEC-016

## I-4: Bootstrap the local specification workspace

After confirmation, let the user choose a parent directory and project name, create a folder only at an unused path, write the confirmed specification foundation in the resolved layout, and initialize local Git with the files uncommitted. The resulting folder must open as a MarkView specification workspace without GitHub.

Requirements: REQ-004
Decisions: DEC-002, DEC-005, DEC-006, DEC-008, DEC-009, DEC-011, DEC-013, DEC-018

## I-5: Choose and create an optional GitHub repository

Offer GitHub creation during bootstrap and from the created workspace. Require an authenticated owner, repository name, visibility choice, and confirmation; check access and collisions before creating or connecting, and preserve the usable local project when GitHub is skipped.

Requirements: REQ-003
Decisions: DEC-001, DEC-010, DEC-017

## I-6: Publish and activate the GitHub connection

Provide a reviewed initial commit and publication path, check the local remote and existing repository history, and report connection complete only after a successful linked push and active authenticated MarkView integration. Keep GitHub issue creation outside clarification and bootstrap.

Requirements: REQ-003
Decisions: DEC-010, DEC-018, DEC-020, DEC-021

## I-7: Recover safely from partial setup

Persist progress across local creation and GitHub connection stages. On failure, retain the draft and completed resources, show the incomplete stage, and retry against the same folder or repository without duplicate creation or an inaccurate completion state.

Requirements: REQ-002, REQ-003, REQ-004
Decisions: DEC-015, DEC-019
