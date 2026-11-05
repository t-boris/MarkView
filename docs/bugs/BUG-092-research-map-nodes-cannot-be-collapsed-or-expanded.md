---
type: bug
id: BUG-092
title: Research map nodes cannot be collapsed or expanded
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
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
