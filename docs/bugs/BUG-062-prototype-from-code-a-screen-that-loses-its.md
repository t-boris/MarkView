---
type: bug
id: BUG-062
title: "Prototype from code: a screen that loses its content stays blank because the preview fix round declines a request spanning more than three files"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype from code: a screen that loses its content stays blank because the preview fix round declines a request spanning more than three files

## Summary

A prototype from code (broker-fabric StrikeDesk, MarkView 5.12.1) is built with blank and broken screens, the preview check names them, and the fix round changes nothing, so the reviewer is left with a prototype that does not work. Two causes stack up. (1) The assistant wrote `screens/trade.js` so that `draw()` calls `root.replaceChildren(...)` inside the `App.load` callback; that removes the loading wrapper from `root`, the content ends up in a detached element and the Trade screen (and the OptionDesk component page) is empty. (2) The fix round after the preview check (`PrototypeSession.settleAndFix`) calls `PrototypeAI.revise(... sweep: false)` with all reported problems at once; `reviseSystem` still tells the assistant to make no change and list the files in `remaining` when a request needs more than three files, and with `sweep: false` that list is ignored, so `written` is empty and the round ends with "No files were changed". Nothing is fixed and nothing in the toolbar says that the prototype is still broken.

## Steps to reproduce

1. Open the broker-fabric project and build a prototype from code of the StrikeDesk app (MarkView 5.12.1), or open the existing docs/prototypes/strikedesk (v4).
2. Wait for the build to finish; the studio chat shows "The preview reported 5 problems; fixing:" followed by TypeError (app.js:93), ResizeObserver, the workspace still loading, Trade rendering nothing and the SPX Chart placeholder.
3. The next chat message is "The reported issues require changes in more than three files, so no changes have been made ... No files were changed."
4. Open Components, choose OptionDesk.tsx and View alone: only the source-component line and an empty box are shown.
5. Reproduction outside the studio: load docs/prototypes/strikedesk/site/components/...-meic-optiondesk-tsx.html in a browser; after three seconds `.sd-widget.sd-option-desk` has no children.

## Expected

The fix round repairs what it can: a defect confined to one file (the Trade screen) is repaired in its own run even when other reported problems need other files, and whatever stays broken is named in the toolbar, not only in a chat message. The prototype checks and the prompts also keep the model from calling `replaceChildren` on the element that `App.load` is filling.

## Actual

The prototype is left with a blank Trade screen and a blank OptionDesk component. The fix round declines, writes nothing and returns; the toolbar still shows an edited, ready prototype with 41 components. Eight screens combine `App.load` with `replaceChildren`; only `trade.js` has the defect (the others return `root` from the callback).

## Environment

MarkView 5.12.1 (installed); source checked on main 2b55a9d (5.13.0): Models/PrototypeSession.swift settleAndFix (`sweep: false`), Models/PrototypeAI.swift reviseSystem and revise (`targets = sweep ? ... : []`). Project: broker-fabric, docs/prototypes/strikedesk. Related: BUG-060 (the \"Not covered\" note on a declining repair round), BUG-053.
