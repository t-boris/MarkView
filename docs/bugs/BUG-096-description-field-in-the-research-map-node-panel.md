---
type: bug
id: BUG-096
title: Description field in the research map node panel cannot be resized
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
---

# Description field in the research map node panel cannot be resized

## Summary

The Markdown description field in the properties panel of a research map node shows a resize grip, but dragging it does not change the height of the field.

## Steps to reproduce

1. Open a research map and select any node
2. In the right panel find the Description field (Markdown description)
3. Drag the resize grip in the bottom-right corner of the field up or down

## Expected

The field becomes taller or shorter by the dragged distance; the panel scrolls when the field is taller than the space left.

## Actual

The field keeps its height. Boris, 2026-11-05: "the size of this input box does not change. I want it to change."

## Environment

MarkView 5.32.0, macOS. Suspected cause, to be confirmed by a failing test before the fix: `.rm-desc { flex: 1 1 180px; resize: vertical }` inside the column-flex `.rm-panel` in markview-research-map.js; a non-auto flex-basis wins over the height that the grip sets.
