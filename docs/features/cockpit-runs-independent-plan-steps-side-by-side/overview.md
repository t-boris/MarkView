---
type: feature
id: cockpit-runs-independent-plan-steps-side-by-side
title: Cockpit runs independent plan steps side by side
status: done
owner: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView from Boris's goal of 2026-11-26 and his answer of 2026-11-27 ("Spec first, then build"); code research of Cockpit (workflow.go, CockpitRun, CockpitSession, CockpitAgentAttempt) on 2026-11-27
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: partial
  Data Model: known
  Notifications: partial
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: partial
schema: 1
related: agent-aware-implementation-runs
---

# Cockpit runs independent plan steps side by side

## Idea

A Copilot Cockpit plan is a workflow, but its steps run one at a time even when they do not depend on each other (for example a Claude review and a Codex review of the same change, or analyses of separate areas). Boris's goal of 2026-11-26 asks that every agent call is optimal: when a task uses a workflow, independent parts run in parallel. Parallel work inside one step (delegation to subagents) already exists; this feature runs adjacent independent steps of a plan at the same time. First version: read-only steps of plain plans, in contiguous groups of at most three, chosen by the planner and visible and editable before approval. Out of scope for now: steps that write, QA scenario steps (one QA model and one browser per window), prerequisites and recovery, the delivery steps of managed runs.

## Problem

## Scope
