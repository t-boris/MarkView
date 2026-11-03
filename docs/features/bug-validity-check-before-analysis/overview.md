---
type: feature
id: bug-validity-check-before-analysis
title: Bug Validity Check Before Analysis
status: exploring
owner: Boris Tsekinovsky
created: 2026-11-02
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: partial
  Permissions: partial
  Failure Scenarios: partial
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: partial
understanding_notes:
  Problem: Нужно исключить повторный анализ и исправление уже устранённых багов.
  Target Users: Пользователи MarkView, запускающие анализ багов в проекте.
  Primary Workflow: Проверка перед каждым анализом и автозакрытие заданы; нужно выбрать состояние проекта для проверки.
  Permissions: Локальное автозакрытие разрешено запросом; автоматическое закрытие GitHub issue не определено.
  Failure Scenarios: Поведение при недостатке доказательств требует проработки при review; неопределённость сама по себе не подтверждает исправление.
  Data Model: Уже есть Markdown-отчёты, статусы багов и ссылки на GitHub issues.
  Notifications: Отдельные уведомления не запрошены.
  Security: Анализ сейчас читает проект без изменения кода; новых требований безопасности запрос не задаёт.
  Analytics: Метрики и аналитика не входят в запрос.
  Dependencies: Известны существующие процессы анализа, хранения статусов и ручной синхронизации GitHub.
  Acceptance Criteria: Основные переходы заданы; критерий доказанности исправления остаётся открытым.
questions_left: 3
issue: "#235"
---

# Bug Validity Check Before Analysis

## Idea

Check whether a selected bug still exists before every bug analysis. If verification establishes that the bug has already been fixed and requires no further correction, close it automatically and stop further investigation of that resolved problem.

## Problem

A bug report can remain open after its underlying problem has been fixed. The current investigation flow can continue refining that stale report and asking questions without first establishing whether any fix is still needed.

## Scope

IN: a mandatory validity check before each bug analysis; automatic closure when the problem is established as already fixed; stopping unnecessary investigation; continuing analysis for existing bugs. OUT: implementing bug fixes as part of this feature, bulk cleanup of unselected reports, and changing feature-analysis workflows. OPEN: the evidence required for closure, the project state used for verification, and whether closure also updates GitHub.

## Existing behaviour

- BugPanelView provides separate Investigate and Fix with AI actions and a manual status menu. Selecting a bug does not itself start an investigation. (`MarkView/Views/FeaturePanelView.swift`)
- investigateBug reads code and documentation to refine the report and ask missing questions. It has no explicit validity outcome or automatic closure. Answering a bug question and submitting a discussion message also trigger investigation. (`MarkView/Models/FeatureIntake.swift`)
- newBug performs read-only analysis before creating an open Markdown report. Reports can originate from an existing GitHub issue; adding the analysis as an issue comment is optional. (`MarkView/Models/FeatureIntake.swift`)
- The single-bug Fix with AI prompt already instructs the implementation assistant to reproduce the problem before finding its cause and fixing it. (`MarkView/Models/HandoffPrompt.swift`)
- Batch Fix with AI also requests reproduction before fixing each bug. The basket accepts open bugs and removes closed or fixed reports when reconciling its selection. (`MarkView/Models/BugBasket.swift`)
- The existing bug lifecycle statuses are open, fixing, fixed and closed. (`MarkView/Models/FeatureVocabulary.swift`)
- The implemented status-sync feature is manually initiated from Issues. Background synchronization is explicitly outside its scope. (`docs/features/sync-documented-status-to-github-issues/overview.md`)
- Status sync treats fixed and closed bug reports as completed and uses explicit links to identify GitHub issues eligible for closure. (`MarkView/Models/IssueSync.swift`)
