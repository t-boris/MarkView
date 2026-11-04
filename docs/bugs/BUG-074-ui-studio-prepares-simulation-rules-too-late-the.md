---
type: bug
id: BUG-074
title: "UI Studio prepares simulation rules too late: the app's own deadline fails the first request and preparations time out"
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio prepares simulation rules too late: the app's own deadline fails the first request and preparations time out

## Summary

A rule for an unknown request is prepared only when the request arrives. The agent needs 17–30 s on vivaa, but vivaa gives every server call a 5 s deadline, so the page always shows "Exchange rates are unavailable" / "Couldn't load the cities" and the overlay shows `[fx] rates unavailable in client-web-app: "marketplace deadline exceeded"`. In addition the 30 s preparation deadline includes the wait for one of two slots and both attempts, and an answer that arrives after it is thrown away, so on vivaa no rule was ever registered (there is no .markview/studio/environment.json).

## Steps to reproduce

1. Open UI Studio on vivaa apps/client-web-app in 5.18.0 (MarkView starts the server)
2. Wait for the page
3. Look at the Degraded banner, the overlay issue and ~/Library/Application Support/MarkView/ai-calls.jsonl (label ui-studio:prepare)

## Expected

The services the server calls are prepared before the first render, so rates and cities come from the simulation on the first load; a late but valid answer is still kept; the rules are saved for later sessions.

## Actual

"Degraded: 3 requests without a simulation rule". Every ui-studio:prepare call after the install was cancelled (7 of 7, mostly at 30.0 s); under 5.15.x about half hit the limit too. The app reports "marketplace deadline exceeded".

## Environment

MarkView 5.18.0, vivaa apps/client-web-app; vivaa lib/fx/server.ts uses Deadline.of(5_000), platform-bff DEFAULT_DEADLINE_MS = 5_000. MarkView: StudioPreparationLimits.deadline = 30, UIStudioPreparation.run drops answers after the deadline.
