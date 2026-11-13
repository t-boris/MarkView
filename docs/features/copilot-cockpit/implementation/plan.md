---
type: plan
feature: copilot-cockpit
title: "Copilot Cockpit: plan, execute, and observe project verification runs"
issues:
  - id: I-1
    title: Add the cockpit entry point, goal, and advisory controls
    summary: Add a project-scoped cockpit accessible from the top toolbar, with at most one interface per MarkView window. Let users enter a goal and configure scenario creation, checks, bug handling, builds, deployment, and run limits. Pass those settings as advisory instructions to the existing full-access agent terminal, disclose the lack of enforcement before launch, and identify checks of a new version that are unavailable when building is disabled.
    requirements: [REQ-001]
    decisions: [DEC-003, DEC-004, DEC-005, DEC-006]
  - id: I-2
    title: Generate, refine, and approve cockpit plans
    summary: Generate a reviewable sequential plan with selected scenarios, stages, an agent and assignment for each step, completion conditions, and explicit success criteria. Support whole-plan refinement by voice or text and keep the graph synchronized. Disclose infeasible goal parts and offer alternatives. Require explicit approval before execution, including the advisory-control disclosure and, for production QA, the exact plan and data-changing actions with explicit production confirmation; invalidate approval when the QA plan changes and retain existing production-step confirmations.
    requirements: [REQ-002]
    decisions:
      - DEC-001
      - DEC-006
      - DEC-008
      - DEC-009
      - DEC-010
      - DEC-011
      - DEC-012
      - DEC-017
      - DEC-018
  - id: I-3
    title: Execute the saved process through Temporal and agent sessions
    summary: Define and persist the test–fix–retest process stages and constraints, and use Temporal to coordinate sequential plan steps and select subsequent stages from conditions and results. Run each step in a separate assigned agent session, provide available MarkView MCP actions and advisory controls, and support an optional initial prerequisite check that pauses on failure and can be retried before subsequent steps proceed.
    requirements: [REQ-003]
    decisions: [DEC-006, DEC-009, DEC-010, DEC-013, DEC-014]
  - id: I-4
    title: Show live run state and progress evidence
    summary: Show live process state in the graph, distinguishing the current, completed, and waiting stages and explaining waits. Display current activity, pass number, scenario coverage, discovered bugs, confirmed fixes, latest changes, and blockers without an overall completion percentage.
    requirements: [REQ-004]
    decisions: []
  - id: I-5
    title: Link and retain evidence for cockpit results
    summary: Link cockpit results to existing E2E scenarios, bugs, and build logs, and retain their plan and build associations and final outcome. Exclude QA runs linked to cockpit results from automatic cleanup; warn before manual deletion and preserve the cockpit context with an indication that detailed QA data was deleted.
    requirements: [REQ-005]
    decisions: [DEC-007]
  - id: I-6
    title: Control, replan, and resume cockpit runs
    summary: Provide pause and stop controls, starting from any selected step without requiring prior-step verification, and previewing and approving changes to the remaining plan before applying them at a safe stage boundary. Preserve historical plan and build associations, renew production QA approval when its plan changes, and pause execution when MarkView closes; present the saved run for user-initiated continuation after reopening or restart. Define the handling of partially executed steps before implementing recovery, since that behavior remains undecided.
    requirements: [REQ-006]
    decisions: [DEC-001, DEC-002, DEC-008, DEC-015, DEC-016]
updated: 2026-11-13
---

# Implementation plan — Copilot Cockpit

## I-1: Add the cockpit entry point, goal, and advisory controls

Add a project-scoped cockpit accessible from the top toolbar, with at most one interface per MarkView window. Let users enter a goal and configure scenario creation, checks, bug handling, builds, deployment, and run limits. Pass those settings as advisory instructions to the existing full-access agent terminal, disclose the lack of enforcement before launch, and identify checks of a new version that are unavailable when building is disabled.

Requirements: REQ-001
Decisions: DEC-003, DEC-004, DEC-005, DEC-006

## I-2: Generate, refine, and approve cockpit plans

Generate a reviewable sequential plan with selected scenarios, stages, an agent and assignment for each step, completion conditions, and explicit success criteria. Support whole-plan refinement by voice or text and keep the graph synchronized. Disclose infeasible goal parts and offer alternatives. Require explicit approval before execution, including the advisory-control disclosure and, for production QA, the exact plan and data-changing actions with explicit production confirmation; invalidate approval when the QA plan changes and retain existing production-step confirmations.

Requirements: REQ-002
Decisions: DEC-001, DEC-006, DEC-008, DEC-009, DEC-010, DEC-011, DEC-012, DEC-017, DEC-018

## I-3: Execute the saved process through Temporal and agent sessions

Define and persist the test–fix–retest process stages and constraints, and use Temporal to coordinate sequential plan steps and select subsequent stages from conditions and results. Run each step in a separate assigned agent session, provide available MarkView MCP actions and advisory controls, and support an optional initial prerequisite check that pauses on failure and can be retried before subsequent steps proceed.

Requirements: REQ-003
Decisions: DEC-006, DEC-009, DEC-010, DEC-013, DEC-014

## I-4: Show live run state and progress evidence

Show live process state in the graph, distinguishing the current, completed, and waiting stages and explaining waits. Display current activity, pass number, scenario coverage, discovered bugs, confirmed fixes, latest changes, and blockers without an overall completion percentage.

Requirements: REQ-004

## I-5: Link and retain evidence for cockpit results

Link cockpit results to existing E2E scenarios, bugs, and build logs, and retain their plan and build associations and final outcome. Exclude QA runs linked to cockpit results from automatic cleanup; warn before manual deletion and preserve the cockpit context with an indication that detailed QA data was deleted.

Requirements: REQ-005
Decisions: DEC-007

## I-6: Control, replan, and resume cockpit runs

Provide pause and stop controls, starting from any selected step without requiring prior-step verification, and previewing and approving changes to the remaining plan before applying them at a safe stage boundary. Preserve historical plan and build associations, renew production QA approval when its plan changes, and pause execution when MarkView closes; present the saved run for user-initiated continuation after reopening or restart. Define the handling of partially executed steps before implementing recovery, since that behavior remains undecided.

Requirements: REQ-006
Decisions: DEC-001, DEC-002, DEC-008, DEC-015, DEC-016
