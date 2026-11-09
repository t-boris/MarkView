---
type: bug
id: BUG-051
title: Prototype revision of the whole prototype fails with an empty answer
status: done
branch: fix/bug-051-prototype-revise-whole
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype revision of the whole prototype fails with an empty answer

## Summary

A review request that touches every file of a large prototype ("Convert all preview to english", 45 of 49 files, about 450 KB) fails in Prototype Studio with "The answer contained no files, edits or deletes." Retry gives the same result. Revising is one read-only run that must return every change in one answer, so the model either returns nothing or a few edits and says the work is incomplete. When it returns nothing, the model's own summary is thrown away and the second attempt is told its edits did not match, which is wrong for an empty answer.

## Steps to reproduce

1. Open a code-mode prototype of a large app (strikedesk in broker-fabric: 49 site files, about 450 KB).
2. In the review chat send: Convert all preview to english.
3. Wait for the two attempts of prototype:revise to finish.

## Expected

Every file that needs the change is revised (in parallel, like the build) and a new version is saved; or, when the model declines, its reason is shown.

## Actual

Error: The answer contained no files, edits or deletes. Both attempts (12:17:05 and 12:17:15 in ai-calls.jsonl) returned 326 and 547 output tokens. A replica of the request on the real Codex CLI returned 2 and 4 edits with a summary saying the conversion was incomplete.

## Environment

MarkView 5.4.0, Codex CLI, model gpt-6.1-terra, output language setting: document language

## Cause

1. A revise is one read-only run whose single answer must carry every change. The request touched 45 of 49 files (about 450 KB), which no
   single answer can hold. With more than 150 KB of files the prompt lists them without contents, so the model reads what it can and returns
   whatever fits: on the real Codex CLI (gpt-6.1-terra, medium) a replica of the request gave 2 and 4 edits and a summary saying the
   conversion was incomplete; the two runs of the report returned nothing (326 and 547 output tokens).
2. The empty answer was reported as an error and the model's `summary` was thrown away, so the reason never reached the screen. The second
   attempt was told its edits did not match the files, which is wrong for an answer that had no edits; Retry repeated the same request.

The Russian text itself is not part of this bug: the output language setting was "document language", so no prompt told the model which
language to write, and the original build chose Russian although `apps/strikedesk` has no Cyrillic. That is a separate prompt question.

## Resolution

- The revise answer has a new `remaining` list. For a request that needs more than three files the first run makes no change itself and lists
  the files; each of them is then revised by a read-only run of its own (`concurrency` 4, as the build writes screens). A run owns one file,
  is checked in memory (`PrototypeFiles.applying`, the core of `apply`) and retried once with the reason. One `apply` at the end writes the
  first change and every file change, so a cancelled or failed sweep leaves the site as it was; a file whose run failed twice stays
  unchanged and is named in the reply. If no file could be revised the request fails.
- An answer with no change but with a `summary` is the assistant's reply ("No files were changed."), not an error; no version is saved.
  A truly empty answer is retried with its own text ("Your previous answer was empty").
- The fix rounds after a preview error never fan out.

## Verification

- `tools/tests/prototype-deadline-tests.sh` (new `sweepMode`): five listed files with a repeat, a ghost and an outside path (dropped), one
  file retried after a bad edit, one run that tries to edit another file and delete one (ignored), one that fails, one that needs no change;
  every run failing; an explanation without a change; silence; a fix round; cancellation mid-sweep (site unchanged).
- `tools/tests/prototype-tests.sh`: `applying`, `sweepTargets`, the file prompt, the empty-answer retry text; the pinned `reviseSystem` digest
  was updated on purpose.
- Real Codex CLI, request replica on the 49-file prototype: the new first run changed nothing and listed exactly the 45 files that contain
  Cyrillic. Two file runs: `screens/settings.js` rewritten whole (841 → 0 Cyrillic characters), `data.js` 15 edits, every `find` unique
  (2222 → 0).
- Real `claude` CLI through the real `PrototypeAI.revise` on a six-file Russian prototype: four files listed, revised three at a time, written
  once; the status value that `data.js` sets and `orders.js` compares stayed consistent.
- Debug `xcodebuild`: build succeeded, app version 5.5.0.
- Not verified: the full 45-file sweep on the strikedesk prototype (about 45 runs); the first one is Boris's.
