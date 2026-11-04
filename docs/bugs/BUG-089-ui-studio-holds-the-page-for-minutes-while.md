---
type: bug
id: BUG-089
title: UI Studio holds the page for minutes while the assistant prepares one unknown request
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio holds the page for minutes while the assistant prepares one unknown request

## Summary

In vivaa-platform the page waits on requests with no simulation rule while the assistant prepares them: /api/admin/me/locale took 23.7 s, work/team-load 60.2 s, dialogs/inbox 49.6 s, and work/queue was cancelled after 37.2 s (a scenario switch discards the attempt) and then timed out after 90.1 s ("The agent did not finish within 90 s"). Mapping the application's API gave up after 420 s, and 269 rules still miss work/queue and auth/sign-out.

## Steps to reproduce

1. Open UI Studio for an application with many endpoints that have no rule yet.
2. Load a page that makes several of them.
3. Switch the scenario while one is being prepared.

## Expected

The page renders with usable data at once; a request that has no rule yet gets a quick safe default while the rule is prepared in the background, and an attempt is not lost when the scenario changes.

## Actual

The request stays pending ("preparing") for up to 90 s per attempt with two slots, so a page of several unknown requests shows nothing for minutes. A scenario switch cancels the attempt and the next load starts again from zero. The log shows "Degraded: 1 request without a simulation rule" and a timeout instead of data.

## Environment

MarkView 5.27.0, vivaa-platform admin-panel, deadline 90 s, aheadDeadline 240 s, maxConcurrent 2 (UIStudioPreparation.swift).
