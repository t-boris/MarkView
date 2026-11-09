---
type: bug
id: BUG-056
title: Prototype generation and sync fail when Copilot runs past its output limit inside one prompt
status: done
branch: fix/bug-056-prototype-output-limit
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype generation and sync fail when Copilot runs past its output limit inside one prompt

## Summary

Building a prototype from a description failed after about 17 minutes:

```
Copilot returned an answer in an unexpected format: the answer was cut off before its JSON
ended (227596 characters after 10 continuation turns). Choose a model with a larger output
limit, or split the request into smaller steps.
```

"Sync from code" of a code-mode prototype failed the same way, reported as
`expected JSON, got I'll explore the key source files…`.

## Cause

Every failing run was a foundation file written as one escaped JSON string: `data.js` in requirements mode
(3 sessions) and in code-mode sync (1 session). The Copilot session logs show what happened:

1. Over ACP, Copilot CLI (1.0.105) continues internally when the model hits its 32K output cap. It streams
   the text of every internal turn as `agent_message_chunk` with no marker between them and returns
   `end_turn`. The joined stream held a cut answer, then a restart or a remainder, so no JSON region closed.
2. MarkView then asked for continuations. The JSON was complete after the first one, but the loop kept
   asking because the whole text still had an open region. The model answered "The answer is complete" eight
   times (10 turns, ~227 KB, about 17 minutes at Opus pricing).
3. Requirements mode had the model write the shell runtime (`app.js`, `data.js`) in every build, so the
   biggest answers of every build came near the cap, and the screens waited for all of them.

## Fix

- **ACP answers** (`ACPAssistant.swift`): a structured answer is continued only while it has no parseable
  JSON. Two short continuations that only say the answer is finished end the attempt. The parser also tries
  the last restarted `{"` regions, so a stream with an internal restart yields the final answer. The real
  texts of the failing sync replay to a parsed 81 KB `data.js` after one continuation.
- **Built-in runtime** (`PrototypeRuntime.swift`, requirements mode): MarkView writes `index.html`, `app.js`
  (the documented `App` API: router, shell with role switch and Prototype menu, toasts, modals, `App.load`,
  permissions, formatting, `renderScreen`) and `data.js` (the `DB` engine with search, filters, sorting,
  pages, persistence per prototype and forced empty state). Right after the plan, the styles, the sample
  records (`seed.js`, checked in JavaScriptCore) and all screens are written at the same time. A screen
  prompt carries the API documentation, not the runtime code. A styles or seed run that fails twice leaves
  its placeholder and is reported as a gap. Code mode still writes its shell from the original.

## Verification

- `tools/tests/acp-continuation-tests.sh`: internal restart, restart with a continuation, refused
  continuations; the new scenarios fail on the old code.
- `tools/tests/prototype-runtime-tests.sh`: the runtime in WKWebView with the Studio's error listener and
  the preview audit (routing, params, roles, DB, forced states, renderScreen, error file and line).
- `tools/tests/prototype-deadline-tests.sh`: the requirements build runs plan, styles, seed and screens;
  a broken seed becomes a gap.
- All prototype harnesses and a Debug build.
