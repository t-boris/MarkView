---
type: feature
id: sync-documented-status-to-github-issues
title: Sync documented status to GitHub issues
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-28
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
  Problem: Расхождение статусов Markdown и GitHub и ручная работа по их согласованию описаны.
  Target Users: Пользователь вкладки Issues определён контекстом функции.
  Primary Workflow: Ручной запуск, немедленное применение и отчёт после выполнения определены.
  Permissions: Область действия ограничена связанными GitHub issues проекта; дополнительные продуктовые решения о доступе не требуются.
  Failure Scenarios: Ошибки и пропуски отражаются в отчёте; подробности обработки относятся к реализации и проверке.
  Data Model: Источники явных ссылок и направление передачи статуса определены.
  Notifications: Уведомления вне вкладки Issues не входят в сценарий.
  Security: Дополнительного продуктового решения в заданной области не выявлено.
  Analytics: Аналитика не входит в область функции.
  Dependencies: Зависимость от существующих ссылок Feature/Bug на GitHub issues определена.
  Acceptance Criteria: Поведение запуска, обновления и отчёта задано; оставшиеся частные случаи можно проверить при реализации.
questions_left: 0
---

# Sync documented status to GitHub issues

## Idea

Add a manual Sync action to the Issues tab that uses documented Feature and Bug lifecycle statuses to update their linked GitHub issues.

## Problem

Feature and Bug statuses in Markdown can diverge from GitHub issue state. Updating completed work on GitHub currently requires manual effort.

## Scope

IN: manual Sync in the Issues tab; resolving existing Feature/Bug links; updating eligible GitHub issues; reporting outcomes. OUT: background sync, issue creation, comments, assignees, milestones, other trackers, and unlinked items. The original issue included a preview and labels; DEC-002 excludes both. This specification replaces `sync-github-issues-with-feature-bug-status-from`, which is archived (DEC-004).
