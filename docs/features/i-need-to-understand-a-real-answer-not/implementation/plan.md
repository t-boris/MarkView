---
type: plan
feature: i-need-to-understand-a-real-answer-not
title: "I Need to Understand: explanatory answer as the primary result"
issues:
  - id: I-1
    title: Structured answer schema with cited source references
    summary: "Extend the XRaySearch answer schema used by I Need to Understand. The answer becomes structured: what, why, how and origin sections, plus a list of typed source references (code file/component, deployment node, document, commit, PR). An explicit 'no origin found' marker is also needed. This is the data contract that the rendering, linking and saving issues build on."
    requirements: [REQ-002, REQ-003]
    decisions: [DEC-003, DEC-006]
  - id: I-2
    title: Explanatory prompt and read-only git/PR context for answers
    summary: Rewrite the I Need to Understand prompt so it explains meaning and origin rather than only location. Give the answering agent current docs (features, REQ, DEC, research), code, and read-only git log/blame and PR data. If there is no repository or PR access is unavailable, the answer must still work and say that origin was not found. A location-only answer counts as a defect.
    requirements: [REQ-002]
    decisions: [DEC-001, DEC-003, DEC-004]
  - id: I-3
    title: Answer shown expanded at the top of the X-Ray right panel
    summary: When I Need to Understand is submitted from the intake sheet or from a document, WorkspaceManager.understandInXRay opens X-Ray with the answer expanded at the top of the right panel. The answer must be visible without clicking or scrolling, and highlights and details go below it. Long answers must stay readable, with sections and scrolling. Both entry points must behave the same.
    requirements: [REQ-001]
    decisions: [DEC-002, DEC-004]
  - id: I-4
    title: Clickable evidence links and highlighting of cited places
    summary: "Highlight every code, document, component and node the answer relies on in X-Ray. Make every cited source in the answer clickable: a code, component or node link selects that place in X-Ray, a document link opens the document, and a commit/PR link opens that commit/PR."
    requirements: [REQ-003]
    decisions: [DEC-006]
  - id: I-5
    title: Explicit loading, empty and failed answer states with retry
    summary: "Replace a silently blank answer area with explicit states: loading, and error or empty (AI error, timeout, empty result). The error state shows the reason and a Retry action that re-runs the same question. Highlights that were already computed stay visible."
    requirements: [REQ-005]
    decisions: [DEC-004]
  - id: I-6
    title: Save answer as a research document (RES-nnn)
    summary: Add a 'Save as research' action to the answer panel. It creates a new docs/research RES-nnn file containing the question, the answer sections and the source list, using the next free id and never overwriting an existing file. Nothing is saved automatically, so an unsaved answer is lost when the X-Ray filter is closed.
    requirements: [REQ-004]
    decisions: [DEC-005]
updated: 2026-09-27
---

# Implementation plan — I Need to Understand: a real answer, not only X-Ray highlights

## I-1: Structured answer schema with cited source references

Extend the XRaySearch answer schema used by I Need to Understand. The answer becomes structured: what, why, how and origin sections, plus a list of typed source references (code file/component, deployment node, document, commit, PR). An explicit 'no origin found' marker is also needed. This is the data contract that the rendering, linking and saving issues build on.

Requirements: REQ-002, REQ-003
Decisions: DEC-003, DEC-006

## I-2: Explanatory prompt and read-only git/PR context for answers

Rewrite the I Need to Understand prompt so it explains meaning and origin rather than only location. Give the answering agent current docs (features, REQ, DEC, research), code, and read-only git log/blame and PR data. If there is no repository or PR access is unavailable, the answer must still work and say that origin was not found. A location-only answer counts as a defect.

Requirements: REQ-002
Decisions: DEC-001, DEC-003, DEC-004

## I-3: Answer shown expanded at the top of the X-Ray right panel

When I Need to Understand is submitted from the intake sheet or from a document, WorkspaceManager.understandInXRay opens X-Ray with the answer expanded at the top of the right panel. The answer must be visible without clicking or scrolling, and highlights and details go below it. Long answers must stay readable, with sections and scrolling. Both entry points must behave the same.

Requirements: REQ-001
Decisions: DEC-002, DEC-004

## I-4: Clickable evidence links and highlighting of cited places

Highlight every code, document, component and node the answer relies on in X-Ray. Make every cited source in the answer clickable: a code, component or node link selects that place in X-Ray, a document link opens the document, and a commit/PR link opens that commit/PR.

Requirements: REQ-003
Decisions: DEC-006

## I-5: Explicit loading, empty and failed answer states with retry

Replace a silently blank answer area with explicit states: loading, and error or empty (AI error, timeout, empty result). The error state shows the reason and a Retry action that re-runs the same question. Highlights that were already computed stay visible.

Requirements: REQ-005
Decisions: DEC-004

## I-6: Save answer as a research document (RES-nnn)

Add a 'Save as research' action to the answer panel. It creates a new docs/research RES-nnn file containing the question, the answer sections and the source list, using the next free id and never overwriting an existing file. Nothing is saved automatically, so an unsaved answer is lost when the X-Ray filter is closed.

Requirements: REQ-004
Decisions: DEC-005

## Completion

I-1 through I-6 are implemented in 2.23.0. [Verification and follow-up scope](verification.md) records the tests and native checks.
