---
type: bug
id: BUG-139
title: Restoring a window never finishes when the window closes while its folder is still loading
status: done
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: BUG-138
schema: 1
---

# Restoring a window never finishes when the window closes while its folder is still loading

## Summary

At launch, `WindowSessionSnapshotter` restores a window's folder and waits for `openFolder`'s completion (`WindowSessionSnapshotter.swift:84-86`). The folder setup task returns early without calling the completion when it is cancelled (`WorkspaceManager.swift:151`, `:159`, `:163`), and closing the window, or opening another folder in it during the restore, cancels it. `WindowSessionController.attach` then waits forever (`:163`), and the waiting task keeps the window, its workspace and its session entry alive, so the window is also never freed (BUG-138) and its saved state is never brought up to date. Side note: `openFolder` cancels the window's task bag, which holds the "attach-session" task that runs it. Found while investigating BUG-138 (a probe in a scratch build showed the restore never finishes).

## Steps to reproduce

1. Quit MarkView with a window that has a large project folder open
2. Launch MarkView and close that window (or open another folder in it) before its folder finishes loading
3. The window's restore never finishes; its workspace stays in memory

## Expected

A restore whose folder setup is cancelled ends at once and lets the window go.

## Actual

The restore waits forever and keeps the closed window's workspace alive.

## Environment

macOS 27.2, MarkView 7.21.x (found by reading the code and a hosted probe), 2026-11-27
