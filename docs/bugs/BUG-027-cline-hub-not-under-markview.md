---
type: bug
id: BUG-027
title: Cline's background hub is not under MarkView, so its browser tools find no window
status: fixed
branch: fix/bug-027-cline-hub-browser-tools
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-05
provenance: Reported in a Claude Code session
---

# Cline's background hub is not under MarkView, so its browser tools find no window

## Summary

Boris (work computer, 4.8.1): Cline ran `MarkView --mcp-browser --diagnose` itself and reported "MarkView not found
among the parent processes, the parent is .cline".

## Root cause

`--mcp-browser` without arguments found the app and the window only through its parent processes (MarkView ←
shell ← agent ← server). On that computer Cline runs its commands and MCP servers in its background hub
(`.cline --cline-hub-daemon`, a child of launchd), so no MarkView is above them. (On this Mac Cline 3.0.65 and
3.0.68 spawned them from the terminal process, which is why BUG-026's checks passed.)

## Resolution

- Without a MarkView among the parents, the server uses the running MarkView processes (their control sockets),
  trying each until one has the agent's folder open.
- Each request carries the agent's working folder; the app picks the window whose project holds it (the deepest),
  else its only window; otherwise it lists the open project windows. Windows register when a folder opens.
- `--diagnose` shows the working folder and whether MarkView was found among the parents or by its socket.

## Verification

Harness: window choice by folder. QA copy with a project open: `--diagnose` from a shell outside its terminals
found it by socket and listed the window's tabs; a real Cline started outside MarkView opened a named tab in that
window and read the page.

## Environment

MarkView 4.8.1, Cline CLI with its background hub.
