---
type: bug
id: BUG-092
title: Research map nodes cannot be collapsed or expanded
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
updated: 2026-11-05
---

# Research map nodes cannot be collapsed or expanded

## Summary

A large AI-made map (up to 60 nodes) always shows every node. There is no fold toggle on a node and no collapse-all or expand-all. The small ▼ on each node opens the actions menu, which reads as a fold toggle and misleads.

## Steps to reproduce

1. Open a research map with several levels.
2. Look for a way to hide the children of a node.

## Expected

A node with children has a fold toggle showing the number of hidden children; the toolbar collapses or expands every branch; the layout closes the gap.

## Actual

No such control exists; the ▼ opens an actions bar.

## Environment

MarkView 5.30.0

## Cause

- The map had no notion of folding anywhere (page, Swift, format). The small ▼ on every node opened the actions menu, which looks like a fold toggle and misled.

## Verification

`research-map-web-tests.sh`: only a node with children has a toggle; folding hides its descendants and the lines and connections into them, shows "+N", keeps the other nodes laid out and sends nothing to Swift; Collapse all / Expand all; folding the branch of the selected node selects the branch; a node created under a folded branch unfolds it. The menu button is an ellipsis.

## Resolution

Fixed in 5.31.0 (release v5.31.0, commit 42268dc). Every node with children has a fold toggle, Collapse all / Expand all sit in the toolbar, the fold state is view state (DEC-010, the map file does not change), and the node menu button is an ellipsis.
