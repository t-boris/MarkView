---
type: bug
id: BUG-049
title: Prototype generation fails on a narrated answer and on a shell too long to finish
status: fixed
branch: fix/bug-049-prototype-shell-too-long
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype generation fails on a narrated answer and on a shell too long to finish

## Summary

Two prototype runs with GitHub Copilot failed:

```
Copilot returned an answer in an unexpected format: the answer was cut off before its JSON
ended (208166 characters after 10 continuation turns). Choose a model with a larger output
limit, or split the request into smaller steps.
```

```
Copilot returned an answer in an unexpected format: expected JSON, got I'll read the key source
files to reproduce the real design tokens and shell layout.```json
{"summary":"Shell for the Unified Partner Portal prototype: index.html, a dough-token-based …
```

The second is a defect in how MarkView decides whether an answer is finished. The first is the
shell stage asking one turn for more than a model can produce.

## Steps to Reproduce

1. Open Prototype Studio over a large existing web application (Previews from Existing Code).
2. Generate a prototype with Copilot (Claude Sonnet 5.5).
3. Watch the foundation step.

## Expected

The shell is written, or the answer is continued until its JSON closes.

## Actual

Either the run stopped at the uncontinued, narrated answer, or it spent all ten continuation
turns on a 208 KB answer that never closed.

## Environment

- MarkView 5.1.0, macOS 13+
- GitHub Copilot CLI (ACP), Claude Sonnet 5.5

## Cause

1. `ACPAssistant.looksCutOff` scanned from the **first** `{` of the answer and returned `false`
   as soon as that one region closed. A model routinely narrates before answering ("I'll read the
   key source files…"), and that narration can quote a complete object — a design-token snippet
   here. The real, unfinished answer that followed was then judged complete, so no continuation
   turn was spent, `parseJSON` found nothing matching the schema, and the run failed with
   "expected JSON, got …" quoting the narration.
2. The shell stage asked one answer for `index.html`, `styles.css` and `app.js` together. In code
   mode those carry the reproduced design tokens, the whole design system and the full `App`
   runtime, which is past what one turn can emit; continuing it ten times reached 208 KB with the
   JSON still open.

## Resolution

- `jsonRegions` returns every top-level brace region of an answer. `looksCutOff` asks whether the
  **last** region is still open, so narration before the answer no longer hides a cut-off answer.
- `parseJSON` tries every complete region, largest first, besides the raw text, a fenced block and
  the outermost braces.
- The shell is written in two parts that run at the same time, next to the data part:
  `shellSystem` writes `index.html` and `app.js`, the new `stylesSystem` writes `styles.css`. The
  shared `shellContract` pins the class names both sides rely on, so the parts still fit together,
  and `app.js` has an explicit 60 KB budget as `data.js` and `styles.css` already had.

## Verification

- `tools/tests/acp-continuation-tests.sh` — two new scenarios: a cut-off answer behind a narrated
  object is continued and joined, and a narrated complete answer is read without spending a turn.
  Against the pre-fix `ACPAssistant.swift` the first fails with exactly the reported
  "expected JSON, got I'll read the key source files…".
- `tools/tests/prototype-tests.sh` — the two shell parts write disjoint files and share the class
  contract; the pinned prompt digests were updated on purpose.
- `tools/tests/prototype-deadline-tests.sh` — the build now runs `prototype:foundation:shell`,
  `:styles` and `:data`, and code mode asks all three for the original design tokens.
- `tools/tests/cli-completion-timeout-tests.sh`, `tools/tests/prototype-scheme-tests.sh`, and a
  Debug `xcodebuild`.
