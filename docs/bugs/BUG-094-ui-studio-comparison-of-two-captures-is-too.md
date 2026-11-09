---
type: bug
id: BUG-094
title: UI Studio comparison of two captures is too small to see anything
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
updated: 2026-11-05
---

# UI Studio comparison of two captures is too small to see anything

## Summary

Compare in the Evidence panel of UI Studio draws the before and after captures (and the difference) inside the narrow side panel, so each image is a thumbnail and the changes cannot be seen. There is no way to open the comparison larger or full screen.

## Steps to reproduce

1. Open a UI Studio tab that has at least two captures.
2. Open the Evidence panel, tick two captures and press Compare.
3. Look at the Before/After images in the panel.

## Expected

The comparison can be opened over the whole UI Studio tab (and in macOS full screen), with large before, after and difference images that can be scrolled and zoomed.

## Actual

The images stay panel-wide (about half of a 300 px column each); no enlarge control exists.

## Environment

MarkView 5.30.0, UIStudioView.swift comparisonView(_:)

## Cause

- The comparison of two captures lived only in the narrow Evidence panel of UI Studio (side by side at about 150 px per picture), with no way to enlarge it.

## Verification

`StudioComparisonView` was rendered offscreen in a hidden window with generated captures: side by side, difference and a 100 % zoom (scrolling). The chat's Compare button and the arrow in the Evidence panel open it (compiled and wired; `ui-studio-session-tests.sh` and the Debug build pass). Not covered: a click-through in the running UI Studio on a real capture pair.

## Resolution

Fixed in 5.31.0 (release v5.31.0, commit 42268dc). `StudioComparisonView` shows the pair at the size of the whole tab: Side by side, Difference, Before, After, zoom from fit to 400 %, Esc to close. The chat's Compare button opens it directly; the Evidence panel has an arrow that opens the same view.
