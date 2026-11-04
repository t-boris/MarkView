---
type: bug
id: BUG-077
title: UI Studio's preparation ahead of a page is cut at 95 s by the agent CLI's fixed timeout, and retried
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio's preparation ahead of a page is cut at 95 s by the agent CLI's fixed timeout, and retried

## Summary

5.20.0 gave a page's preparation ahead 240 s per attempt, but StudioCLIPreparer still set the CLI timeout to the default 90 s deadline + 5. On vivaa the preparation failed at 95 s ("Codex did not finish within 95 s"). Because that is a failure rather than a timeout, the queue retried it once, so the preview stayed black for 190 s and the page then loaded without the bundles' rule.

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app with no prepared route
2. Read .dde/studio/session.log

## Expected

The preparation ahead runs up to 240 s. A timeout ends it once, and the page loads.

## Actual

`Page /: server requests: failed after 190.2 s — Codex did not finish within 95 s.`

## Environment

MarkView 5.20.0, Codex gpt-6.1-sol (low), vivaa home page
