---
type: bug
id: BUG-093
title: "\"Move to another branch\" in the research map is an unlabelled icon with a clumsy dialog"
status: fixed
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
updated: 2026-11-05
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

## Cause

- "Move to another branch" was an icon-only button behind the ▼ that opened a `<select>` dialog; dragging only moves a node visually. Boris found the control useless and chose to remove the capability entirely (DEC-010; it supersedes the "move" half of Q-003).

## Verification

`research-map-web-tests.sh`: there is no Move action in the node menu or anywhere on the page; the menu holds labelled items only. `research-map-document-tests.sh`: `reparent` is gone from the model. The `reparent` bridge action no longer exists in `WorkspaceManager`.

## Resolution

Fixed in 5.31.0 (release v5.31.0, commit 42268dc) by removing the capability, as Boris decided: no Move to another branch in the node menu, the page or the bridge; `reparent` is gone from the model. The node menu now has labelled items: the four AI actions, add, connect, edit, icon, number children, arrange, delete.
