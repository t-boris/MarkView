---
type: bug
id: BUG-086
title: UI Studio Select fails with "Script error." as soon as the pointer moves over the page
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio Select fails with "Script error." as soon as the pointer moves over the page

## Summary

Turning on Select in UI Studio and moving the pointer over the page makes the application show webpack's "Uncaught runtime errors: Script error." overlay, which covers the page, so nothing can be selected. Cause: markview-ui-studio.js declares both `var place` (the scenario's browser location, REQ-008) and `function place(div, el)` (draws the hover and selection boxes) in the same scope. The assignment `var place = ... : null` runs at start and replaces the function, so the first redraw after the overlay exists throws `TypeError: place is not a function` inside a script without an address; WebKit hides its message.

## Steps to reproduce

1. Open a project in UI Studio whose page loads (strikedesk on localhost:3010 reproduces it).
2. Choose Select.
3. Move the pointer over the page, without clicking.

## Expected

The hovered element gets a highlight box; a click selects it; no error is reported.

## Actual

The page reports "Script error." (twice per move) and the build error overlay of the dev server covers the page. Studio shows "Degraded: Build error". Select cannot be used.

## Environment

MarkView 5.26.1, regression since 5dcedc0 (REQ-008). Reproduced in a WKWebView against the real page; the instrumented runtime shows `TypeError: place is not a function. (In 'place(hoverBox, ...)', 'place' is null)`.
