---
type: bug
id: BUG-124
title: QA picture viewer collapses to a tiny window when a second picture is opened
status: in-review
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-10
provenance: Created by an AI agent through MarkView
regression_of: end-to-end-qa
---

# QA picture viewer collapses to a tiny window when a second picture is opened

## Summary

Opening a picture of a QA run (a player's page or a screenshot) while the viewer window is already open shrinks the window to about 249x74 points, so the picture is not visible.

## Steps to reproduce

1. Open the End-to-End QA tab of a scenario and open an earlier run (or finish a run).
2. Click a screenshot: the viewer opens at 1280x892.
3. Without closing it, click another screenshot or a player's picture in the MarkView window.

## Expected

The viewer keeps its size and shows the picture that was clicked.

## Actual

The viewer window collapses to about 249x74 (content 249x42), nothing readable. Reproduced in the invisible probe on 5.61.0: frame {1280,892} after the first click, {249,74} after the second.

## Environment

MarkView 5.61.0 (REQ-015). Root cause: QAViewer.show replaces window.contentViewController with a new NSHostingController (sizingOptions = []), and AppKit resizes the window to the new controller's initial view size.
