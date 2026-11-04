---
type: bug
id: BUG-075
title: UI Studio's conversation shows every earlier session's turns and cannot be cleared
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio's conversation shows every earlier session's turns and cannot be cleared

## Summary

The element panel's thread lists the whole saved operation history, from every earlier UI Studio session, and has no way to clear it. Boris wants UI Studio to open with an empty conversation and to be able to clear it at any time; earlier changes stay in History, where they can be undone or compared.

## Steps to reproduce

1. Open UI Studio on a project where changes were made in an earlier session
2. Look at the element panel's conversation

## Expected

A new UI Studio session starts with an empty conversation; a Clear button starts a new conversation (the assistant forgets its turns); History keeps every operation with undo.

## Actual

The thread shows every operation ever saved (consent-banner changes from yesterday's session included) and there is no Clear.

## Environment

MarkView 5.18.0; StudioSession.history is shown whole by UIStudioView.thread; only the assistant's memory was scoped to the session (conversationIds).
