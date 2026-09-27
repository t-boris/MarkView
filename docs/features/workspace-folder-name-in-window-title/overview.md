---
type: feature
id: workspace-folder-name-in-window-title
title: Workspace folder name in window title
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: n/a
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#25"
understanding_notes:
  Problem: Окна разных проектов неразличимы.
  Target Users: Пользователи MarkView с несколькими проектами.
  Primary Workflow: Открыть папку — заголовок обновляется.
  Permissions: Не применимо.
  Failure Scenarios: Фолбэк без папки, одинаковые имена через represented URL.
  Data Model: Только имя корневой папки и версия.
  Notifications: Не применимо.
  Security: Не применимо.
  Analytics: Не применимо.
  Dependencies: navigationTitle в MarkViewApp.swift, состояние WorkspaceManager.
  Acceptance Criteria: "Формат зафиксирован: «MarkView 1.4 — foo»."
questions_left: 0
---

# Workspace folder name in window title

## Idea

Show the name of the currently opened workspace folder in the MarkView window title alongside the app version (e.g. "MarkView 1.4 — my-project"), so windows from different projects are distinguishable.

## Problem

MarkView is used across many projects, but every window title is the same static "MarkView <version>" (set via .navigationTitle in MarkView/App/MarkViewApp.swift:189). With several windows open, in Mission Control, Cmd+` or the Window menu, users cannot tell which window belongs to which project.

## Scope

In: the window title shows the app version plus the name (last path component) of the workspace root folder; the title updates when the workspace changes; there is a fallback when no folder is open. Out: showing the full path, the active file name or git branch; custom title templates or settings; changes to the Dock or app name; the "DDE Settings" window.
