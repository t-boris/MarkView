---
type: bug
id: BUG-125
title: Offscreen web QA freezes dialog entrance animations
status: backlog
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-11
provenance: Created by an AI agent through MarkView
related: end-to-end-qa
---

# Offscreen web QA freezes dialog entrance animations

## Summary

QA web players live in offscreen NSWindows. WebKit marks their documents hidden and suspends CSS entrance animations at currentTime 0. Animated modal dialogs remain transparent while their backdrop is visible, producing misleading screenshots and disrupting interaction.

## Steps to reproduce

1. Run a web QA scenario that opens an animated modal dialog.
2. Use a dialog with a 220 ms opacity/transform entrance animation.
3. Inspect the player's screenshot after at least one second.

## Expected

The QA browser renders and interacts with the completed dialog just like a visible browser, without showing or activating its host window.

## Actual

Only the dark modal backdrop appears. A minimal real WKWebView reproducer reports document.hidden=true and the CSS animation running at currentTime 0 after one second.

## Environment

MarkView 5.67.0; offscreen 1280x800 QAWebActor window; reproduced with a local HTML dialog fixture.
