---
type: plan
feature: feature-3
title: Project-specific development workflows
issues:
  - id: I-1
    title: Store and migrate project workflows and rule variants
    summary: Introduce persistent project workflow configurations and rule variants, including automatic adoption of a backward-compatible standard workflow. Migrate existing verifiable rules and assign each existing feature and bug a variant that preserves its previous behavior. Let a person select variants for new and existing work items and choose replacements before deleting variants in use; subsequent transitions use the current configuration without rewriting history.
    requirements: [REQ-001, REQ-005]
    decisions: [DEC-016, DEC-017, DEC-019, DEC-020, DEC-021, DEC-022, DEC-024]
  - id: I-2
    title: Configure issue statuses and lifecycle roles
    summary: Support separate configurable feature and bug statuses, lifecycle roles and transition graphs, with default roles for existing statuses. Define completion and reopening from roles, keep delivery evidence independent of those roles, and require a human-selected replacement before deleting a status used by work items.
    requirements: [REQ-002, REQ-005]
    decisions: [DEC-021, DEC-023]
  - id: I-3
    title: Enforce configurable transition conditions
    summary: Evaluate transitions requested by people, AI and the system against the current workflow and assigned rule variant. Support configurable integration, pull request, check and human acceptance conditions for features and bugs; define their evidence and unavailable-evidence behavior before implementation. Preserve recorded history and allow only a person to make a one-time exception with a reason.
    requirements: [REQ-003, REQ-005]
    decisions: [DEC-016, DEC-020, DEC-022, DEC-023, DEC-025]
  - id: I-4
    title: Capture start and delivery evidence
    summary: Provide explicit evidence for manual work start and configurable delivery conditions, including a human start note, automatic verification of a published GitHub release, and human confirmation of another delivery event. Apply the selected variant's conditions to transitions for both features and bugs, including when required evidence is unavailable.
    requirements: [REQ-004, REQ-005]
    decisions: [DEC-018, DEC-025]
  - id: I-5
    title: Integrate workflow lifecycle with GitHub synchronization
    summary: Adapt existing GitHub issue synchronization to recognize completion and reopening through lifecycle roles while retaining verified-completion safeguards. Keep workflows usable without GitHub, retain existing synchronization, and require user confirmation before executing any new policy-driven GitHub action.
    requirements: [REQ-002, REQ-006]
    decisions: [DEC-016, DEC-018, DEC-023]
  - id: I-6
    title: Build project workflow configuration and assignment controls
    summary: Provide a project-level workflow editor for selecting and customizing workflows, feature and bug lifecycles, rule variants, development conditions and delivery rules. Provide human controls for assigning variants and selecting replacements for in-use statuses or variants, with validation that prevents configurations from leaving affected work items without valid references.
    requirements: [REQ-001, REQ-002, REQ-005]
    decisions: [DEC-016, DEC-019, DEC-021, DEC-023, DEC-025]
updated: 2026-11-08
---

# Implementation plan — Процессы разработки для каждого проекта

## I-1: Store and migrate project workflows and rule variants

Introduce persistent project workflow configurations and rule variants, including automatic adoption of a backward-compatible standard workflow. Migrate existing verifiable rules and assign each existing feature and bug a variant that preserves its previous behavior. Let a person select variants for new and existing work items and choose replacements before deleting variants in use; subsequent transitions use the current configuration without rewriting history.

Requirements: REQ-001, REQ-005
Decisions: DEC-016, DEC-017, DEC-019, DEC-020, DEC-021, DEC-022, DEC-024

## I-2: Configure issue statuses and lifecycle roles

Support separate configurable feature and bug statuses, lifecycle roles and transition graphs, with default roles for existing statuses. Define completion and reopening from roles, keep delivery evidence independent of those roles, and require a human-selected replacement before deleting a status used by work items.

Requirements: REQ-002, REQ-005
Decisions: DEC-021, DEC-023

## I-3: Enforce configurable transition conditions

Evaluate transitions requested by people, AI and the system against the current workflow and assigned rule variant. Support configurable integration, pull request, check and human acceptance conditions for features and bugs; define their evidence and unavailable-evidence behavior before implementation. Preserve recorded history and allow only a person to make a one-time exception with a reason.

Requirements: REQ-003, REQ-005
Decisions: DEC-016, DEC-020, DEC-022, DEC-023, DEC-025

## I-4: Capture start and delivery evidence

Provide explicit evidence for manual work start and configurable delivery conditions, including a human start note, automatic verification of a published GitHub release, and human confirmation of another delivery event. Apply the selected variant's conditions to transitions for both features and bugs, including when required evidence is unavailable.

Requirements: REQ-004, REQ-005
Decisions: DEC-018, DEC-025

## I-5: Integrate workflow lifecycle with GitHub synchronization

Adapt existing GitHub issue synchronization to recognize completion and reopening through lifecycle roles while retaining verified-completion safeguards. Keep workflows usable without GitHub, retain existing synchronization, and require user confirmation before executing any new policy-driven GitHub action.

Requirements: REQ-002, REQ-006
Decisions: DEC-016, DEC-018, DEC-023

## I-6: Build project workflow configuration and assignment controls

Provide a project-level workflow editor for selecting and customizing workflows, feature and bug lifecycles, rule variants, development conditions and delivery rules. Provide human controls for assigning variants and selecting replacements for in-use statuses or variants, with validation that prevents configurations from leaving affected work items without valid references.

Requirements: REQ-001, REQ-002, REQ-005
Decisions: DEC-016, DEC-019, DEC-021, DEC-023, DEC-025
