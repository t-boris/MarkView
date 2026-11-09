---
type: feature
id: assistants-confirm-delivery-with-evidence-and-propose-workflow
title: Assistants confirm delivery with evidence and propose workflow changes through MCP
status: ready
owner: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView from Boris, 2026-11-09, messages about BUG-116 and BUG-117 not closing
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
  Acceptance Criteria: known
---

# Assistants confirm delivery with evidence and propose workflow changes through MCP

## Idea

Boris: an assistant restarted and checked the installed MarkView itself, yet two bugs stayed in review because the delivery event "Installed on mac" can only be confirmed by a person, and no assistant can change the workflow. He wants (1) a delivery event that a person OR an AI with evidence may confirm, as acceptance already allows, and (2) any assistant started in a MarkView window (Claude Code, Codex, Copilot, Cline, Antigravity) to understand the workflow through MCP and, when he asks in words ("change my workflow so that ..."), to propose the change so that he reviews it in the Workflow tab and presses Save. Assistants never write the workflow themselves.

## Problem

## Scope
