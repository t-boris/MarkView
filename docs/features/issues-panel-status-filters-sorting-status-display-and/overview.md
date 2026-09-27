---
type: feature
id: issues-panel-status-filters-sorting-status-display-and
title: "Issues panel: status filters, sorting, status display and resizable width"
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
issue: "#24"
understanding_notes:
  Problem: Нельзя фильтровать и сортировать; статус скрыт; панель не меняет ширину.
  Target Users: Пользователи MarkView, работающие с фичами и багами.
  Primary Workflow: Меню фильтра и сортировки рядом с полем Filter (DEC-001).
  Permissions: Не применимо.
  Failure Scenarios: Неизвестный или пустой статус считается Open; элементы без даты или приоритета идут в конце.
  Data Model: Соответствие статусов задано в DEC-002 и новом решении; ключи сортировки — в DEC-003.
  Notifications: Не применимо.
  Security: Не применимо.
  Analytics: Не применимо.
  Dependencies: FeatureNavigatorView, FeatureVocabulary, механизм изменения ширины левых панелей.
  Acceptance Criteria: Критерии есть в REQ-001…REQ-005.
questions_left: 0
---

# Issues panel: status filters, sorting, status display and resizable width

## Idea

Add status/type filters (Open, Closed, Bugs, Implemented, Not-implemented features) and sorting (by date, by priority) to the Issues panel under Features/Bugs; show each item's status explicitly in the row; make the panel resizable like the other left panels.

## Problem

The Issues panel (FeatureNavigatorView) only has a free-text filter and collapsible Features/Bugs sections. You can't narrow items by state or reorder them by date or priority. Bug status appears only in a tooltip and as dimmed text. According to the user, the panel can't be resized, unlike the other left panels.

## Scope

IN: status/type filter controls; sorting by date and priority/severity; a visible status indicator for features and bugs; resizable panel width that matches the other left panels. OUT (assumed): editing status from the panel, saved or custom filter presets, filtering GitHub issues from GitHubStore, changes to the feature/bug file formats beyond reading the existing fields.
