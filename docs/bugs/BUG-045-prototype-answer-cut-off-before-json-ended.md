---
type: bug
id: BUG-045
title: Prototype generation fails when the assistant's JSON answer is cut off
status: fixed
branch: fix/bug-045-acp-cut-off-json
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Prototype generation fails when the assistant's JSON answer is cut off

## Summary

A prototype build with GitHub Copilot (Claude Sonnet 5.5) ended with

```
Copilot returned an answer in an unexpected format: the answer was cut off before its JSON
ended (192130 characters). Choose a model with a larger output limit, or split the request
into smaller steps.
```

A prototype screen is one long structured answer, so a stage regularly runs past a single
turn's output limit. `ACPAssistant` already asked for the rest of such an answer, but it did so
only when the CLI reported `stopReason` `max_tokens` or `max_turn_requests`, and it appended
every continuation turn verbatim. Both assumptions fail in practice, and then the answer never
closes however many turns are spent.

## Steps to reproduce

1. Pick GitHub Copilot with Claude Sonnet 5.5 as the project assistant.
2. Open Prototype Studio and build a prototype whose screens are large.
3. Watch a stage that produces a long file.

## Expected

MarkView asks the assistant to finish the answer, joins the turns into one JSON object and the
stage completes. If the answer really cannot be finished, the failure says so and names the
effort already spent.

## Actual

The stage fails with "the answer was cut off before its JSON ended", with no continuation turn
spent at all or with turns that did not move the answer forward.

## Environment

MarkView 5.0.0 (e816bbe), GitHub Copilot CLI over ACP, model Claude Sonnet 5.5,
`MarkView/Models/ACPAssistant.swift` (`answer`, `looksCutOff`), Prototype Studio.

## Cause

Three defects in `ACPAssistant.answer`, all in the same path:

- **The stop reason decided everything.** Continuations ran only while the CLI said the turn hit
  a limit. A CLI that reports a truncated turn as `end_turn` (or a model that simply stops
  mid-object) produced zero continuation turns and an immediate failure.
- **Continuations were appended verbatim.** Asked to resume, a model often repeats the tail
  quoted back to it, or starts the whole answer again. Concatenated as-is, the text grew with
  every turn — 192 130 characters here — while its JSON stayed open.
- **`looksCutOff` only compared the first and last characters** (`{` … `}`), so a fenced or
  commented answer was misjudged in both directions.

## Resolution

`ACPAssistant` now decides completeness from the answer itself. `looksCutOff` scans the text
from its first `{`, tracking strings, escapes, braces and brackets, and reports whether the
object ever closed; text containing no JSON at all is not "cut off", so a wrong-shaped answer
still gets its repair turn. A structured answer is continued while its JSON is open regardless
of the reported stop reason; an unstructured one still follows the CLI's stop reason, and a
finished answer spends no turn even when the CLI reports a limit.

Continuation turns are joined by `join`: a turn that repeats exactly the quoted tail loses that
repeat, a turn that repeats the end of the answer in another way loses the longest agreed
overlap, and a turn that restarts the answer replaces it when it is longer. A turn that adds
nothing ends the attempt instead of burning the budget. The budget itself is 10 turns, and the
failure message now reports how many were spent.

No prompts, provider flags, models, permissions or deadlines changed; the read-only tool policy
is untouched.

## Verification

- `bash tools/tests/acp-continuation-tests.sh` — a fixture ACP assistant that stops mid-JSON with
  `end_turn`, repeats its quoted tail, restarts its answer, finishes while reporting `max_tokens`,
  never closes its object, and returns an empty continuation. The same test run against the
  pre-fix `ACPAssistant` fails with exactly the reported error.
- `bash tools/tests/cli-completion-timeout-tests.sh`, `bash tools/tests/prototype-deadline-tests.sh`,
  `bash tools/tests/prototype-tests.sh` — deadlines, Stop, provider errors, process cleanup and the
  prototype stages are unchanged.
- Debug build of the app.
