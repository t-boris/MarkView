---
type: bug
id: BUG-025
title: Copilot reports "MCP server was blocked by policy: markview-browser"
status: fixed
branch: fix/bug-025-copilot-mcp-policy
severity: medium
reporter: Boris Tsekinovsky
created: 2026-10-05
provenance: Reported in a Claude Code session
---

# Copilot reports "MCP server was blocked by policy: markview-browser"

## Summary

Boris, on his work computer: "I get error with Copilot - MCP server was blocked by policy:
"markview-browser"".

## Steps to reproduce

1. A GitHub account whose organisation allows Copilot only the MCP servers it lists.
2. MarkView 4.6.0, Copilot as the assistant; open the AI panel.
3. Copilot prints the error at every start.

## Root cause

Since 4.6.0 MarkView starts Copilot from the AI panel with `--additional-mcp-config` for its
`markview-browser` server (Task 82). An organisation policy that lists the allowed MCP servers refuses
it. The policy is the organisation's to set; MarkView must not work around it, only stop adding the
server where it is refused.

## Resolution

- Globe menu → **Browser Tools for Agents**: Claude Code, Codex and Copilot each on or off, per Mac
  (`browser.agentTools.<tool>`); an agent turned off starts without the server.
- A Copilot terminal that prints `blocked by policy` for `markview-browser`
  (`BrowserAgentTools.reportsPolicyBlock`) turns the server off for Copilot on that Mac and offers
  **Restart Copilot Without Them** (continuing its session). Copilot keeps working; the browser tab
  still opens pages and files it opens. Claude Code and Codex are not governed by Copilot's policy.

## Verification

`tools/tests/browser-agent-tools-tests.sh` recognises the message (and not other servers' blocks).
QA copy with a stand-in Copilot printing the message: the dialog appeared, the setting turned off,
and the restart ran `copilot --continue --allow-all` without `--additional-mcp-config`.

## Environment

MarkView 4.6.0, GitHub Copilot CLI on a work account with an MCP policy.
