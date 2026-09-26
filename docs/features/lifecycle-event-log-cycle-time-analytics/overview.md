---
type: feature
id: lifecycle-event-log-cycle-time-analytics
title: Lifecycle event log & cycle-time analytics
status: implementing
owner: Boris Tsekinovsky
created: 2026-09-26
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: known
  Dependencies: known
  Acceptance Criteria: known
issue: "#2"
understanding_notes:
  Problem: Нет данных о длительности шагов и исполнителях/моделях.
  Target Users: Команда, работающая в MarkView с AI-агентами.
  Primary Workflow: Гибридная фиксация событий (DEC-002), расширенный список этапов (DEC-006).
  Permissions: Локальное хранилище на одной машине.
  Failure Scenarios: Исправления не поддерживаются (DEC-005).
  Data Model: Неизменяемые события с метаданными (REQ-001, REQ-002).
  Notifications: Не требуются.
  Security: Только локальное хранение (DEC-001).
  Analytics: Таймлайн фичи и сводная таблица по проекту (DEC-004).
  Dependencies: Автоматическая фиксация — там, где MarkView может наблюдать переход, остальное вручную.
  Acceptance Criteria: Критерии заданы в REQ-001…REQ-004.
questions_left: 0
---

# Lifecycle event log & cycle-time analytics

## Idea

Record timestamped events at key transitions of a feature's lifecycle in MarkView (e.g. idea created → spec ready → implementation started/finished by AI → merged to main → verified), each carrying metadata (project, feature, AI agent/model, actor, etc.), so durations between events can later be computed and compared — e.g. time AI spent implementing, per model, or which process steps are bottlenecks.

## Problem

There is currently no recorded data about how long each step of the idea-to-shipped process takes or who/which model performed it, so the team cannot compare AI models' speed/quality or identify slow steps worth automating.

## Scope

IN: event model and storage; emitting events at defined lifecycle transitions; metadata (project, feature id, AI model/agent, actor, timestamps); computing durations between event pairs; basic aggregation by model/project/step. OUT (for now, inferred): quality scoring of AI output, cost/token accounting, dashboards beyond basic reports, cross-workspace/team analytics, external BI export.
