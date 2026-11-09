---
type: bug
id: BUG-100
title: "UI Studio: a protocol MarkView cannot serve is logged but no check proves it is named in the turn (REQ-015 criterion 6)"
status: done
branch: fix/ui-studio-bug-batch
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
updated: 2026-11-05
---

# UI Studio: a protocol MarkView cannot serve is logged but no check proves it is named in the turn (REQ-015 criterion 6)

## Summary

REQ-015 criterion 6 says an unknown channel message is prepared like an unknown request, and a protocol MarkView truly cannot serve "is named in the turn and the log, never silently dropped". What exists: an unknown WebSocket or GraphQL operation is prepared (checks pass); a request the assistant marks `unsupported` is logged (outcome `unsupported`, status 501), recorded as an unsupported dependency in the Environment panel and answered with "MarkView UI Studio does not simulate …"; a context change reports `Not done: …`. What is missing is evidence for the "turn" half: a page-initiated WebSocket, stream or binary protocol that the preparation marks unsupported produces no assistant turn, and no session check opens such a connection and asserts the log line and the answer. Either add the check and, if needed, a note in the conversation, or narrow the criterion to the log and the Environment panel.

## Steps to reproduce

1. Open UI Studio on a page that opens a WebSocket (or stream) speaking a binary protocol MarkView cannot serve, for example a custom framed protocol.
2. Let the preparation run and mark the channel `unsupported`.
3. Read the session log, the Environment panel and the conversation.

## Expected

The log names the connection and the reason, the Environment panel lists it as unsupported, and the conversation tells the person what is not simulated, so it is never silently dropped.

## Actual

Not verified end to end. The log and the Environment panel are fed by the code path (`UIStudioSession.swift` around the `.unsupported` cases), but no check drives it for a channel, and nothing is said in the conversation for a page-initiated case.

## Environment

MarkView 5.35.0, `UIStudioSession.swift` (`.unsupported` handling), `UIStudioPreparation.swift`, `UIStudioChannels.swift`. Feature markview-ui-studio, REQ-015 criterion 6 (left unticked).
