---
type: feature
id: flexible-files-views-and-visible-agent-usage
title: Flexible Files Views and Visible Agent Usage
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-08
provenance: Created from the quick feature intake
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
intake: quick
questions_left: 0
issue: "#320"
---

# Flexible Files Views and Visible Agent Usage

## Idea

Make Files adaptable to different browsing tasks and put agent quota at a glance in the workspace top bar.

## Problem

The current directory-by-directory file list makes hierarchy and hidden-item control difficult to see, while quota indicators are confined to the Agents panel.

## Scope

Redesign the Files navigation and controls; relocate existing agent usage indicators and add other agents only where reliable data is available.

## Analysis

The Files surface in MarkView/Views/FileTreeView.swift browses one directory at a time, filters its immediate entries by name, and places linked folders among project-root contents. It creates files and folders in the browsed directory and supports selection, drag and drop, and contextual actions. MarkView/Models/FileNode.swift already models a lazily loaded expandable tree, but that is not the current Files presentation; it includes directories and openable files. Name and modification-date sorting, with direction persisted in MarkView/Models/WorkspaceManager.swift, is currently exposed as a cycling button. MarkView/Views/ModuleExplorerView.swift hosts AgentUsageBar in the Agents header. MarkView/Views/AgentUsageViews.swift displays detected Claude and Codex usage, details and fallback states; its visibility controls polling. MarkView/Models/AgentUsageTracker.swift and MarkView/Models/AgentUsageLogs.swift provide official usage and local-log fallback data.

## Assumptions

Made by the AI where the request left a choice open; correct them in the discussion.

- “Root” means the project root; the requested parallel objects are linked folders, presented with it under a virtual workspace level.
- “Main bar” means the persistent top bar of the project workspace, rather than the Agents panel header.
- Name search is scoped to the browsed directory in Icon and List views. In Tree view, it searches recursively across the project root and all linked folders, including collapsed and not-yet-loaded directories.
- Filtering hidden items includes dot-prefixed names and items marked hidden by the filesystem.
- Additional agent support is opportunistic and must not delay the relocation of existing indicators.

## Acceptance Criteria

- [ ] Files offers Icon, List, and Tree views with an accessible, clearly selected view control. Tree view expands and collapses folders; Icon and List views navigate folders and show the current location.
- [ ] A virtual top level displays the project root and linked folders as siblings. Users can enter either without changing its filesystem location.
- [ ] Users can toggle hidden files and folders and filter by name and by file category: all, folders, or openable files. Hidden items are excluded by default; filters apply consistently in all views, and Tree retains the ancestors needed to reach matches.
- [ ] Users can explicitly select Name or Date Modified and ascending or descending order. Folders precede files, ties sort by name, and the active sort is visible.
- [ ] View, filter, and sort choices persist across app restarts. Existing file opening, creation in the chosen destination, selection, context-menu actions, drag and drop, and reveal behavior remain usable in each applicable view.
- [ ] Detected, enabled Claude Code and Codex usage indicators appear in the main workspace top bar across workspace views, including when the Agents panel is closed. Each identifies the agent and shows used or remaining quota with an explicit label; its existing details and limit controls remain accessible.
- [ ] At narrow widths, usage indicators remain accessible without overlapping other controls. Loading, stale, estimated, and unavailable states are distinguishable; unavailable quota is never presented as zero.
- [ ] Additional agent quota indicators are added only where a reliable usage source is available; otherwise the existing supported agents continue to work.
