---
type: bug
id: BUG-134
title: A closed window stays listed by markview_windows, so it looks open but is not saved
status: in-review
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
updated: 2026-11-27
schema: 1
---

# A closed window stays listed by markview_windows, so it looks open but is not saved

## Summary

A window that is closed stays in the agent window registry (`AgentToolServer`), so `markview_windows` keeps listing it and `markview_open_project` answers "already open" for its folder. The saved window archive (`windowSessions.json`) is right to leave it out. On 2026-11-27 the 2 windows that were "missing" from the archive, 3d-model-studio and astroweb, had been closed by Boris (he confirmed it). The window server showed them off screen, `markview_flow_status` said "has no project open", and their file watchers were gone, which is what `WindowComposition.close()` does. `BrowserHost.register()` adds the window to the registry. Nothing removes it on close: the registry drops a window only when its `WorkspaceManager` is freed, and a closed window's manager stays in memory. The earlier report (5 open vs 3 saved, and 4 of 9 after the 7.4.0 reinstall) counted closed windows as open.

## Steps to reproduce

1. Open two project windows
2. Close one of them (red button or Cmd-W)
3. Call `markview_windows`: it still lists the closed window, last
4. Call `markview_open_project` with the closed window's folder: it answers "already open in window …" and opens nothing

## Expected

A closed window leaves `markview_windows` at once, and `markview_open_project` opens its folder again in a new window.

## Actual

The closed window stays listed with its folder for as long as the app runs, and an agent cannot reopen its project.

## Environment

macOS 27.2, MarkView 7.7.1 and 7.21.0, 2026-11-27. Not covered by this report, and filed on their own: closed windows' WorkspaceManagers stay in memory, and closing a window leaves its agent terminals running.
