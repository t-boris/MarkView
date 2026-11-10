---
type: bug
id: BUG-120
title: Welcome screen background is shared by every window
status: in-review
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-10
provenance: Created by an AI agent through MarkView
related: welcome-screen-with-action-tiles-and-a-falling
---

# Welcome screen background is shared by every window

## Summary

The background chosen on the welcome screen ("No file is open") changes in all open windows at once. Each window should keep its own choice.

## Steps to reproduce

1. Open two MarkView windows, both showing the welcome screen (no file open).
2. In one window choose another background with the pill in the top right corner (for example Aurora).
3. Look at the other window.

## Expected

Only the window where the background was chosen changes. A new window starts with the last choice, and each window restores its own choice after a relaunch, like the other per-window panel states.

## Actual

The other window changes its background too, because the choice is stored in one shared setting that every welcome screen observes (@AppStorage "welcomeBackdrop").

## Environment

Unknown
