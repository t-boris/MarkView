---
type: bug
id: BUG-091
title: Research map does not follow the application's design
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
updated: 2026-11-05
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

## Cause

- The page copied the prototype's palette (`--rm-*` hex values: purple page and root, green tool buttons, glowing nodes) and used none of the application's tokens (`--bg-*`, `--text-*`, `--border-color`, `--accent-*` in `index.html`). Only hidden-WebKit tests with a stubbed bridge looked at the map; nobody looked at it next to the editor.
- The panel title was a one-line `input`, so a long title was cut.
- When the title field was first made to wrap, it was fitted before the panel had its final content: a scrollbar then narrowed it by 17 px and the text wrapped onto a second, clipped line.

## Verification

`research-map-web-tests.sh` (264 checks): computed colours of the root, nodes, canvas and panel equal the application's tokens in the dark and the light theme, the prototype's 3D shadow is gone, branch accents are the application's colours, a long title wraps and is not clipped (the check found the border-box height bug). Hidden-WebKit renders of the real page in both themes were looked at, including Boris's own long Russian title. Not covered: a look inside the running app on Boris's screen.

## Resolution

Fixed in 5.31.0 (release v5.31.0, commit 42268dc, together with BUG-092, BUG-093, BUG-094). The page maps its look onto the application's tokens in both themes, the glow and the 3D root shadow are gone, and the panel title is a textarea that wraps, is fitted last and again on every width change.
