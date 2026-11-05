---
type: bug
id: BUG-099
title: "UI Studio: toolbar button, Log button with filters and mapping progress were never checked in the running app (REQ-011 criteria 1-2, REQ-014 criterion 1)"
status: open
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
updated: 2026-11-05
---

# UI Studio: toolbar button, Log button with filters and mapping progress were never checked in the running app (REQ-011 criteria 1-2, REQ-014 criterion 1)

## Summary

Three user-visible controls of UI Studio are covered only by model-state checks and a compiled build, never by clicking them in the running app, so their criteria stay unticked: (1) the UI Studio button in the project window toolbar next to Deployments and Discussions, which opens or focuses the tab and is highlighted while it is active (REQ-011 criterion 1); (2) the Log button with the problem count, the log under the page and its All / Problems / Requests / Server filters, newest first (REQ-011 criterion 2); (3) the visible progress of the first-open API mapping (REQ-014 criterion 1). The log content, the session.log file and the mapping logic are proven by checks; the views are not. This is a verification task that can turn into defects once someone looks.

## Steps to reproduce

1. Install the current build and open a project window.
2. Check the toolbar: the UI Studio button sits next to Deployments and Discussions, opens UI Studio or focuses its tab, and is highlighted while that tab is active.
3. In UI Studio open the Log button: it shows the number of problems, opens the log under the page, and All / Problems / Requests / Server filter the rows, newest first.
4. Open UI Studio on a project that has no saved map and watch the first-open mapping: progress is visible while rules, entities and seed are prepared.
5. Tick the criteria that hold; file a bug for each one that does not.

## Expected

All three controls behave as REQ-011 and REQ-014 describe, with no window popping up on Boris's screen from automated probes (run the check by hand or with a hidden window).

## Actual

Not verified. Only the models behind them are checked (`fixableErrors`, log entries and filters in the pure suite, the mapper's progress state in the session suite).

## Environment

MarkView 5.35.0. Feature markview-ui-studio, REQ-011 criteria 1 and 2, REQ-014 criterion 1 (left unticked).
