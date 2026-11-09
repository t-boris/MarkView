---
type: bug
id: BUG-066
title: "Code X-Ray overview is badly arranged: a cross-cutting column runs through External and bands collapse to empty bars"
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
updated: 2026-11-04
---

# Code X-Ray overview is badly arranged: a cross-cutting column runs through External and bands collapse to empty bars

## Summary

In the X-Ray Code overview of vivaa-platform (with a code model), the Infrastructure column (2 components + 14 scripts) runs about 2.5 times the height of the layer stack, straight through the External band. Application, Data & storage and Unclassified are drawn as empty bars and Build & tooling as a full-height empty column, so the whole picture is zoomed out to 25 %. Two causes: (1) CodeArchitecture.modelView hangs every file the code model does not own directly from the root, so each becomes a separate part of its guessed layer (Data: 4 components + 317 migration files), which pushes layers over the 18-part limit and closes them; the draft view keeps folders, the model view does not. (2) layeredBands gives a cross-cutting column one grid column whatever its part count, and places External and sizes the diagram from the stack height alone, ignoring how tall the columns really are.

## Steps to reproduce

1. Open vivaa-platform in MarkView 5.15.0 (it has a code model from the automatic analysis)
2. Open X-Ray and choose the Code view (overview, nothing expanded)

## Expected

Layers are stacked as bands, each showing its components; cross-cutting layers stand as columns no taller than the stack; External sits below everything; the picture fills the window.

## Actual

The Infrastructure column runs down past the External band to 2.5× the stack height, as a list of single script files; Application, Data & storage and Unclassified are empty bars; the diagram is zoomed to 0.25.

## Environment

MarkView 5.15.0, macOS 27, vivaa-platform. Fixed in 5.15.1.

## Fix

Fixed in 5.15.1. (1) `CodeArchitecture.modelView`: a file no component of the code model owns keeps its folders from the Modules view, as the draft already did, so a layer shows its components and a few folder boxes instead of one box per loose file. On vivaa-platform: Data 321 → 7 parts, Application 28 → 8, Infrastructure 16 → 3, Build & tooling 31 → 2; every band opens. (2) `layeredBands`: a cross-cutting column takes as many parts per row (up to 4) as it needs to stay within the stack's height; External is placed below the tallest of the stack and the columns, and the window-fit width uses the real column widths. The band gap now leaves room for a band's two-line title. Checks: `tools/tests/code-architecture-tests.sh` (unowned files keep their folders; a crowded column stays within the stack, External below it). Both fail on 5.15.0.
