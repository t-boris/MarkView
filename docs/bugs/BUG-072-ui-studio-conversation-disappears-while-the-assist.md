---
type: bug
id: BUG-072
title: UI Studio conversation disappears while the assistant thinks
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
ready_to_fix: true
updated: 2026-11-04
---

# UI Studio conversation disappears while the assistant thinks

## Summary

The Element panel shows only the last operation and the text field empties when a question is sent, so the question is not visible anywhere while the assistant works, and earlier questions and answers are not shown. Each question is also sent without the earlier turns, so there is no dialog.

## Steps to reproduce

1. Open UI Studio, select an element and ask a question.
2. While the assistant works, look at the Element panel; then ask a follow-up question.

## Expected

The conversation stays visible as a thread, with the pending question and the assistant's progress; follow-up questions know the earlier turns.

## Actual

The question disappears until the answer arrives; afterwards only the last operation is shown, and the follow-up question is answered without the earlier turns.

## Environment

MarkView 5.15.2 (UIStudioView elementPanel shows session.history.last; StudioPrompts.questionPrompt has no conversation).
