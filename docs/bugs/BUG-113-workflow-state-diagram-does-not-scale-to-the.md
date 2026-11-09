---
type: bug
id: BUG-113
title: Workflow state diagram does not scale to the window and its transitions are hard to see
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
related: BUG-112
---

# Workflow state diagram does not scale to the window and its transitions are hard to see

## Summary

In MarkView 5.47.0 the Workflow tab draws the transitions as a state diagram (BUG-112), but the diagram keeps a small fixed size: in a window about 1000 pt wide it takes about 860 pt and leaves the right side and the whole page below it empty, while the arrows, their names and the arrowheads are thin and tiny and run over each other, so the transitions cannot be followed. Original report (Russian-English, dictated, with a screenshot of the Features page): "not scale... hard to see transactions".

## Steps to reproduce

1. Open a project and open the Workflow tab in a large window.
2. Choose Features.
3. Look at the diagram under States and transitions.

## Expected

The diagram uses the room the tab has: it grows with the window (width and height), and everything in it grows with it. Each transition can be followed: arrows and their names are large enough to read, parallel arrows are apart, and the arrows of a state or a step light up when the pointer is over them.

## Actual

The diagram is drawn at one size (states at most 150 pt wide, lines 1.4 pt, names 9 pt) with the specification stages 10 pt apart; the arrows between the lanes lie on top of each other and cannot be told apart. Only a click lights a transition.

## Environment

MarkView 5.47.0 on macOS, Workflow tab (WorkflowTransitionsEditor), dark theme, tab about 1000 pt wide.
