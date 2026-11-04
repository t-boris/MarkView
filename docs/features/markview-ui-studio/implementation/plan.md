---
type: plan
feature: markview-ui-studio
title: MarkView UI Studio
issues:
  - id: I-1
    title: Launch and manage real application sessions
    summary: Introduce managed sessions for actual client-rendered project interfaces inside native MarkView, reusing existing launch discovery where applicable. Report preparation progress, prepared and unsupported dependencies, and scenario readiness limitations; support browser-executable Electron renderers without claiming preload, IPC, native adapters or SSR support. Replace existing-code reconstruction entry points with UI Studio while preserving requirements-based prototyping and clearly identified historical reconstructions. Verify lifecycle behavior, framework-independent launch eligibility and cleanup of session-owned processes.
    requirements: [REQ-001, REQ-006]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-004]
  - id: I-2
    title: Enforce session, bridge and agent access boundaries
    summary: Establish explicit boundaries for trusted project execution, application connections, simulation traffic and agent access. Disclose execution with user permissions, separate application and model network policies, use test credentials, filter confidential model context and prevent secrets from entering logs or evidence. Validate bridge origin, session identity and payloads, reject obsolete messages after cancellation or Reset, and enforce read-only agent access for questions. Verify rejected bridge messages, secret filtering and permission separation without claiming operating-system isolation.
    requirements: [REQ-006, REQ-001, REQ-004]
    decisions: [DEC-003, DEC-004]
  - id: I-3
    title: Build the stateful REST simulation runtime
    summary: Implement validated reusable simulation rules for supported JSON REST fetch/XHR requests, backed by shared entity state and atomic CRUD operations. Keep scenario seeds separate from mutable session state, serve registered rules without model calls, prevent duplicate write effects and restore the baseline on Reset. Unknown requests must return controlled unresolved outcomes without automatic real-service fallback. Verify consistency across list and detail views, mutation atomicity, duplicate handling and Reset.
    requirements: [REQ-002, REQ-006]
    decisions: [DEC-003, DEC-004]
  - id: I-4
    title: Prepare and validate dependency simulation rules
    summary: Prepare supported dependency rules from project evidence and trial execution, explicitly recording inferred contracts and unsupported dependencies. Add deduplicated, bounded agent preparation for unknown requests, validate candidate rules before atomic registration, and expose actionable preparation failures and scenario readiness limitations. Use cancellation and session generations to prevent timed-out or obsolete results from registering rules or mutating state. Verify concurrent unknown requests, invalid results, deadlines, cancellation and Reset during preparation.
    requirements: [REQ-002, REQ-001, REQ-006]
    decisions: [DEC-001, DEC-004]
  - id: I-5
    title: Connect visual element selection to project sources
    summary: Extend DOM selection with distinct interaction and selection modes, parent navigation, viewport controls and zoom that preserves application viewport dimensions. Add development-only source mapping for supported targets, distinguishing repeated instances from shared source nodes, and assemble selection context containing source, styles, image, route, scenario and code revision. Disclose unsupported boundaries and revalidate or clear stale and ambiguous mappings. Verify suppressed business actions, scrolling and zoom geometry, repeated components and mapping invalidation.
    requirements: [REQ-003]
    decisions: [DEC-001, DEC-004]
  - id: I-6
    title: Apply, verify and selectively undo AI source edits
    summary: Apply scoped AI changes to durable project sources while preserving existing styling conventions, clarifying material ambiguity and detecting concurrent modifications. Record requests, patches, revision identities including uncommitted changes and applied editor buffers, and verification outcomes in operation history. Support selective undo that preserves independent edits or exposes conflicts. After each edit, wait for rebuild and refresh, restore the scenario and check runtime errors; display build diagnostics and mark the previous preview stale on failure. Verify read-only questions, edit conflicts, selective undo and failed rebuilds.
    requirements: [REQ-004, REQ-005]
    decisions: [DEC-003]
  - id: I-7
    title: Save and restore reproducible UI scenarios
    summary: Persist reusable scenarios with route, baseline data, role, response rules, viewport, theme, locale, seed, test time and restoration steps separately from mutable session state. Restore populated, empty, loading, error, detail and editing states without modifying production UI code or regenerating registered rules through the model. Detect contract incompatibility and require an explicit scenario update rather than silently changing the baseline. Verify saved replay, Reset and post-edit restoration against the same scenario conditions.
    requirements: [REQ-005, REQ-002, REQ-004]
    decisions: [DEC-004]
  - id: I-8
    title: Compare UI changes and export revision-linked feature evidence
    summary: Capture before and after evidence from the same baseline scenario and restoration steps, recording rendering conditions and code revisions, and provide side-by-side and image-difference review. Integrate feature export with the existing feature-writing path to include the description, patch, baseline and final revisions, scenario, rendering metadata, captures and verification results. Retain historical captures while marking packages for revalidation when baseline code changes, exclude secrets and avoid automatically adding large images to Git. Verify package completeness, comparable capture conditions and stale-evidence marking.
    requirements: [REQ-005, REQ-006]
    decisions: []
updated: 2026-11-04
---

# Implementation plan — MarkView UI Studio

## I-1: Launch and manage real application sessions

Introduce managed sessions for actual client-rendered project interfaces inside native MarkView, reusing existing launch discovery where applicable. Report preparation progress, prepared and unsupported dependencies, and scenario readiness limitations; support browser-executable Electron renderers without claiming preload, IPC, native adapters or SSR support. Replace existing-code reconstruction entry points with UI Studio while preserving requirements-based prototyping and clearly identified historical reconstructions. Verify lifecycle behavior, framework-independent launch eligibility and cleanup of session-owned processes.

Requirements: REQ-001, REQ-006
Decisions: DEC-001, DEC-002, DEC-003, DEC-004

## I-2: Enforce session, bridge and agent access boundaries

Establish explicit boundaries for trusted project execution, application connections, simulation traffic and agent access. Disclose execution with user permissions, separate application and model network policies, use test credentials, filter confidential model context and prevent secrets from entering logs or evidence. Validate bridge origin, session identity and payloads, reject obsolete messages after cancellation or Reset, and enforce read-only agent access for questions. Verify rejected bridge messages, secret filtering and permission separation without claiming operating-system isolation.

Requirements: REQ-006, REQ-001, REQ-004
Decisions: DEC-003, DEC-004

## I-3: Build the stateful REST simulation runtime

Implement validated reusable simulation rules for supported JSON REST fetch/XHR requests, backed by shared entity state and atomic CRUD operations. Keep scenario seeds separate from mutable session state, serve registered rules without model calls, prevent duplicate write effects and restore the baseline on Reset. Unknown requests must return controlled unresolved outcomes without automatic real-service fallback. Verify consistency across list and detail views, mutation atomicity, duplicate handling and Reset.

Requirements: REQ-002, REQ-006
Decisions: DEC-003, DEC-004

## I-4: Prepare and validate dependency simulation rules

Prepare supported dependency rules from project evidence and trial execution, explicitly recording inferred contracts and unsupported dependencies. Add deduplicated, bounded agent preparation for unknown requests, validate candidate rules before atomic registration, and expose actionable preparation failures and scenario readiness limitations. Use cancellation and session generations to prevent timed-out or obsolete results from registering rules or mutating state. Verify concurrent unknown requests, invalid results, deadlines, cancellation and Reset during preparation.

Requirements: REQ-002, REQ-001, REQ-006
Decisions: DEC-001, DEC-004

## I-5: Connect visual element selection to project sources

Extend DOM selection with distinct interaction and selection modes, parent navigation, viewport controls and zoom that preserves application viewport dimensions. Add development-only source mapping for supported targets, distinguishing repeated instances from shared source nodes, and assemble selection context containing source, styles, image, route, scenario and code revision. Disclose unsupported boundaries and revalidate or clear stale and ambiguous mappings. Verify suppressed business actions, scrolling and zoom geometry, repeated components and mapping invalidation.

Requirements: REQ-003
Decisions: DEC-001, DEC-004

## I-6: Apply, verify and selectively undo AI source edits

Apply scoped AI changes to durable project sources while preserving existing styling conventions, clarifying material ambiguity and detecting concurrent modifications. Record requests, patches, revision identities including uncommitted changes and applied editor buffers, and verification outcomes in operation history. Support selective undo that preserves independent edits or exposes conflicts. After each edit, wait for rebuild and refresh, restore the scenario and check runtime errors; display build diagnostics and mark the previous preview stale on failure. Verify read-only questions, edit conflicts, selective undo and failed rebuilds.

Requirements: REQ-004, REQ-005
Decisions: DEC-003

## I-7: Save and restore reproducible UI scenarios

Persist reusable scenarios with route, baseline data, role, response rules, viewport, theme, locale, seed, test time and restoration steps separately from mutable session state. Restore populated, empty, loading, error, detail and editing states without modifying production UI code or regenerating registered rules through the model. Detect contract incompatibility and require an explicit scenario update rather than silently changing the baseline. Verify saved replay, Reset and post-edit restoration against the same scenario conditions.

Requirements: REQ-005, REQ-002, REQ-004
Decisions: DEC-004

## I-8: Compare UI changes and export revision-linked feature evidence

Capture before and after evidence from the same baseline scenario and restoration steps, recording rendering conditions and code revisions, and provide side-by-side and image-difference review. Integrate feature export with the existing feature-writing path to include the description, patch, baseline and final revisions, scenario, rendering metadata, captures and verification results. Retain historical captures while marking packages for revalidation when baseline code changes, exclude secrets and avoid automatically adding large images to Git. Verify package completeness, comparable capture conditions and stale-evidence marking.

Requirements: REQ-005, REQ-006
