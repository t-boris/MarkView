---
type: feature
id: cycle-time-as-a-view-over-the-workflow
title: Cycle time as a view over the workflow
status: done
owner: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView from Review docs/plans/2026-11-09-cycle-time-review.md, direction A approved by Boris on 2026-11-09
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: known
  Dependencies: known
  Acceptance Criteria: known
related: lifecycle-event-log-cycle-time-analytics
---

# Cycle time as a view over the workflow

## Idea

Project Cycle Time becomes a read-only projection of the workflow transition journal (.dde/lifecycle/transitions.jsonl) instead of a second hand-built event log with nine fixed stages. Problem: the fixed-stage observer cannot tell work from a flow migration (the Kanban switch on 2026-11-09 wrote 33 false events, so the implementation median reads 997 h instead of 1.0 h and the immutable log cannot be corrected), review_done and verified were never recorded, bugs are not measured, per-model rows are split over 13 spellings, there is no red/green, no drill-down and no reset. Scope: status layer for features and bugs with metrics by workflow role (lead time, cycle time, waiting, time in each status, rework, acceptance lag), measure-since window, exclude item, recompute; pace/facts/data-quality signals with a Needs attention list; dig-in from a number to the items and to an item timeline; evidence layer (PR, checks, merge, CI) chosen by the process variant; model aliases. Out of scope: cross-project analytics, charts, agent-active time and git history backfill (spikes only). Full review: docs/plans/2026-11-09-cycle-time-review.md. Follows lifecycle-event-log-cycle-time-analytics.

## Problem

## Scope
