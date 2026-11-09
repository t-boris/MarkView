---
type: bug
id: BUG-032
title: Batch "Fix with AI" can leave bugs stuck in "fixing" when the prompt is not sent
status: done
branch: fix/bug-032-batch-fix-stuck-fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Batch "Fix with AI" can leave bugs stuck in "fixing" when the prompt is not sent

## Summary

`WorkspaceManager.fixBasketWithAI` marks every selected bug as `fixing` before it sends the prompt, and ignores whether each status write succeeded. If `sendToAssistant` returns nil, or a write fails, the bugs stay in the wrong state and nothing recovers them. Found by a read-only audit of the batch-fix feature against its requirements (REQ-004); not reproduced at runtime.

## Steps to reproduce

1. Add two or more open bugs to the bug basket in the Issues panel.
2. Make the AI terminal unavailable so that sending the prompt fails (for example, no assistant terminal can be opened).
3. Click the batch Fix with AI button.

## Expected

Either every selected bug is `fixing` and the prompt was sent, or the bugs are left as they were and the user sees why nothing started. The basket keeps its contents when nothing was sent.

## Actual

In `fixBasketWithAI` (MarkView/Models/WorkspaceManager.swift) the loop that sets `status: fixing` runs first and its result is not checked. When `sendToAssistant(prompt, submit: true)` then returns nil, the function returns early: the bugs stay `fixing`, the basket is not cleared, and no run exists. A bug whose status write failed is still listed in the prompt as being fixed. The only recovery is the manual status reset.

## Environment

MarkView 4.55.0 and current main (ade7910); code reading only.

## Cause

Confirmed by reading the call path; the failure was not reproduced in the running app.

`fixBasketWithAI` did two things without looking at the result:

- The loop that sets `status: fixing` called `FeatureStore.updateBug` and dropped its `Bool`. `updateBug` returns
  false when a report cannot be read, has YAML the app cannot rewrite safely, or cannot be saved. The prompt was
  then built from the whole eligible list, so a bug whose write failed was handed to the AI as "status is now
  fixing" while its report still said `open`.
- `guard sendToAssistant(...) != nil else { return }` left the loop's marks in place. `sendToAssistant` returns nil
  when no assistant terminal can be opened (`openAITerminal` needs a workspace folder). The bugs then stayed
  `fixing`, and because the basket treats `fixing` as "being fixed" (DEC-008), they were no longer eligible: the
  batch button could not be used for them again. Only a manual status change got them back (DEC-006).

## Resolution

The order stays as it was: bugs are marked `fixing` before the prompt is sent (DEC-006). The AI writes `fixed` or
`open` into each report after that, and a later write by the app would overwrite it. What changed is that the app
now checks each step and undoes its own marks.

- `BatchStart.run` (new, `MarkView/Models/BugBasket.swift`, Foundation only) does the sequence. The status write and
  the send are passed in as closures, so the sequence can be tested without the app:
  1. Each bug is marked. A bug whose write fails is left out of the prompt.
  2. If fewer than `BugBasket.minimumBatch` bugs were marked, nothing is sent and the bugs already marked are put
     back (`tooFewMarked`).
  3. Otherwise the prompt is sent for the marked bugs only. If `sendToAssistant` returns nil, every marked bug is put
     back (`notSent`).
  4. Otherwise the batch started (`started`), possibly without the bugs that were left out.
- A bug is put back to the status its report had, as written (`open` for every bug that could be in the batch). A
  report that had no `status` line gets an explicit `status: open`, which reads the same.
- `BatchStart.notice` gives the text for the user, shown in the basket's existing notice row (`BugBatch.notice`),
  next to the batch button. It names the bugs that were left out. If putting a bug back fails too, the notice names
  it as still `fixing` and says to change its status by hand.
- `fixBasketWithAI` is now a thin wrapper: it passes `FeatureStore.updateBug` and `sendToAssistant` in, clears the
  basket only when the batch started, and shows the notice. When nothing was sent the basket keeps its contents.
- When a batch starts without some bugs, the basket is still cleared (REQ-001: "after a batch starts, the basket is
  cleared"). The notice says which bugs were left out; they are still open and can be added again.
- `tools/tests/bug-basket-tests.sh` did not compile on main: `HandoffPrompt.swift` now refers to `DefinitionOfDone`,
  which the script did not include. `DefinitionOfDone.swift` was added to its compile line.

## Not changed

- The single-bug `fixBugWithAI` marks the report `fixing` and ignores a nil from `sendToAssistant` in the same way.
  This report is about the batch, and DEC-011 keeps the single-bug action as it is, so it was left alone. It may
  deserve its own report.
- A run that starts and is later interrupted still leaves its bugs `fixing`; DEC-006 and DEC-013 keep the manual
  reset for that case.
- `sendToAssistant` returns a terminal as soon as the prompt is queued (`pasteWhenReady`), not when it was
  delivered. A terminal that dies before it is ready is not detected.
- The batch prompt, the basket rules and the order of marking and sending.

## Verification

- `bash tools/tests/bug-basket-tests.sh`: all checks pass, including 20 new ones for starting a batch with a fake
  report store and a fake assistant. They cover: all writes succeed (every bug marked before the single send, all in
  the prompt); one write fails (that bug left out and untouched, the rest sent, the notice names it); too few marked
  (nothing sent, the marked bug restored, notice); no write works; the send fails (every marked bug restored to its
  own status after the send attempt, bugs that were left out untouched); a restore that fails (reported as still
  `fixing`). The same checks were run against the previous behaviour (write results ignored, no restore): 14 of them
  fail.
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: the real app. A real write failure or a failing terminal was not provoked, and the notice
  row was not looked at on screen. `WorkspaceManager.fixBasketWithAI` is covered by the build and by reading the
  call path; the status writes it passes in are the existing `FeatureStore.updateBug`, whose atomic write leaves the
  old file in place when it fails.
