---
type: plan
feature: markview-workspace-redesign
title: "MarkView Workspace Redesign: Three-Workspace Migration"
issues:
  - id: I-1
    title: Approve the capability inventory and migration map
    summary: Fix the current release as the preservation baseline. Inventory every user-accessible workflow, tab, panel, command, menu action, integration, and AI action; record its expected outcome, destination workspace, secondary entry points, and preservation check. Include the existing project identity elements. Review and approve the complete migration map before implementation.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-002, DEC-010, DEC-013, DEC-014]
  - id: I-2
    title: Build the adaptive three-workspace shell
    summary: Build the shared Files, Project Map, and Work shell using the approved migration map. Preserve project name, color icon, color strip, and their behavior across workspace switches. Keep primary content and collapsed actions accessible at 900 × 600 points and 200% interface text scale; verify light, dark, and increased-contrast appearances in the running app.
    requirements: [REQ-001, REQ-002, REQ-006]
    decisions: [DEC-001, DEC-010, DEC-014, DEC-015]
  - id: I-3
    title: Migrate Files, editor, and terminal workflows
    summary: Move file navigation, document and image editing, and terminal access into the mapped Files experience. Preserve tab, save, reload, file-tree, and editor outcomes and existing shortcuts unless separately decided. At constrained widths, provide an explicit editor–terminal switch and refit the terminal whenever its visible size changes.
    requirements: [REQ-001, REQ-002, REQ-006]
    decisions: [DEC-001, DEC-002, DEC-010, DEC-015]
  - id: I-4
    title: Migrate Project Map and X-Ray workflows
    summary: Place X-Ray, Project Map, and related analysis views at their approved destinations, retaining their mapped commands and routes to project files. Verify the existing analysis outcomes and navigation paths, including access when secondary panels collapse.
    requirements: [REQ-001, REQ-002, REQ-006]
    decisions: [DEC-001, DEC-002, DEC-010, DEC-015]
  - id: I-5
    title: Implement specification handoff and revision tracking
    summary: Add a persistent, unassigned handoff record in Work. Any participant with project access can hand off or mark the current specification ready again. Each handoff stores an immutable, browsable snapshot of the whole feature folder plus revision, actor, and time. Detect added, changed, and deleted files, show the current and handed-off versions, and clear the change flag by recording a new revision without changing feature status or lifecycle events.
    requirements: [REQ-002]
    decisions:
      - DEC-003
      - DEC-004
      - DEC-005
      - DEC-006
      - DEC-007
      - DEC-008
      - DEC-009
      - DEC-011
      - DEC-012
      - DEC-017
  - id: I-6
    title: Build the start and handoff resume experience
    summary: Make the start screen show how an author begins and how a developer resumes a handoff. Use explicit project-relative file links for the Files resume action and retain a route to the specification in Work. Show missing links by path; when no files are linked, offer file browsing and a return to Work.
    requirements: [REQ-002, REQ-004]
    decisions: [DEC-003, DEC-004, DEC-005, DEC-011, DEC-016]
  - id: I-7
    title: Implement shared project search
    summary: Add a keyboard-accessible shared search for project file names, content in supported readable text files, and commands available in the current context. Define supported types, exclusions, indexing progress, stale-result behavior, and result scope labels. Preserve in-document search and local filters, and verify search without an AI assistant.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-002, DEC-010, DEC-018]
  - id: I-8
    title: Expose and verify AI action lifecycles
    summary: Use the approved AI action inventory to specify and implement each action’s input scope, assistant, output location, progress, stop behavior, partial output, failure state, and review surface. Cover read-only actions, file edits, X-Ray analysis, and assistant terminals, including changes made outside MarkView. Explain unavailable actions when no assistant is configured.
    requirements: [REQ-001, REQ-005]
    decisions: [DEC-002, DEC-010, DEC-019]
  - id: I-9
    title: Verify complete workflow preservation
    summary: Run outcome checks for every item in the approved migration map against the fixed release, including Git and feature workflows, integrations, menus, shortcuts, and project identity. Exercise all three workspaces at the minimum window size and 200% text scale in the running app. Record a separate decision for every proposed preservation exception or command or shortcut change before accepting the migration.
    requirements: [REQ-001, REQ-002, REQ-006]
    decisions: [DEC-001, DEC-002, DEC-010, DEC-013, DEC-014, DEC-015]
updated: 2026-09-28
---

# Implementation plan — MarkView Workspace Redesign

## I-1: Approve the capability inventory and migration map

Fix the current release as the preservation baseline. Inventory every user-accessible workflow, tab, panel, command, menu action, integration, and AI action; record its expected outcome, destination workspace, secondary entry points, and preservation check. Include the existing project identity elements. Review and approve the complete migration map before implementation.

Requirements: REQ-001, REQ-002
Decisions: DEC-002, DEC-010, DEC-013, DEC-014

## I-2: Build the adaptive three-workspace shell

Build the shared Files, Project Map, and Work shell using the approved migration map. Preserve project name, color icon, color strip, and their behavior across workspace switches. Keep primary content and collapsed actions accessible at 900 × 600 points and 200% interface text scale; verify light, dark, and increased-contrast appearances in the running app.

Requirements: REQ-001, REQ-002, REQ-006
Decisions: DEC-001, DEC-010, DEC-014, DEC-015

## I-3: Migrate Files, editor, and terminal workflows

Move file navigation, document and image editing, and terminal access into the mapped Files experience. Preserve tab, save, reload, file-tree, and editor outcomes and existing shortcuts unless separately decided. At constrained widths, provide an explicit editor–terminal switch and refit the terminal whenever its visible size changes.

Requirements: REQ-001, REQ-002, REQ-006
Decisions: DEC-001, DEC-002, DEC-010, DEC-015

## I-4: Migrate Project Map and X-Ray workflows

Place X-Ray, Project Map, and related analysis views at their approved destinations, retaining their mapped commands and routes to project files. Verify the existing analysis outcomes and navigation paths, including access when secondary panels collapse.

Requirements: REQ-001, REQ-002, REQ-006
Decisions: DEC-001, DEC-002, DEC-010, DEC-015

## I-5: Implement specification handoff and revision tracking

Add a persistent, unassigned handoff record in Work. Any participant with project access can hand off or mark the current specification ready again. Each handoff stores an immutable, browsable snapshot of the whole feature folder plus revision, actor, and time. Detect added, changed, and deleted files, show the current and handed-off versions, and clear the change flag by recording a new revision without changing feature status or lifecycle events.

Requirements: REQ-002
Decisions: DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-008, DEC-009, DEC-011, DEC-012, DEC-017

## I-6: Build the start and handoff resume experience

Make the start screen show how an author begins and how a developer resumes a handoff. Use explicit project-relative file links for the Files resume action and retain a route to the specification in Work. Show missing links by path; when no files are linked, offer file browsing and a return to Work.

Requirements: REQ-002, REQ-004
Decisions: DEC-003, DEC-004, DEC-005, DEC-011, DEC-016

## I-7: Implement shared project search

Add a keyboard-accessible shared search for project file names, content in supported readable text files, and commands available in the current context. Define supported types, exclusions, indexing progress, stale-result behavior, and result scope labels. Preserve in-document search and local filters, and verify search without an AI assistant.

Requirements: REQ-001, REQ-003
Decisions: DEC-002, DEC-010, DEC-018

## I-8: Expose and verify AI action lifecycles

Use the approved AI action inventory to specify and implement each action’s input scope, assistant, output location, progress, stop behavior, partial output, failure state, and review surface. Cover read-only actions, file edits, X-Ray analysis, and assistant terminals, including changes made outside MarkView. Explain unavailable actions when no assistant is configured.

Requirements: REQ-001, REQ-005
Decisions: DEC-002, DEC-010, DEC-019

## I-9: Verify complete workflow preservation

Run outcome checks for every item in the approved migration map against the fixed release, including Git and feature workflows, integrations, menus, shortcuts, and project identity. Exercise all three workspaces at the minimum window size and 200% text scale in the running app. Record a separate decision for every proposed preservation exception or command or shortcut change before accepting the migration.

Requirements: REQ-001, REQ-002, REQ-006
Decisions: DEC-001, DEC-002, DEC-010, DEC-013, DEC-014, DEC-015
