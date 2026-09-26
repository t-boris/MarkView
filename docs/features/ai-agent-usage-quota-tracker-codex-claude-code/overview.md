---
type: feature
id: ai-agent-usage-quota-tracker-codex-claude-code
title: AI agent usage & quota tracker (Codex, Claude Code, etc.)
status: review
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
  Notifications: known
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#12"
understanding_notes:
  Problem: Пользователь не видит расход квоты и время до сброса.
  Target Users: Один пользователь, личные подписки.
  Primary Workflow: Компактный индикатор в панели AI-терминала, детали во всплывающем окне.
  Permissions: Однопользовательское приложение.
  Failure Scenarios: Нет лимита — подсказка; логи не читаются — «usage unavailable».
  Data Model: Официальные данные о лимите, иначе расход из локальных логов относительно лимита пользователя.
  Notifications: Уведомлений нет, только цвет индикатора.
  Security: Учётные данные используются только локально и только для запроса лимитов.
  Analytics: Не требуется.
  Dependencies: Локальные логи Claude Code/Codex и их официальные данные о лимитах.
  Acceptance Criteria: Критерии заданы в требованиях.
questions_left: 0
---

# AI agent usage & quota tracker (Codex, Claude Code, etc.)

## Idea

Show, for each AI coding agent the user works with (e.g. Codex, Claude Code), how much of the current quota period has been used and how much remains: tokens or money spent, tokens/money left, and time until the next reset. The goal is a visible progress indicator so the user can pace their usage.

## Problem

The user can't see how much of their agent quota (tokens or budget) they have used in the current reset window, or how long until it resets, so they can't tell whether they are on pace or about to hit the limit.

## Scope

IN: per-agent usage display (Codex, Claude Code, possibly others); used vs remaining tokens and/or money in the current window; time until reset; a progress/pacing indicator. OUT (assumed, needs confirmation): changing or buying plans, automatically throttling agents, historical analytics past the current window, team/multi-user billing.
