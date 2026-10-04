---
type: bug
id: BUG-024
title: Feature review still repeats after 4.0.0
status: fixed
branch: fix/bug-024-review-repeats
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-04
provenance: Reported in a Claude Code session
---

# Feature review still repeats after 4.0.0

## Summary

Boris: "Я не уверен, что твой подход работает… чем больше decisions там появляется, и чем больше я делаю
research, тем больше у меня новых вопросов." On `grow-garden` r01 with 4.0.0 (BUG-023), reviews raised
the same things again: "Overview still says the decision groups are open" three times (F-001, F-007,
F-011), "decision IDs reused / references point to wrong IDs" (F-006, F-010), and "REQ-002 lacks the
wire-format criteria required by DEC-007" (F-009) although REQ-002 already stated them.

## Root cause

- Race: `applyDecisions` returned at once when an apply was running. A review started while a
  resolution's apply was still rewriting REQ-002 (ai-calls.jsonl: review 16:23:30, apply:REQ-002
  16:23:31–16:23:44) and read the old text — F-009 was false.
- ID reuse: decisions had been deleted by hand; `nextID` counted only existing files, so new decisions
  took the freed numbers (DEC-002 now meant something else) while requirements still linked
  DEC-012, DEC-021…025.
- The overview was outside the apply: decisions about what it says were never written into it.
- Each review asked for more detail on what the last decisions added (tolerances, fixture sets, finer
  permission cases); delegated resolutions answered with still more detail. Explore already leaves such
  details to the implementer; Review did not.

## Resolution

- Applies run one at a time per feature; a review waits for a running one, then applies what is left.
- `nextID` skips every number still referenced in the feature; a rewritten requirement drops links to
  decisions that no longer exist.
- The apply routing can target the overview, which is corrected by exact, unique passage edits only.
- Review: details the implementer settles are not findings; statuses, sign-offs and links between
  records are bookkeeping, not findings. Delegated resolutions add the least new detail.
- "Start over" (restart the feature from its overview) is a header button instead of a ⋯ menu item.

## Verification

APFS clone of the current `grow-garden` with a QA copy (own bundle id), driven through Accessibility:
Decide for me, Run review the moment the finding closed → the review started after the apply ended
and reported nothing new; Decide all on the three stale findings → overview edited in two passages,
new decision numbered DEC-026, dangling links gone; reviews afterwards: 1, then nothing new.

## Environment

MarkView 4.0.0, Claude Code (opus) as the feature assistant.
