---
type: bug
id: BUG-076
title: "UI Studio stays at Starting: the server probe renders the page and needs its whole body in under a second"
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio stays at Starting: the server probe renders the page and needs its whole body in under a second

## Summary

On vivaa, UI Studio shows "Starting `npm run dev`" for minutes while the server already answers, and the server console fills with "marketplace deadline exceeded". The start loop asks `WebAppPreview.firstAnswering`, a GET / that must return the whole body within 0.8–1 s, every half second. A server-rendered page whose data calls go through the simulated gateway cannot finish in that time while its rules are being prepared, so the probe never passes. Each probe also renders the page again, sending more requests that start more rule preparations; they compete with the preparation ahead of the page, which timed out at 90 s with Codex.

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app with no saved rules for the home page
2. Watch the status and the server output

## Expected

UI Studio sees that the server is listening, prepares the page's server requests ahead (with a visible banner), then loads the page once.

## Actual

The status stays at Starting. `GET / 200 in 799ms` repeats every few seconds, each followed by categories, cities and rates fetch failures ("marketplace deadline exceeded"). ai-calls.jsonl shows the preparation ahead of the page cancelled at 90.0 s, and a request-time preparation that succeeded after 49 s (categories and served cities).

## Environment

MarkView 5.19.0; vivaa-platform, Next.js 16 dev server on port 3000; preparation agent Codex gpt-6.1-sol (low). Probe code: WebAppPreview.firstAnswering (session.data, timeoutIntervalForResource 0.8–1 s), called from StudioSession.launch and startServer.
