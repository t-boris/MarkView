---
type: plan
feature: mcp
title: Individual MCP Service Management for Supported Agents
issues:
  - id: I-1
    title: Discover MCP services and track per-agent selections
    summary: Discover MCP services available to each supported agent, including services configured outside MarkView and separately registered markview-control. Represent service identity, configured state, and per-agent selections on the current Mac, preserving newly discovered services in their agent-configured state until the user changes them. Define and verify agent-specific configuration handling with fixtures, including preservation of unrelated settings.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-006]
  - id: I-2
    title: Apply service selections to agent configurations
    summary: Apply individual service selections to each supported agent’s own configuration so that disabled services are unavailable for direct connections in subsequent launches inside and outside MarkView. Restore a previously disabled service when enabled without changing unrelated settings, and verify both launch contexts for MarkView and third-party services, including configured markview-control.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-002, DEC-003, DEC-006]
  - id: I-3
    title: Migrate existing agent-wide tool settings
    summary: "Migrate the existing agent-wide switch for each agent: when it is off, initially disable markview and markview-browser, including registered copies in the agent’s own configuration; when it is on, preserve each service’s existing state. Preserve third-party service states and verify the migrated behavior for subsequent launches inside and outside MarkView."
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-004]
  - id: I-4
    title: Honor service selections during launch and registration
    summary: Make MarkView’s agent launch and Connect Agents registration paths honor each agent’s saved service selections. Supply or register only enabled MarkView services, report skipped services during registration, and verify that registration preserves selections and does not make skipped services available on a later launch.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-003, DEC-005]
  - id: I-5
    title: Add per-agent MCP service controls
    summary: Provide controls for viewing and independently changing each available MCP service for every supported agent. Reflect the agent-specific state, inform the user when an already running session must restart for a change to take effect, and ensure the workflow does not alter or circumvent organizational policy.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-006]
updated: 2026-11-18
schema: 1
---

# Implementation plan — Управление MCP-сервисами агентов

## I-1: Discover MCP services and track per-agent selections

Discover MCP services available to each supported agent, including services configured outside MarkView and separately registered markview-control. Represent service identity, configured state, and per-agent selections on the current Mac, preserving newly discovered services in their agent-configured state until the user changes them. Define and verify agent-specific configuration handling with fixtures, including preservation of unrelated settings.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-002, DEC-003, DEC-006

## I-2: Apply service selections to agent configurations

Apply individual service selections to each supported agent’s own configuration so that disabled services are unavailable for direct connections in subsequent launches inside and outside MarkView. Restore a previously disabled service when enabled without changing unrelated settings, and verify both launch contexts for MarkView and third-party services, including configured markview-control.

Requirements: REQ-001, REQ-002
Decisions: DEC-002, DEC-003, DEC-006

## I-3: Migrate existing agent-wide tool settings

Migrate the existing agent-wide switch for each agent: when it is off, initially disable markview and markview-browser, including registered copies in the agent’s own configuration; when it is on, preserve each service’s existing state. Preserve third-party service states and verify the migrated behavior for subsequent launches inside and outside MarkView.

Requirements: REQ-001, REQ-002
Decisions: DEC-004

## I-4: Honor service selections during launch and registration

Make MarkView’s agent launch and Connect Agents registration paths honor each agent’s saved service selections. Supply or register only enabled MarkView services, report skipped services during registration, and verify that registration preserves selections and does not make skipped services available on a later launch.

Requirements: REQ-001, REQ-002
Decisions: DEC-003, DEC-005

## I-5: Add per-agent MCP service controls

Provide controls for viewing and independently changing each available MCP service for every supported agent. Reflect the agent-specific state, inform the user when an already running session must restart for a change to take effect, and ensure the workflow does not alter or circumvent organizational policy.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-002, DEC-003, DEC-006
