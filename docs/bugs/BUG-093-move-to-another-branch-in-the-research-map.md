---
type: bug
id: BUG-093
title: "\"Move to another branch\" in the research map is an unlabelled icon with a clumsy dialog"
status: fixing
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
---

# "Move to another branch" in the research map is an unlabelled icon with a clumsy dialog

## Summary

The node actions bar shows only icons; "Move to another branch" opens a dialog with a drop-down list of every node. Boris judged it useless (2026-11-04) and chose to remove it entirely. Dragging a node keeps moving it visually only.

## Steps to reproduce

1. Open a map, click the ▼ on a node, hover the fifth icon.

## Expected

No move-to-branch control; the node menu has labelled actions only.

## Actual

An icon-only button opens a modal with a select of all nodes.

## Environment

MarkView 5.30.0
