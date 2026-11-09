---
type: bug
id: BUG-035
title: Agent usage indicator and polling disappear in narrow Agents panels
status: done
branch: fix/bug-035-usage-indicator-narrow
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Agent usage indicator and polling disappear in narrow Agents panels

## Summary

`ModuleExplorerView` draws `AgentUsageBar` only when the panel is at least 460 points wide (times the font scale). Below that the compact indicator is gone, and because the bar's `onDisappear` stops polling, usage is no longer refreshed. REQ-004 of the usage tracker requires a compact indicator for each supported agent, and DEC-017 says it shrinks (full, percent only, minimal) instead of vanishing. Found by a read-only audit.

## Steps to reproduce

1. Open a project with at least one detected agent (Claude Code or Codex).
2. Narrow the Agents panel below about 460 points, or raise the font scale.
3. Look at the panel header.

## Expected

A compact indicator stays visible and shrinks with the width; polling continues.

## Actual

The indicator and the total-cost label are hidden completely and polling stops until the panel is widened again.

## Environment

MarkView current main (ade7910), MarkView/Views/ModuleExplorerView.swift lines 12-20; code reading only.

## Cause

The width gate in the Agents panel header covered the usage bar, not only the labels that can be dropped.

- `ModuleExplorerView` computed `showStats = width >= 460 * max(1, fontScale)` and put `AgentUsageBar()`, the total-cost
  label and the indexing progress inside `if showStats` (added in e9d35c9, "Keep terminal controls readable in narrow
  windows"). Below the threshold the bar was removed from the view tree.
- `AgentUsageBar` calls `tracker.indicatorAppeared()` in `onAppear` and `indicatorDisappeared()` in `onDisappear`. When
  the bar left the tree the visible count fell to 0 and `AgentUsageTracker.updateRunning()` stopped the timer and the log
  watcher; they started again only when the panel was widened.
- DEC-017's shrink levels already existed: `AgentUsageChip` wraps its content in `ViewThatFits` with a full, a
  percent-only and a minimal variant (since 2.14.0). Behind the gate they could not act below 460 points, and
  the threshold grows with the text size (920 points at 200%). The pane itself may be as narrow as 300 points
  (`terminalMinimum` in `ContentView`), so the gate was in the ordinary range, not a corner case.

## Resolution

`AgentUsageBar` is always in the header; only the labels that can be dropped keep the width gate.

- `ModuleExplorerView`: `AgentUsageBar()` moved out of `if showStats`. The gate (same threshold, 460 points times the
  text scale) now covers only the total-cost label and the indexing progress, as before. A comment states why the bar
  must not be gated.
- `AgentUsageViews.swift`: a doc comment on `AgentUsageBar` records that its appearance drives the polling (DEC-010) and
  that each chip shrinks on its own (DEC-017).
- The chips are unchanged. `ViewThatFits` picks the largest variant that fits the room the header gives the chip, so the
  level follows the available width and the text size without any width constants of its own.

## Not changed

- The look at wide widths: same chips, same cost label, same threshold for the cost label and the indexing progress.
- The tracker and its polling rules. Polling still stops while the Agents tab is not the selected one or the app is
  inactive (DEC-010, DEC-017 consequences); it no longer stops because the panel is narrow.
- Levels are chosen per chip, as DEC-017 words it ("each chip shrinks"). At some widths one chip can still show its reset
  time while the other shows only the percent (seen at 360 points with two agents), and the minimal level shortens the
  name to two letters ("Cl", "Co"). Making all chips use one level would be a separate design decision.
- No width-to-level function and no standalone test were added: the level is chosen by SwiftUI from the measured
  content, so there is no Foundation-only rule to check.
- Below the pane's own minimum (300 points) the last chip is clipped at the edge. That width cannot be reached in the
  app; it was only looked at in the harness below.

## Verification

- `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug CODE_SIGNING_ALLOWED=NO build`
  succeeds.
- `bash tools/tests/agent-usage-tests.sh` passes (83 checks). This change adds no checks to it.
- A throwaway layout harness, kept outside the repository: it compiles the real `ModuleExplorerView.swift`,
  `AgentUsageViews.swift`, `AgentUsage.swift`, `AppFontScale.swift` and `MatrixTheme.swift` against stub
  `AgentUsageTracker` (it counts `indicatorAppeared`/`indicatorDisappeared` instead of polling), `WorkspaceManager` and
  `AITerminalPanel`, hosts the header in an offscreen `NSHostingView` and renders it at set widths and text scales
  (dark appearance only).
  - Before the change (`HEAD`), at text scale 100%: no chip below 460 points (looked at 440 and narrower), and a width
    change from 500 to 459 gave one `indicatorDisappeared` call, so the visible count went to 0.
  - After the change: chips at every width tried, from 800 down to 300 points at text scales 100%, 150% and 200% and
    for four data states (official windows, no limit plus estimate, unavailable plus loading, one agent), going from the
    full variant through percent only to minimal. Resizing 800, 500, 459, 400, 300, 200, 700, 300, 800 keeps
    the visible count at 1 with no `indicatorDisappeared` call, with agents detected and with none.
  - The rows at 520 and 460 points (cost label shown) are pixel-identical to the render before the change. The 800-point
    row, which also shows the indexing spinner, looks the same by eye; the spinner is animated, so it was not compared
    pixel by pixel.
- Not exercised: the real app window with the real tracker, real agent data and the real split view (dragging the panel,
  switching tabs); that polling actually continues, which was read from `AgentUsageTracker.updateRunning()` and not run;
  the light appearance; a stale-data clock icon at 200% text on a 300-point pane, which adds a little width that was not
  measured.
