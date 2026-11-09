---
type: bug
id: BUG-062
title: "Prototype from code: a screen that loses its content stays blank because the preview fix round declines a request spanning more than three files"
status: done
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

## Cause

- The Trade screen's script put its content into the element its loader sits in and cleared that element inside the `App.load` callback (`draw()` calls `root.replaceChildren(...)`). That takes the loader container out of the page, so the callback's content goes into a detached element: nothing is shown and nothing is thrown.
- The fix round used the revision prompt, which lets the assistant decline into `remaining` when a request needs more than three files, and then called the revision with `sweep: false`, which never follows `remaining`. Five problems in five files were declined as a whole and a defect confined to one file stayed. The toolbar did not show that anything was left.

## Resolution

Fixed in 5.13.1 (pull request #281):

- The fix round names the files each problem points to. More than three files: one run per file (`revise(sweepFiles:)`), each seeing the whole list at medium effort. Three files or fewer: one run as before, and a decline now fans out through `remaining`. A request that cannot fan out is told to leave `remaining` empty.
- `PrototypeAudit.loadProblem` reads a screen's script for a callback of `App.load` that clears the element holding the loader, directly or through functions it calls. It runs when a screen is written (one retry with the reason) and in the fix round over every screen, so an existing prototype is covered. The screen prompt names the calls.
- The header shows a red "N not working" chip with the list and a Fix again button when the fix round leaves problems.

## Verification

Reproduced on the real strikedesk prototype in a headless browser (the OptionDesk root has no children). The new standalone checks pass (`tools/tests/prototype-fixround-tests.sh`, which fails when the lint is disabled; the new cases of `prototype-deadline-tests.sh` and `prototype-tests.sh`), the three pull request checks passed, the Debug build succeeds, and the `Build & Release` run of the merge commit succeeded. Over the 30 real strikedesk screens the new check flags only `trade.js`; over 12 vivaa screens it flags none. The signed DMG of 5.13.1 is notarized and published as release v5.13.1.

Not covered: a live run with a real assistant on the strikedesk prototype (it would write a new version of a prototype in use), and a click-through of the header chip. The existing prototype keeps its blank Trade screen until its owner presses Fix again in 5.13.1 or syncs it.
