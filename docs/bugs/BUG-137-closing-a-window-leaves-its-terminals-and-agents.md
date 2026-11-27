---
type: bug
id: BUG-137
title: Closing a window leaves its terminals and agents running out of sight
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: BUG-134
schema: 1
---

# Closing a window leaves its terminals and agents running out of sight

## Summary

When a project window closes, `WindowComposition.close()` stops the project watcher, polls, X-Ray, flow, browser, tools and Git work, but not the window's terminals. Agent sessions (Claude Code, Codex, Antigravity) started in its AI panel keep running with no window to show them, and nothing asks first. The project-operations confirmation in `WindowSessionController.windowShouldClose` covers deploy-style operations only. Seen on 2026-11-27: the closed astroweb window (7.7.1) still had a running Claude Code agent. Found while investigating BUG-134. Whether closing should stop the agents, or ask first like running project operations, is Boris's decision.

## Steps to reproduce

1. Open a project window and start an agent in its AI panel (Claude Code), give it a long task
2. Close the window
3. Look at the processes (ps) or the agent's output files: the agent keeps working

## Expected

Closing a window with running terminals or agents either asks first (keep working / stop and close) or stops them; nothing keeps running unseen.

## Actual

The terminals and agents keep running after the window closes, with no way to see or stop them except quitting the app.

## Environment

macOS 27.2, MarkView 7.7.1 and 7.21.0 (code unchanged), 2026-11-27
