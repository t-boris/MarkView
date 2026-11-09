---
type: bug
id: BUG-112
title: Workflow transitions are unreadable without an editable state diagram
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
related: BUG-108
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
