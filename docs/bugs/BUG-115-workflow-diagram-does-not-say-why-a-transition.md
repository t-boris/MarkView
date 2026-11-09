---
type: bug
id: BUG-115
title: Workflow diagram does not say why a transition happens or what triggers it
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
related: BUG-113
updated: 2026-11-09
---

# Workflow diagram does not say why a transition happens or what triggers it

## Summary

The Workflow state diagram (BUG-112, BUG-113) shows where a step goes from and to, and labels an arrow only with its kind (Start, Delivered, Accepted...). It does not show WHY the step happens: what event triggers it, what must hold first (merged to the default branch or a pull request, checks passed automatically, a release published, a person confirmed, a person or an AI with evidence accepted), and who or what makes it (a person, an AI through the project tools, or MarkView itself automatically once the evidence is complete). That data already exists: the actor conditions of each rule (LifecycleRule.needs) and the project's processes (RuleVariant: start, integration, checks, delivery event, acceptance), but it is visible only in tiny menus of the rule inspector and on the Processes page, never in the diagram.

## Steps to reproduce

1. Open Settings > Workflow > Features (or Bugs)
2. Look at the diagram: an arrow from Implementing to Implemented is labelled only 'Delivered'
3. Try to tell from the diagram whether that step needs a merged pull request, passing checks, a release, or a person, and whether MarkView makes it by itself

## Expected

Every arrow says what makes the step happen (its trigger), who may make it (person, AI through the project tools, MarkView automatically), and the evidence it needs. Selecting an arrow shows a When / Who / Evidence card built from the rule and from the project's processes, and the conditions of a process (how the work reaches the branch, checks, delivery event, who accepts, how work starts) can be changed in that same card. First slice shows and edits only what the workflow already stores; the file format (.dde/workflow/workflow.json) does not change.

## Actual

The arrow label is the kind of step only. The conditions are in three small menus of the rule inspector (Person / AI / MarkView) and the process conditions are on another page, so the diagram cannot answer 'why does it move' or 'is it automatic'. Boris on 5.47.0: 'which are the conditions of a transition, where do we see that it must be merged to the default branch, checked visually or automatically... we need events that can happen and lead to something, and they must run automatically; if an AI sees that something is finished and writes through MCP, the status changes'.

## Environment

MarkView 5.47.0 and 5.48.0, Workflow tab (Features, Bugs and Processes pages)

## Resolution

Every arrow of the Workflow diagram is now labelled with the step and who moves it (for example 'Completion · automatic', 'Acceptance · person or AI', 'Reopening · person'), and selecting an arrow opens a When / Who / Evidence card: what makes the step happen, one sentence per actor (a person, an AI through MarkView's project tools, MarkView by itself and on which event) and, for each process that follows the transitions, the evidence it requires, with the controls that change it (how work starts, how it reaches the default branch, checks, delivery event, who accepts). The wording is built from the rule's actor conditions and the processes (Models/WorkflowTransitionStory.swift); workflow.json is unchanged. 'automatic' is claimed only for events MarkView acts on by itself: a hand-off or attached session, complete delivery evidence, a regression report. Merged as PR #335 (5.49.0). Verified: workflow-story-tests.sh, workflow-diagram-tests.sh, issue-lifecycle-tests.sh workflow, workflow-editor-layout-tests.sh with real mouse events and off-screen renders, Debug build. Not hand-checked in the running app. Not done: new event kinds (a visual check as against an automatic one, custom events) change the stored format and wait for a decision.
