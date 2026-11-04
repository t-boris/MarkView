---
type: bug
id: BUG-088
title: UI Studio signs the application out on every scenario switch
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio signs the application out on every scenario switch

## Summary

Switching the scenario reloads the page after emptying all browser data, so an application behind a sign-in guard (vivaa-platform admin-panel on :3301, Next proxy.ts) redirects /work to /login each time. In the log the sign-in request follows 11 to 26 seconds later (15:41:37 to 15:41:48, 15:46:05 to 15:46:31), the time it takes a person to sign in by hand. Only a cookie the person kept with Keep survives the reload.

## Steps to reproduce

1. Open UI Studio for an application whose server redirects signed-out requests to a sign-in page.
2. Sign in, then switch the scenario (Empty, Populated, a saved one).
3. The page lands on /login?redirect=%2Fwork again.

## Expected

After a scenario switch the application is signed in as the scenario's test user without a manual step, as the mock-up policy (REQ-010) says it should be.

## Actual

The restore empties cookies and storage (UIStudioSession restore path), the server guard redirects to the sign-in page, and the person signs in again by hand after every switch. The log marks each one with "Server redirect ... (a sign-in page)".

## Environment

MarkView 5.27.0, vivaa-platform admin-panel, .dde/studio/session.log of 2026-11-04 15:34 to 15:47.
