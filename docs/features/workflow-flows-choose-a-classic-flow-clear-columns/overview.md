---
type: feature
id: workflow-flows-choose-a-classic-flow-clear-columns
title: "Workflow flows: choose a classic flow, clear columns, and a visible Done"
status: implemented
owner: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView from Boris, 2026-11-09, after BUG-115
understanding:
  Problem: unknown
  Target Users: unknown
  Primary Workflow: unknown
  Permissions: unknown
  Failure Scenarios: unknown
  Data Model: unknown
  Notifications: unknown
  Security: unknown
  Analytics: unknown
  Dependencies: unknown
  Acceptance Criteria: unknown
related: BUG-115
---

# Workflow flows: choose a classic flow, clear columns, and a visible Done

## Idea

Boris, on the Workflow tab: the lanes make no sense (Draft, Exploring and Review all sit in "Not started", Review looks like the end, Resolving looks like Implementing), the tab shows nothing about pull requests, CI checks or releases, and it is not clear what "done" means in a project. Offer a choice of classic flows (Kanban, Scrum, Linear, GitHub Projects, Azure DevOps Agile, Shape Up, a bug triage) per project, make the columns say what they mean, and show on the diagram where a pull request, CI checks, a release and an acceptance apply, whether each is required in this project, and what Done is, with a warning when the project's Definition of Done and its process disagree. The templates are data in the existing workflow format (workflow.json does not change); new projects start on Kanban, existing projects keep their flow.

## Problem

## Scope
