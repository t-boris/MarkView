---
type: feature
id: issue-lifecycle-management
title: Issue Lifecycle Management
status: exploring
owner: Boris Tsekinovsky
created: 2026-11-05
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: partial
  Primary Workflow: partial
  Permissions: partial
  Failure Scenarios: partial
  Data Model: known
  Notifications: partial
  Security: partial
  Analytics: partial
  Dependencies: partial
  Acceptance Criteria: partial
understanding_notes:
  Problem: Проблема и желаемая связь статуса с реальной работой сформулированы.
  Target Users: Известны человек, управляющий issues, и AI-агент; охват поддерживаемых сессий открыт.
  Primary Workflow: Нужны создание, изменение и автоматические переходы; условия стадий и повторного открытия требуют решения.
  Permissions: Оба участника могут менять статус, но пределы их полномочий не определены.
  Failure Scenarios: Исследование выявило недоступность источников, конфликты и частичные сбои; поведение уточняется правилами.
  Data Model: В проекте существуют отдельные записи и словари статусов features и bugs.
  Notifications: Способ и необходимость отдельного уведомления о переходах не установлены; видимость ошибок входит в начальные требования.
  Security: Существуют полномочия MCP и GitHub, но новых отдельных требований безопасности запрос не устанавливает.
  Analytics: Исследование предлагает измерять доверие к автоматизации; обязательные метрики не согласованы.
  Dependencies: Известны MarkView MCP и существующая интеграция GitHub; роль GitHub и охват клиентов требуют решения.
  Acceptance Criteria: Общие проверяемые результаты сформулированы; точные критерии переходов зависят от решений владельца.
questions_left: 6
issue: "#294"
---

# Issue Lifecycle Management

## Idea

Управлять жизненным циклом features и bugs так, чтобы человек и AI работали с едиными правилами, а статусы автоматически отражали подтверждённое состояние работы. AI должен знать об issues и пользоваться управлением через MarkView MCP.

## Problem

Сегодня статусы меняются в разных сценариях по разным правилам. Журнал событий и статус не обязательно совпадают, а наличие MCP само по себе не гарантирует, что агент знает о текущем issue и применяет нужный процесс.

## Scope

Входит: жизненный цикл features и bugs, действия человека и AI, управление через MarkView MCP, автоматические переходы по согласованным правилам, контекст AI и связь с фактической работой. Связь с GitHub входит в рассмотрение; её полномочия и степень автоматизации требуют решения. Граница охвата внешних AI-сессий также открыта. Не входит: управление статусами отдельных требований и других объектов спецификации как отдельным жизненным циклом.

## Existing behaviour

- Features and bugs have separate status vocabularies: features run from idea to archived; bugs use open, fixing, fixed and closed. (`MarkView/Models/FeatureVocabulary.swift`)
- Project MCP tools list, read and create features and bugs and change their statuses. The guide describes their workflows; some feature-object decisions require explicit user authority. (`MarkView/Models/ProjectAgentTools.swift`)
- The Issues list derives open, closed and in-progress views from stored statuses. It also recognizes some values outside the main vocabulary. (`MarkView/Models/IssueListing.swift`)
- Feature implementation handoff sends work to an agent before marking the feature implementing; the single-bug handoff currently marks fixing before sending the prompt. (`MarkView/Models/WorkspaceManager.swift`)
- Lifecycle capture already collects some GitHub PR and check events, but its coverage and association with work are limited. (`MarkView/Models/LifecycleCapture.swift`)
- Manual GitHub Sync closes an open GitHub issue when all linked items are done; it does not reopen closed issues. (`MarkView/Models/IssueSync.swift`)
- MarkView registers project MCP for supported agents and provides a project-call fallback; registration alone does not prove that an agent follows the workflow. (`MarkView/Models/AgentBrowserRegistration.swift`)
