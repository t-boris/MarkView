---
type: bug
id: BUG-071
title: UI Studio recording stops capturing steps
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
updated: 2026-11-04
---

# UI Studio recording stops capturing steps

## Summary

Boris reports that recording in UI Studio does not seem to work. A likely cause in the code: the recording flag lives only in the page, so after a full page load (a non-client link, a form, a full reload) the page stops reporting steps while Studio still shows Record. To be reproduced before the fix.

## Steps to reproduce

1. Open UI Studio on a web app and choose Record.
2. Click, follow a link that loads a new page, click and type again.

## Expected

Every click, typed text and Enter becomes a step until recording stops; the step count is visible while recording.

## Actual

Reported as not working; the cause will be confirmed by reproduction.

## Environment

MarkView 5.15.2; vivaa-platform apps/client-web-app (Next.js 16).
