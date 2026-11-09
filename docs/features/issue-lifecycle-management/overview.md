---
type: feature
id: issue-lifecycle-management
title: Issue Lifecycle Management
status: done
owner: Boris Tsekinovsky
created: 2026-11-05
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
  Problem: "Из запроса: статусы должны отражать подтверждённую работу по единым правилам для человека и AI."
  Target Users: "Участники определены: человек, управляющий issues, и AI в поддерживаемых или явно подключённых сессиях."
  Primary Workflow: Ответами определены завершение после merge, проверок и необходимого выпуска, отдельная приёмка, обработка регрессий и автоматизация GitHub. Проект уже использует передачу агенту для начала реализации.
  Permissions: "Решение пользователя: человек может принудительно менять статус с причиной; AI действует по правилам. GitHub не управляет локальным статусом напрямую."
  Failure Scenarios: Требования охватывают неопределённость, сбои передачи, повторные события, конкурентные изменения и восстановление; детали проверит реализация и review.
  Data Model: "Подтверждено кодом: Markdown-записи, отдельные словари features и bugs, существующие связи с GitHub. Форматы реализации не требуют продуктового выбора."
  Notifications: Предусмотрена видимость причин, блокировок и расхождений. Отдельные каналы уведомлений для этой функции не требуются.
  Security: Граница человеческого override определена; AI не может выдавать собственное действие за человеческое подтверждение. Проверка доступа GitHub уже существует в Sync.
  Analytics: История переходов нужна для объяснимости; отдельная аналитическая система не входит в спецификацию.
  Dependencies: Код подтверждает наличие MCP, сбора GitHub-событий и ручного Sync. CLAUDE.md определяет обязательный выпуск MarkView; его условия не нужно согласовывать повторно.
  Acceptance Criteria: Ответы преобразованы в проверяемые критерии. Дополнительных блокирующих продуктовых вопросов по текущему объёму не выявлено.
questions_left: 0
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
