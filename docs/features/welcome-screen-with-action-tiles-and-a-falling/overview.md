---
type: feature
id: welcome-screen-with-action-tiles-and-a-falling
title: Welcome screen with action tiles and a falling-symbols backdrop
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView from Boris, /goal 2026-11-09 with a screenshot of the "No File Open" screen
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
---

# Welcome screen with action tiles and a falling-symbols backdrop

## Idea

The screen a window shows when no file is open ("No File Open" in a project window, "Open a Project" in an empty window) is a plain column of four small buttons (Open Terminal, New Feature, Open X-Ray, Open File) on a flat background. Boris wants it more functional and much more attractive: more actions than those four (New Bug, Search Project, Discussions, Tasks, Git, Build & Deployment, UI Studio, Browser, ...), and, wherever there is no text and no button, symbols that fall and change in the background like the Matrix rain. Scope: the welcome screen of a window only (project state and empty-window state). The rain must be cheap (the app has had CPU problems), follow the window's theme, respect Reduce Motion and never take clicks.

## Problem

## Scope
