---
type: bug
id: BUG-138
title: A closed window's workspace stays in memory for as long as the app runs
status: in-progress
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: BUG-134
schema: 1
updated: 2026-11-27
---

# A closed window's workspace stays in memory for as long as the app runs

## Summary

After a window closes, its NSWindow and WorkspaceManager are not freed. On 2026-11-27 the two windows Boris had closed (3d-model-studio and astroweb, in 7.21.0) were still known to the window server (off screen), and each still held an open file handle on its project root. Earlier, hosted tests kept about 180 closed test windows alive. Every closed window keeps its tabs, its browser web views, its project database (`.dde/state.db`) and its files in memory until the app quits. Found while investigating BUG-134.

Step 1 (PR #476, 7.21.7, merged 2026-11-27) removed three holders found by reading the code and a hosted test: `FeatureFlowCoordinator` held the window strongly (`tabs`), a loop through the window that `close()` never broke; the Settings window kept the last workspace it showed after it closed; the window-opening action kept by `WindowSessionController` captured the last attached `ContentView`. A hosted test (`testAClosedWindowsWorkspaceIsFreed`) proves the workspace is freed once those are gone. A restore that never ends (BUG-139) is a fourth holder.

Still open: in the real Debug app (app probe, `heap` and `leaks --traceTree` on the running probe app) SwiftUI's own structures still keep the closed window and its WorkspaceManager: `focusedValues` property lists of hosted views (a menu pop-up and the split view), `AppWindowsController.windowFocusedValues`, a captured closure context holding a copy of the view, and `PlatformItemList` menu items. A build of main shows the same count (2 windows, 2 WorkspaceManagers after closing one of two), and `.dde/state.db` with its -wal and -shm and the project root stay open. Boris chose to release step 1 first and keep investigating.

## Steps to reproduce

1. Open a project window, open a few files and a browser tab
2. Close the window
3. Inspect the app's memory graph (Xcode Debug Memory Graph or `leaks`): its WorkspaceManager is still alive

## Expected

A closed window's WorkspaceManager, tabs and web views are freed soon after it closes.

## Actual

They stay alive until the app quits.

## Environment

macOS 27.2, MarkView 7.21.0, 2026-11-27
