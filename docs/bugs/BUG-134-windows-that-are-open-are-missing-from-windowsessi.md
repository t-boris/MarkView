---
type: bug
id: BUG-134
title: Windows that are open are missing from windowSessions.json, so a restart loses them
status: backlog
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
---

# Windows that are open are missing from windowSessions.json, so a restart loses them

## Summary

Some open MarkView windows never enter the saved window archive (`~/Library/Application Support/MarkView/windowSessions.json`). When the app quits and relaunches (a reinstall), those windows do not come back. It happened twice: after the 7.4.0 reinstall 4 of 9 windows were missing, and on 2026-11-27 (7.7.1 → 7.21.0) 2 of 5 (3d-model-studio and astroweb). The archive copied right before the quit (last written 11:46:14) held 3 windows, while `markview_windows` listed 5 at about 11:49. 7.7.1 wrote no window-session log line. `WindowSessionController` is unchanged between 7.7.1 and 7.21.0, so 7.21.0 is expected to behave the same. Not known yet: how the two windows were opened (agent `markview_open_project`, Finder, or the menu) and whether the quit-time save (`saveBeforeTermination`) ran.

## Steps to reproduce

1. Have several project windows open in MarkView, some of them opened during the session
2. Compare `markview_windows` with the `windows` list in windowSessions.json
3. Quit MarkView normally (AppleScript quit) and relaunch it

## Expected

Every open window is in windowSessions.json within a second of opening or changing, the quit-time save records all of them, and all of them come back after the relaunch.

## Actual

windowSessions.json held 3 of 5 open windows before the quit; after the relaunch only those 3 came back. The other two had to be reopened by hand, and their agent terminals (Codex, Antigravity and Claude Code in astroweb) were not restored.

## Environment

macOS 27.2, MarkView 7.7.1 quit and replaced by 7.21.0 (detached install, `osascript quit`, swap by rename, `open -a`), 2026-11-27 11:50
