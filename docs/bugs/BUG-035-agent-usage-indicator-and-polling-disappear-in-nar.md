---
type: bug
id: BUG-035
title: Agent usage indicator and polling disappear in narrow Agents panels
status: open
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
