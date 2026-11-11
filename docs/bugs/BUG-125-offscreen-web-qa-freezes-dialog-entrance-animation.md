---
type: bug
id: BUG-125
title: Offscreen web QA freezes dialog entrance animations
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-11
provenance: Created by an AI agent through MarkView
related: end-to-end-qa
updated: 2026-11-11
---

# Offscreen web QA freezes dialog entrance animations

## Summary

QA web players were hosted in ordinary offscreen NSWindows. WebKit marked those documents hidden and held CSS entrance animations at currentTime 0, leaving animated dialogs transparent while their backdrops rendered. Reporting visible occlusion from the QA-only QAWebWindow while ordered in keeps rendering active without moving or activating the host. Normal browser and ordered-out windows retain their usual behavior.

Fixed by PR #363 (https://github.com/t-boris/MarkView/pull/363), merged as 28ddbc84d9920084513ffd3d0bde55640a0cbeb1, version 5.67.1. Debug build and QA runner checks pass. Real WKWebView regression checks two players, requestAnimationFrame, dialog pixels, native date input, repeated opening and unchanged focus; the original host reproduces eight failures. A full isolated real-app run using the real QA assistant passed all four calendar steps in 24 seconds, with the calendar visible in stored screenshots and video. Merge CI passed for arm64 and x86_64.

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
