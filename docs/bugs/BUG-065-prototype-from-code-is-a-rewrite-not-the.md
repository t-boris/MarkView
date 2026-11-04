---
type: bug
id: BUG-065
title: "Prototype from code is a rewrite, not the real result: OptionDesk loses its styles, fonts and layout (vertical tabs cut, buttons not stretched, no colours)"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# Prototype from code is a rewrite, not the real result: OptionDesk loses its styles, fonts and layout (vertical tabs cut, buttons not stretched, no colours)

## Summary

The StrikeDesk prototype (MarkView 5.12.1 window, v6, 38 components) shows OptionDesk, the most complex widget, in a primitive form: the vertical tab strip is cut to a stub, the order-ticket buttons are not stretched, there are no colour highlights and the fonts are different. Boris's requirement: a prototype from code must reproduce the real result pixel for pixel (HTML and JavaScript with fixture data is fine, the look is not negotiable). Evidence from the project: (1) the stylesheets that style OptionDesk itself (option-desk.css, order-ticket.css, strategy-builder.css, widget-base.css, order-book.css) are copied into site/original/ but linked from neither index.html nor the OptionDesk component page; index.html also carries 43 links to apps/... paths that do not exist in site/ (only original/apps/... does) next to 25 working original/ links. (2) The real app loads Inter, JetBrains Mono, Fira Code and Source Code Pro from @fontsource packages by JavaScript imports in Shell.tsx; the prototype has no font file and no @font-face for them. (3) The real widget is 2137 lines of TSX with 43 stylesheets (collapsed sidebar tabs use writing-mode: vertical-lr and the height of dockview containers); the prototype component is a 4 KB page rewritten by the assistant in plain JavaScript, so structure, state and layout are approximated. A probe outside MarkView: the real built renderer (apps/strikedesk/app/packages/shell/dist/renderer) opened in headless Chrome with a 15-line stub of window.strikedesk (the single preload bridge) already renders the real chrome: full-height vertical tabs POSITIONS, TRADE, ACTIVITY, CHART, TRADE JOURNAL, MARKET CONDITIONS, STATS DASHBOARD, the real fonts and colours; only the data is missing. It makes 40 distinct bridge calls at startup, 36 of them event subscriptions.

## Steps to reproduce

1. Open the broker-fabric project and its prototype docs/prototypes/strikedesk (v6) in MarkView 5.12.1 or later.
2. Open the Trade screen or the OptionDesk component page.
3. Compare with the real StrikeDesk app (apps/strikedesk, pnpm dev): vertical tabs, order ticket, fonts, colours.

## Expected

The prototype looks exactly like the real application, pixel for pixel, with fixture data in place of live data. Everything the real code uses to look right (all its stylesheets, fonts, layout containers) is present and linked, and the result is checked against the real render rather than against a description.

## Actual

OptionDesk looks unfinished: the vertical tabs are cut to a stub, the buttons are not stretched, the colour highlights are missing, the fonts differ. The prototype is an assistant's re-implementation, and nothing in the build compares it with the real render, so the gap is not detected or reported.

## Environment

MarkView 5.12.1 window (5.13.2 installed afterwards, not yet opened on this prototype); project broker-fabric, docs/prototypes/strikedesk v6, source apps/strikedesk (Electron, React 19, rspack, zustand, dockview, plain CSS, 43 stylesheets). Related: BUG-062, BUG-063, BUG-064.
