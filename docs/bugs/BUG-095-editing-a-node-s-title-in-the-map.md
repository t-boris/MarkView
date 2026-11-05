---
type: bug
id: BUG-095
title: Editing a node's title in the map panel removes its number badge and icon
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
---

# Editing a node's title in the map panel removes its number badge and icon

## Summary

While the title of a node is typed in the properties panel of the research map, the page replaced the whole children of the node card with the plain text. The number badge and the icon (REQ-008) disappeared from the card and did not come back until the map was reloaded.

## Steps to reproduce

1. Open a research map and select a node that has a number badge or an icon
2. Type a character into the node name field of the properties panel
3. Look at the node card on the map

## Expected

The card shows the new title and keeps its number badge and its icon.

## Actual

The card shows only the title text. The badge and the icon are gone. The cause is the title field's input handler in markview-research-map.js, which set `btn.textContent`; that wiped the lead (badge and icon) and label spans built in 5.31.0, and later snapshots updated the detached label. Found while adding shape and size to the node card; reproduced by running the new regression check against the page of the installed 5.31.0 app (the button held only "Compiler flags").

## Environment

MarkView 5.31.0, research map, any node with a number or an icon
