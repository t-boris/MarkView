---
type: feature
id: long-running-design-agent-planned-reviewed-tied-to
title: "Long-running design agent: planned, reviewed, tied to a feature"
status: wont-do
owner: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView from Boris, 2026-11-05 (goal message with a screenshot of the design agent)
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: partial
  Permissions: unknown
  Failure Scenarios: partial
  Data Model: unknown
  Notifications: unknown
  Security: unknown
  Analytics: unknown
  Dependencies: unknown
  Acceptance Criteria: partial
---

# Long-running design agent: planned, reviewed, tied to a feature

## Idea

The design agent (UI Studio; possibly also Prototype Studio — to be confirmed) makes only small changes: Boris gives it a button and it changes the button. A big change is not possible, because every request is one read-only model call that returns search/replace edits, with no plan, no steps and no look at the result. Boris needs a long-running agent that runs for a long time, splits a big request into chunks and does them one by one, periodically checks its state, asks questions and reports. Every change is two-level: first a plan, then a review of the plan, then implementation, then a review of the implementation against the requirements. Every time something is about to change, a new feature is opened automatically, and everything Boris says and everything that has to be done is added to it as requirements. Images can be added straight into the dialog in the input box.

## Problem

## Scope
