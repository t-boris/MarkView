---
type: plan
feature: bug-validity-check-before-analysis
title: Bug Validity Check Before Analysis
issues:
  - id: I-1
    title: Implement main-based bug validity checks
    summary: Implement a read-only validity checker returning still-present, already-fixed, or inconclusive against an identifiable main revision. Record the baseline and scenario-specific evidence or uncertainty reason. Exclude uncommitted changes and fixes confined to other branches from resolution evidence; unavailable main, verification errors, missing tools, and inability to reproduce alone must never establish resolution. Allow affirmative code or verification evidence without requiring a release. Verify these classifications with focused fixtures.
    requirements: [REQ-001, REQ-002, REQ-004]
    decisions: [DEC-001, DEC-002, DEC-004]
    github: 283
  - id: I-2
    title: Gate every existing-bug analysis entry point
    summary: Route explicit investigation, question-answer submission, and discussion submission through the validity checker before any analytical AI call. In particular, move the check ahead of the existing discussion reply analysis, which currently precedes investigateBug. Preserve submitted user input, continue existing analysis for still-present and inconclusive outcomes, and pass uncertainty and its reason into the analysis. Route already-fixed results to the closure handler and stop further investigation after successful closure. Verify all three entry paths and confirm that selecting a bug alone starts no analysis.
    requirements: [REQ-001, REQ-003, REQ-004]
    decisions: [DEC-002, DEC-004]
    github: 284
  - id: I-3
    title: Persist evidence-backed closure and report its outcome
    summary: Implement a local closure handler that saves closed status together with the verification baseline, supporting evidence addressing the reported scenario, and an explanation of why no further correction is needed. Preserve this evidence through later report rewrites. Close only on sufficient affirmative evidence; otherwise preserve the current lifecycle status. Return successful closure only after persistence succeeds, surface save failures without claiming closure, and visibly identify successful automatic closure and its reason. Verify persistence success and failure, evidence retention, and that automatic closure makes no GitHub updates or comments while preserving eligibility for manual Sync under existing linking rules.
    requirements: [REQ-002, REQ-003, REQ-004, REQ-005]
    decisions: [DEC-001, DEC-003, DEC-004]
    github: 285
updated: 2026-11-04
---

# Implementation plan — Bug Validity Check Before Analysis

## I-1: Implement main-based bug validity checks

Implement a read-only validity checker returning still-present, already-fixed, or inconclusive against an identifiable main revision. Record the baseline and scenario-specific evidence or uncertainty reason. Exclude uncommitted changes and fixes confined to other branches from resolution evidence; unavailable main, verification errors, missing tools, and inability to reproduce alone must never establish resolution. Allow affirmative code or verification evidence without requiring a release. Verify these classifications with focused fixtures.

Requirements: REQ-001, REQ-002, REQ-004
Decisions: DEC-001, DEC-002, DEC-004

## I-2: Gate every existing-bug analysis entry point

Route explicit investigation, question-answer submission, and discussion submission through the validity checker before any analytical AI call. In particular, move the check ahead of the existing discussion reply analysis, which currently precedes investigateBug. Preserve submitted user input, continue existing analysis for still-present and inconclusive outcomes, and pass uncertainty and its reason into the analysis. Route already-fixed results to the closure handler and stop further investigation after successful closure. Verify all three entry paths and confirm that selecting a bug alone starts no analysis.

Requirements: REQ-001, REQ-003, REQ-004
Decisions: DEC-002, DEC-004

## I-3: Persist evidence-backed closure and report its outcome

Implement a local closure handler that saves closed status together with the verification baseline, supporting evidence addressing the reported scenario, and an explanation of why no further correction is needed. Preserve this evidence through later report rewrites. Close only on sufficient affirmative evidence; otherwise preserve the current lifecycle status. Return successful closure only after persistence succeeds, surface save failures without claiming closure, and visibly identify successful automatic closure and its reason. Verify persistence success and failure, evidence retention, and that automatic closure makes no GitHub updates or comments while preserving eligibility for manual Sync under existing linking rules.

Requirements: REQ-002, REQ-003, REQ-004, REQ-005
Decisions: DEC-001, DEC-003, DEC-004
