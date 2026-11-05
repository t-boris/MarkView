---
type: bug
id: BUG-094
title: UI Studio comparison of two captures is too small to see anything
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
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
