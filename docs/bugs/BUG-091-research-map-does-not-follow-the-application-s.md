---
type: bug
id: BUG-091
title: Research map does not follow the application's design
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
---

# Research map does not follow the application's design

## Summary

The research map page uses its own purple/navy/green palette copied from prototype v10 (--rm-* hex values, glowing nodes, 3D root shadow) instead of the application's design tokens (--bg-*, --text-*, --border-color, --accent-*). It looks like a different product next to the editor, the canvas viewer and the other views. The properties panel title is a one-line input that cuts a long title.

## Steps to reproduce

1. Start New Research so a map tab opens.
2. Compare the map's toolbar, nodes and properties panel with the editor tabs, status bar and another overlay view (canvas, data).

## Expected

The map uses the same surfaces, borders, accent, buttons and typography as the rest of MarkView, in the dark and the light theme; a long node title is fully readable in the panel.

## Actual

The map has its own dark purple page, purple root node with glow, green tool buttons and rounded 15-20px nodes; the panel title shows "Мне нужно сделать deep re" and cuts the rest.

## Environment

MarkView 5.30.0, dark theme, macOS
