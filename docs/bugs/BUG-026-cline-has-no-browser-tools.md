---
type: bug
id: BUG-026
title: Cline says it has no browser control in this session
status: fixed
branch: fix/bug-026-cline-browser-tools
severity: medium
reporter: Boris Tsekinovsky
created: 2026-10-05
provenance: Reported in a Claude Code session
---

# Cline says it has no browser control in this session

## Summary

Boris (work computer): Cline answers that "in this session there is no browser control support", although he
had connected the agents.

## Root cause

Cline has no per-session MCP option, so unlike Claude Code, Codex and Copilot it gets `markview-browser` only
from its own settings, written by "Connect Agents to MarkView's Browser…". That command connected only the agents
it found and left the others out without saying so; a Cline started before it, outside a MarkView terminal, or
not found by MarkView had no tools. Checked against real Cline 3.0.65 and 3.0.68 (interactive and prompt mode):
both start the MCP server from the process in the terminal, so once registered the window is found through the
parent processes.

## Resolution

- A Cline started from the AI panel gets the server in its settings automatically when it is missing
  (`AgentBrowserRegistration.ensureCline`); outside MarkView terminals the server offers no tools.
- "Connect Agents…" lists the agents it could not find ("not found — set its path in Settings").
- `MarkView --mcp-browser --diagnose` in a terminal prints the parent processes, whether a MarkView is among them
  and the window's tabs — one command to tell which link is missing.
- Sockets left by MarkView processes that are gone are removed at launch.

## Environment

MarkView 4.8.0 on the work computer, Cline CLI.
