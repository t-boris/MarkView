---
type: plan
feature: flexible-files-views-and-visible-agent-usage
title: Flexible Files Views and Visible Agent Usage
issues:
  - id: I-1
    title: Add a virtual workspace level for file navigation
    summary: Introduce a virtual workspace level where the project root and linked folders appear as siblings, without changing their filesystem locations. Support entering either location and preserve file creation, selection, opening, context actions, drag and drop, and reveal behavior at applicable destinations.
    requirements: [AC-002, AC-005]
    decisions: []
  - id: I-2
    title: Add Files views and filters
    summary: Provide accessible Icon, List, and Tree view controls with a clearly selected state. Icon and List navigate directories and show the current location; Tree expands and collapses folders. Add name, hidden-item, and category filters consistently across views, including recursive workspace-wide Tree search, ancestor retention, and all files in the All category. Persist view and filter choices and preserve applicable file operations.
    requirements: [AC-001, AC-003, AC-005]
    decisions: [DEC-001, DEC-003]
  - id: I-3
    title: Make file sorting explicit and persistent
    summary: Replace the cycling sort control with explicit, visible choices for Name or Date Modified and ascending or descending order. Keep folders before files, resolve ties by name, and persist sort choices across app restarts.
    requirements: [AC-004, AC-005]
    decisions: []
  - id: I-4
    title: Move agent usage indicators to the workspace top bar
    summary: Move detected, enabled Claude Code and Codex usage indicators to the persistent workspace top bar across workspace views, including when Agents is closed. Keep agent identity, labeled quota, details, limit controls, and polling available; distinguish loading, stale, estimated, and unavailable states, and provide accessible narrow-width behavior without overlap.
    requirements: [AC-006, AC-007]
    decisions: []
  - id: I-5
    title: Move Project Cycle Time access to the workspace top bar
    summary: "Move access to Project Cycle Time from the Features panel to the persistent workspace top bar alongside agent usage. The presentation remains an open product choice: a compact button opening the existing summary or a visible metric with a selected value."
    requirements: []
    decisions: [DEC-002]
  - id: I-6
    title: Evaluate additional agent usage sources
    summary: Evaluate available usage sources for additional agents and add indicators only for agents with reliable quota data. Keep existing Claude Code and Codex support operational if no additional reliable source is available; this work must not delay their relocation.
    requirements: [AC-008]
    decisions: []
updated: 2026-11-08
---

# Implementation plan — Flexible Files Views and Visible Agent Usage

## I-1: Add a virtual workspace level for file navigation

Introduce a virtual workspace level where the project root and linked folders appear as siblings, without changing their filesystem locations. Support entering either location and preserve file creation, selection, opening, context actions, drag and drop, and reveal behavior at applicable destinations.

Requirements: AC-002, AC-005

## I-2: Add Files views and filters

Provide accessible Icon, List, and Tree view controls with a clearly selected state. Icon and List navigate directories and show the current location; Tree expands and collapses folders. Add name, hidden-item, and category filters consistently across views, including recursive workspace-wide Tree search, ancestor retention, and all files in the All category. Persist view and filter choices and preserve applicable file operations.

Requirements: AC-001, AC-003, AC-005
Decisions: DEC-001, DEC-003

## I-3: Make file sorting explicit and persistent

Replace the cycling sort control with explicit, visible choices for Name or Date Modified and ascending or descending order. Keep folders before files, resolve ties by name, and persist sort choices across app restarts.

Requirements: AC-004, AC-005

## I-4: Move agent usage indicators to the workspace top bar

Move detected, enabled Claude Code and Codex usage indicators to the persistent workspace top bar across workspace views, including when Agents is closed. Keep agent identity, labeled quota, details, limit controls, and polling available; distinguish loading, stale, estimated, and unavailable states, and provide accessible narrow-width behavior without overlap.

Requirements: AC-006, AC-007

## I-5: Move Project Cycle Time access to the workspace top bar

Move access to Project Cycle Time from the Features panel to the persistent workspace top bar alongside agent usage. The presentation remains an open product choice: a compact button opening the existing summary or a visible metric with a selected value.

Requirements: 
Decisions: DEC-002

## I-6: Evaluate additional agent usage sources

Evaluate available usage sources for additional agents and add indicators only for agents with reliable quota data. Keep existing Claude Code and Codex support operational if no additional reliable source is available; this work must not delay their relocation.

Requirements: AC-008
