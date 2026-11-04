---
type: bug
id: BUG-080
title: Simulated records use values the application does not know, and the page crashes (vivaa "draft" bundle status)
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# Simulated records use values the application does not know, and the page crashes (vivaa "draft" bundle status)

## Summary

vivaa's My Bundles page threw `Missing copy key "workspace.list.next.draft" for locale "en"`. The environment's seed gave 6 `customBundle` records `status: "draft"`. The application only knows editable, under_review, approved, in_progress, completed and cancelled (its types and its `workspace.list.next.*` copy keys). The preparation prompt never asked for enumerations to come from the code.

## Steps to reproduce

1. Open UI Studio on vivaa apps/client-web-app
2. Open My Bundles (/bundles/my)

## Expected

Every status the seed uses is one the code handles. The page renders the list.

## Actual

The error boundary shows "something went wrong"; the log has the logged Error with its stack (BUG-079).

## Environment

MarkView 5.23.0; vivaa .markview/studio/environment.json seed customBundle
