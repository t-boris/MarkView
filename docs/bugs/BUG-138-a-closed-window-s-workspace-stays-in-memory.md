---
type: bug
id: BUG-138
title: A closed window's workspace stays in memory for as long as the app runs
status: in-review
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

Step 1 (PR #476, 7.21.7, merged 2026-11-27) removed three holders found by reading the code and a hosted test: `FeatureFlowCoordinator` held the window strongly (`tabs`), a loop through the window that `close()` never broke; the Settings window kept the last workspace it showed after it closed; the window-opening action kept by `WindowSessionController` captured the last attached `ContentView`. A hosted test (`testAClosedWindowsWorkspaceIsFreed`) proves the workspace is freed once those are gone. A restore that never ends (BUG-139, PR #477) was a fourth holder.

Step 2 (PR #479, 7.21.9, merged 2026-11-27) removed the last one. `WorkspaceWindow` (`ContentView.swift`) kept its NSWindow in a strong `@State hostWindow`; that state lives in the window's own SwiftUI view graph, so window, graph and the WorkspaceManager the graph owns held one another. The view now keeps a weak reference (`WeakWindowRef`). The SwiftUI structures `leaks --traceTree` listed earlier (focused values, menu items) were parts of that same graph, not separate holders. Evidence, invisible real app (app probe: open a folder, close its window): origin/main 7.21.8 keeps 2 windows, 2 WorkspaceManagers, 2 ProjectContexts and 4 open files of the closed project (`.dde/state.db`, -wal, -shm, folder); 7.21.9 keeps 1, 1, 1 and 0. New hosted test `testAClosedWorkspaceWindowLetsGoOfItsView` shows the real `ContentView` in a window, closes it and checks that the window and its workspace are freed: fails on 7.21.8's view, passes with the fix. Not checked by hand in the installed app.

Seen on the way, not changed: if a window closes before its session `attach` task has started, `attach` still takes the closed window (and can bring it back to the front).

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
