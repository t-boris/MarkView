---
type: bug
id: BUG-032
title: Batch "Fix with AI" can leave bugs stuck in "fixing" when the prompt is not sent
status: open
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
