---
type: bug
id: BUG-116
title: Workflow diagram is too low for its transitions and the arrow names overlap
status: in-review
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
related: workflow-flows-choose-a-classic-flow-clear-columns
---

# Workflow diagram is too low for its transitions and the arrow names overlap

## Summary

On the Workflow tab, a flow with many transitions (Kanban: ten arrows between two rows of states) is drawn only about 150 px high. Boris: "the flow is far too small; when you add that many transitions the diagram must be taller, so there is more room."

## Steps to reproduce

1. Open the Workflow tab of a project on the Kanban flow (Flow button, Kanban), Features page
2. Look at the diagram: two lanes hold two states each and ten arrows run between them

## Expected

The diagram is as tall as its transitions need: arrows do not run along one another, and the name of every arrow can be read without another name on top of it.

## Actual

The height of the lanes comes from the number of states in the tallest lane only (two states, about 130 px), however many arrows there are. Each arrow's name is drawn at its arrowhead, so the names of arrows that arrive at the same state sit on top of each other and the arrows themselves are squeezed into a few pixels.

## Environment

MarkView 5.50.0, Workflow tab, Kanban flow (also Azure DevOps Agile, Linear, Shape Up)
