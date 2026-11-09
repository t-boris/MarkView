---
type: bug
id: BUG-112
title: Workflow transitions are unreadable without an editable state diagram
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
related: BUG-108
updated: 2026-11-09
---

# Workflow transitions are unreadable without an editable state diagram

## Summary

The Workflow tab lists a project's transitions as rows of menus ("From: exploring, idea, ready… → Draft, Specification, Person: nothing needed, AI: nothing needed, MarkView: nothing needed"). The reporter cannot understand the workflow from those rows and asks for an editable state diagram instead: statuses as states, transitions as arrows, with the states and the arrows changeable. Original report (Russian, dictated): "Совершенно невозможно понять эти transitions без нормальных стейт-диаграмм. Оставьте стейт-диаграмму, которую можно было бы редактировать: переводить состояния, стрелочки менять и все остальное. Transition переведи на стейт-диаграмму."

## Steps to reproduce

1. Open a project and open the Workflow tab (header button or Operations → Workflow…).
2. Choose Features (or Bugs, or a process with transitions of its own).
3. Read the Transitions section.

## Expected

The transitions of a type (and of a process with its own transitions) are drawn as a state diagram: every status is a state, every transition an arrow with its kind, and the diagram is editable: states can be added, renamed, given a role and removed; arrows can be added, redirected, given a kind and the evidence each actor needs, and removed.

## Actual

The transitions are a long list of rows, one per rule, each with a multi-status "From" menu, a target, a kind and three evidence menus. The flow of a status through the workflow cannot be seen.

## Environment

MarkView 5.46.0, Workflow tab (WorkflowTabView).

## Resolution

Fixed in PR #332 (5.47.0, branch fix/bug-112-workflow-state-diagram). The Workflow tab draws the transitions of a type, and of a process with its own, as a state diagram: one column per status role, every status a state, every transition an arrow with its kind (one curve per source into one arrowhead; a lane a rule covers completely is one tail; the specification stages that may be taken in any order are entered from one bar). Click a state to rename it, change its role, remove it and see the arrows into and out of it; click an arrow to change where it starts and ends, its kind and what a person, an AI and MarkView need; drag from one state to another to draw an arrow. The stored workflow.json is unchanged; the list of rows and the statuses list are gone. Checks: tools/tests/workflow-diagram-tests.sh, workflow-editor-layout-tests.sh (real mouse events in the off-screen tab), issue-lifecycle-tests.sh workflow display, Debug build. Not hand-checked in the running app.
