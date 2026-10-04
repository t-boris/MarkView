---
type: bug
id: BUG-023
title: Feature review never converges
status: fixed
branch: fix/bug-023-review-convergence
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-04
provenance: Reported in a Claude Code session
---

# Feature review never converges

## Summary

Boris: "when I work on a feature pass Review, then run it again it finds more concerns, I choose AI
decide — and after that run review again — even more concerns… the process is not narrowing." And:
"А зачем нам Resolve stage?"

## Steps to reproduce

1. A feature past Explore with approved requirements. Review → Run review.
2. Decide all for me.
3. Run review again: new findings, many of them "REQ-x contradicts DEC-y" or "REQ-x not updated per
   DEC-y". Decide all, review again: more of the same.

## Expected

Each round settles what it found; a later review reports only problems that are new, and an
implementation-ready specification gives an empty review.

## Actual

`grow-garden/docs/features/r01-product-decisions` had 7 requirements, 25 decisions and 33 findings,
all from one day. Roughly half the findings were the requirement text contradicting a decision made
to resolve an earlier finding; others repeated a resolved finding in other words ("Purge-pending
lifecycle and failure handling missing from REQ-001", resolved, then "… not in REQ-001", open), or
flagged that decisions were "proposed, not approved".

## Root cause

- Resolving a finding created a decision and linked it to the requirement, but never changed the
  requirement's statement or acceptance criteria. The next review compared the old text with the new
  decision and reported the contradiction, so every resolution produced the next finding.
- The review saw closed findings by title only, without how they were settled, and the prompt did not
  say that settled points must not be reported again. Duplicates were checked against open findings
  only.
- AI-chosen decisions are `proposed`; the review treated that status as a problem in itself.
- The separate Resolve stage repeated Review's blocker/high and contradiction cards, so the same
  findings were worked through in two places.

## Resolution

- `FeatureAssistant.applyDecisions` writes what was settled and not yet `applied` — decisions in force
  and findings resolved by their text alone — into the requirements it changes (statement and
  acceptance criteria): one call maps settlements to requirements, then each requirement is rewritten
  on its own, a later settlement overriding an earlier one. It runs after every resolution, once after
  Decide all, and before every review — which also repairs features resolved before this fix.
- The review context carries each closed finding's settlement; the prompt names closed findings,
  answered questions and decisions (proposed ones too) as settled, statuses and sign-offs as the
  team's workflow rather than findings, and an empty list as the expected result of a later review.
  A new finding with the title of any earlier finding, open or closed, is skipped. A whole review ends
  with "Review: N new findings" or "Review: nothing new".
- Rejecting a proposed decision that was already applied opens a contradiction finding on the
  requirements that carry it.
- The Resolve stage is gone (4.0.0): its own content — blocking and open questions, decisions to
  confirm, open assumptions, research gaps — is the "Before Build" section at the end of Review. A
  window that had Resolve stored opens Review.

## Verification

An APFS clone of `grow-garden` with a QA copy of the Debug build (own bundle id), driven through
Accessibility: Decide all → requirements rewritten → Run review, five rounds. New findings per review:
8 → 3 → 3 → 1 (the last ones medium edge cases, none repeating a settled point or pairing a requirement
with a decision). Two gaps were found and fixed on the way: one call over all requirements missed rules
(REQ-003 untouched), and findings closed by text alone were never written into the requirements.

## Environment

MarkView 3.24.0, Claude Code as the feature assistant.
