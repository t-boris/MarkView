---
type: feature
id: markview-workspace-redesign
title: MarkView Workspace Redesign
status: verified
owner: Boris Tsekinovsky
created: 2026-09-28
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#63"
understanding_notes:
  Primary Workflow: Explicit specification handoff leads the developer to linked files in Files, with a return route to the specification in Work.
  Dependencies: Existing application capabilities must remain available while moving between workspaces.
  Acceptance Criteria: Ready-again clears the post-handoff change flag; the migration map defines the preservation checks.
  Problem: Existing capabilities compete for space in the current window.
  Permissions: Any participant with project access can mark a specification ready.
  Target Users: The primary journey serves a specification author and a developer.
  Failure Scenarios: Editing a handed-off specification keeps it ready and flags changes; ready-again clears the flag.
  Data Model: A persistent handoff revision stores actor, time, linked files, and a full feature-folder snapshot under DEC-011, DEC-012, and DEC-017.
  Notifications: Уведомления не входят в описанный путь передачи.
  Security: Существующие правила доступа сохраняются.
  Analytics: Измерение эффекта переработки не входит в первоначальную спецификацию.
questions_left: 0
---

# MarkView Workspace Redesign

## Idea

Redesign MarkView around three clear workspaces—Files, Project Map, and Work—with easier navigation, search, and AI actions, while preserving every existing capability used today.

## Problem

The current window places file navigation, editing, X-Ray, search, Git, terminals, and feature work into competing panels. The research proposes a clearer interface, but it does not establish which workflows matter most to users or verify the proposed layouts in a running app.

## Scope

In: the application shell, start screen, Files/editor, X-Ray/Project Map, feature and Git work areas, terminal placement, search, AI action presentation, project identity, and shared visual styling. Preserve existing behaviors throughout. Out for this initial specification: a claim that the redesign will increase popularity, final pixel dimensions, a replacement editor engine, and a commitment to installation or release-process changes; these need separate evidence or decisions.

## Completion

The three-column redesign shipped in MarkView 3.0.0 through [PR #65](https://github.com/t-boris/MarkView/pull/65). Its implementation and running-app checks are recorded in [verification.md](implementation/verification.md). The full live assistant and GitHub action matrix remains a separate integration check, as documented there.
