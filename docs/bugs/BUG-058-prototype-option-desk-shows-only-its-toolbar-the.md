---
type: bug
id: BUG-058
title: "Prototype option desk shows only its toolbar: the option chain is clipped to zero height and the preview check does not notice"
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Prototype option desk shows only its toolbar: the option chain is clipped to zero height and the preview check does not notice

## Summary

In the StrikeDesk prototype made from code (broker-fabric, apps/strikedesk) the main component, the option desk (OptionDesk.tsx, screen option-desk, the default widget of the trading desk), renders its toolbar but an empty black area where the option chain should be. The chain is not missing: all 111 rows are in the DOM, but every container around the table is 0 px tall and clipped by overflow:hidden. The audit that opens every screen after a build looked only at the DOM (display, visibility, text), so it reported nothing and no repair round ran.

Fix (5.10.0): the preview audit now measures geometry. A box that hides its overflow and is under 8 px high or wide hides what it holds; a screen whose text is mostly hidden this way (at least 150 characters and no less than what it shows) gets the new kind `clipped`, with the collapsed box and the heights up to the first tall ancestor in the message that goes to the repair round. `aria-hidden` and `inert` boxes and boxes that are only short (they scroll) are not reported. The embedded-widget shell contract and the host-screen prompt now ask for a panel with a definite height and a returned element that fills it, so new builds avoid the collapse. Checked on a copy of the real strike-desk prototype: the new audit reports `desk` and `option-desk`; a real Codex repair round fixed `option-desk`, a second round cleared the host `desk` (0 problems). The repair runs once per request, so a host like `desk` can still be reported as 'Still not right after the fix'; the prototype in Boris's folder needs a Sync or rebuild with 5.10.0 to benefit.

## Steps to reproduce

1. Open broker-fabric in MarkView 5.8.0, open the prototype strike-desk (made with New Prototype from Code, source apps/strikedesk).
2. Open the screen option-desk (labelled "Торговля опционами"), or look at the first screen, the trading desk, which shows it by default.
3. Below the toolbar (SPX price, Table/Analysis, Strategy, Apply, Configure, Strikes, Refresh) the area is empty.

## Expected

The option chain table (calls | strike | puts per expiry) is visible and scrolls inside the widget. If a built screen has its content cut off, the post-build audit reports it and the repair round fixes it.

## Actual

Measured in a headless browser: the table is 3762 px tall, its parent div (overflow:auto, max-height 55vh) is 0 px, .sd-option-desk__market-surface, __surface and __layout (all overflow:hidden or flex:1 1 0; min-height:0 in the copied original option-desk.css) are 0 px, and the widget root (inline height:100%) is only 88 px because its parent, the element returned by App.renderScreen, has height:auto. Walking all 20 non-modal screens and counting text inside zero-size overflow containers: option-desk 93% of its text clipped (3897 of 4193 characters), desk 72% (same widget), every other screen 0%. Screen scripts are syntactically fine and nothing throws, so the build reported no problem. Side findings in the same prototype: a stray text "null" at the top of the desk's left strip; the builder named or read 35 of 369 UI files (9%) and did not read components/ChainTable.tsx (82 KB, the real chain), so the table is a hand-made approximation.

## Environment

MarkView 5.8.0, project broker-fabric, prototype strike-desk v5 (docs/prototypes/strike-desk), source apps/strikedesk, rendered in headless Chrome from a copy of site/
