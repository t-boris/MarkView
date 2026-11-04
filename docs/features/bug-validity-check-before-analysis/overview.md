---
type: feature
id: bug-validity-check-before-analysis
title: Bug Validity Check Before Analysis
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-02
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
understanding_notes:
  Problem: Открытые отчёты могут описывать уже исправленные проблемы и запускать ненужное расследование.
  Target Users: Пользователи, запускающие анализ существующих багов в MarkView.
  Primary Workflow: Перед каждым анализом существующего отчёта выполняется проверка относительно main; доказанное исправление закрывает отчёт, остальные исходы ведут к анализу.
  Permissions: Разрешено автоматическое локальное закрытие; обновление GitHub остаётся ручным через Sync.
  Failure Scenarios: Неопределённость сохраняет статус; ошибка сохранения закрытия показывается пользователю и не выдаётся за успех.
  Data Model: Используются существующие lifecycle-статусы; основание закрытия и проверенная ревизия сохраняются в отчёте. Исход проверки не является новым lifecycle-статусом.
  Notifications: Отдельные уведомления не нужны; результат и причина закрытия отображаются в текущем анализе.
  Security: Новые внешние полномочия не добавляются; проверка не реализует исправления и не изменяет GitHub.
  Analytics: Дополнительная аналитика не требуется для этой функции.
  Dependencies: Нужны доступ к проверяемой ревизии main и существующее сохранение отчётов; GitHub Sync остаётся отдельным процессом.
  Acceptance Criteria: Определены обязательные точки проверки, доказательства закрытия, базовая ревизия, обработка неопределённости и остановка расследования.
questions_left: 0
issue: "#235"
---

# Bug Validity Check Before Analysis

## Idea

Check whether a selected bug still exists before every bug analysis. If verification establishes that the bug has already been fixed and requires no further correction, close it automatically and stop further investigation of that resolved problem.

## Problem

A bug report can remain open after its underlying problem has been fixed. The current investigation flow can continue refining that stale report and asking questions without first establishing whether any fix is still needed.

## Scope

IN: a mandatory validity check before each bug analysis; automatic closure when the problem is established as already fixed; stopping unnecessary investigation; continuing analysis for existing bugs. OUT: implementing bug fixes as part of this feature, bulk cleanup of unselected reports, and changing feature-analysis workflows. Verification uses an identifiable revision of the project's main branch; uncommitted changes and fixes present only on another branch cannot establish resolution. Automatic closure requires concrete evidence that the reported scenario has already been fixed and needs no further correction; inability to reproduce alone is insufficient. Outcomes are still-present, already-fixed, or inconclusive; if main cannot be identified or inspected, the outcome is inconclusive. Investigation continues for still-present and inconclusive outcomes, preserving uncertainty. For already-fixed outcomes, investigation stops only after local closure is saved successfully; save failures must be surfaced without reporting successful closure. Automatic closure updates only the local report; linked GitHub issues remain subject to manually initiated status sync.

## Existing behaviour

- BugPanelView provides separate Investigate and Fix with AI actions and a manual status menu. Selecting a bug does not itself start an investigation. (`MarkView/Views/FeaturePanelView.swift`)
- investigateBug reads code and documentation to refine the report and ask missing questions. It has no explicit validity outcome or automatic closure. Answering a bug question and submitting a discussion message also trigger investigation. (`MarkView/Models/FeatureIntake.swift`)
- newBug performs read-only analysis before creating an open Markdown report. Reports can originate from an existing GitHub issue; adding the analysis as an issue comment is optional. (`MarkView/Models/FeatureIntake.swift`)
- The single-bug Fix with AI prompt already instructs the implementation assistant to reproduce the problem before finding its cause and fixing it. (`MarkView/Models/HandoffPrompt.swift`)
- Batch Fix with AI also requests reproduction before fixing each bug. The basket accepts open bugs and removes closed or fixed reports when reconciling its selection. (`MarkView/Models/BugBasket.swift`)
- The existing bug lifecycle statuses are open, fixing, fixed and closed. (`MarkView/Models/FeatureVocabulary.swift`)
- The implemented status-sync feature is manually initiated from Issues. Background synchronization is explicitly outside its scope. (`docs/features/sync-documented-status-to-github-issues/overview.md`)
- Status sync treats fixed and closed bug reports as completed and uses explicit links to identify GitHub issues eligible for closure. (`MarkView/Models/IssueSync.swift`)
