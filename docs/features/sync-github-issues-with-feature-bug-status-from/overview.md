---
type: feature
id: sync-github-issues-with-feature-bug-status-from
title: Sync GitHub Issues with Feature/Bug status from the Issues tab
status: archived
owner: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#36"
understanding_notes:
  Problem: Статусы в документации и GitHub issues расходятся; их обновляют вручную.
  Target Users: Команда проекта, которая работает во вкладке Issues.
  Primary Workflow: Ручной Sync применяет изменения сразу, после чего показывается отчёт (DEC-001).
  Permissions: Используется существующий доступ к GitHub; без прав на запись результат будет failed в отчёте.
  Failure Scenarios: Ошибки по отдельным issue попадают в отчёт как failed или skipped.
  Data Model: Связи берутся из существующих источников. Markdown не меняется (DEC-003).
  Notifications: Вне scope.
  Security: Используется существующая авторизация GitHub.
  Analytics: Не требуется.
  Dependencies: GitHub API и существующая интеграция с GitHub.
  Acceptance Criteria: Покрыты в REQ-001…REQ-004.
questions_left: 0
---

# Sync GitHub Issues with Feature/Bug status from the Issues tab

> Archived: replaced by `docs/features/sync-documented-status-to-github-issues/` (its DEC-004), which carries these decisions and is the implemented specification.

## Idea

Add a "Sync" action to the Issues tab. It reconciles the linked GitHub Issues with the lifecycle status of the documented Features and Bugs. When a feature or bug is already Implemented in the docs, sync updates the linked GitHub issue to match (for example, closes it or labels it "implemented").

## Problem

Feature/bug status lives in Markdown front matter (planned → implementing → implemented → verified → archived). GitHub Issues are tracked separately. Today they drift apart: work marked Implemented in the docs stays open or unmarked on GitHub, so someone has to update each one by hand.

## Scope

IN: a manual sync action in the Issues tab; matching features and bugs to GitHub issues through existing links (the `github` field, front matter `issue`/`issues`, issue links and "issue #n" mentions); updating GitHub issue state or labels for items whose status is implemented or later; a preview and result report. OUT (for now): automatic or background sync; creating new GitHub issues; syncing comments, assignees or milestones; other trackers (Jira, Linear); items with no linked issue.
