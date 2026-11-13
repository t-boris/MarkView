---
type: feature
id: copilot-cockpit
title: Copilot Cockpit
status: backlog
owner: Boris Tsekinovsky
created: 2026-11-13
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: partial
  Primary Workflow: known
  Permissions: partial
  Failure Scenarios: known
  Data Model: partial
  Notifications: n/a
  Security: partial
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: known
understanding_notes:
  Problem: Известна потребность управлять циклом проверки и исправления и оценивать его результат.
  Target Users: Пользователь работает в контексте проекта MarkView; более узкая сегментация для спецификации не требуется.
  Primary Workflow: Определены цель, согласование плана, выполнение, наблюдение и согласование изменений.
  Permissions: Выбранные возможности должны реально ограничивать действия запуска; способ обеспечения ограничений предстоит определить при реализации.
  Failure Scenarios: Закрытие приложения приостанавливает запуск; после перезапуска пользователь сам выбирает продолжение.
  Data Model: Результаты сохраняют связь с прежними планом и сборкой; внутреннее представление определит реализация.
  Notifications: Отдельные уведомления в описанную область не входят.
  Security: README указывает, что MarkView запускает CLI с правами пользователя; наличие принудительных ограничений для cockpit этим не подтверждается.
  Analytics: Аналитика использования не запрошена; показатели выполнения относятся к наблюдению за запуском.
  Dependencies: Определены роли Temporal, MCP и существующих результатов QA. Техническую интеграцию предстоит спроектировать.
  Acceptance Criteria: Основные пользовательские результаты и решение о продолжении известны; детали проверок можно определить при подготовке реализации.
questions_left: 0
issue: "#396"
---

# Copilot Cockpit

## Idea

A project-scoped Copilot Cockpit turns a user's goal into a reviewable plan for a test–fix–retest run, executes it with selected capability controls passed to the agent as advisory instructions, and shows a live graph linked to existing MarkView results. The agent retains full user permissions and can perform actions disabled in the controls. Copilot proposes the plan, a saved process definition supplies stages and constraints, Temporal executes it, and MarkView MCP provides actions.

## Problem

A user needs a coherent way to direct and observe a multi-step verification and repair effort across existing MarkView capabilities, understand what the agent may do, and judge the outcome against explicit success criteria.

## Scope

In: one test–fix–retest template; goal and capability controls; AI planning and text refinements; explicit success criteria; Temporal execution; live graph and run controls; links to scenarios, bugs and build logs. Out: a universal process editor and direct editing of graph blocks in the first version. Strike Desk and Paper Account are examples, not established product-specific requirements.

## Existing behaviour

- End-to-End QA already turns a goal into an editable branching scenario and supports web, native macOS and HTTP API scenarios. QA scenarios are project assets; runs and linked bugs are retained under documented rules. (`README.md`)
- The existing End-to-End QA architecture documents scenario execution and results; it is the relevant starting point for connecting cockpit runs to QA. (`docs/architecture/modules/end-to-end-qa.md`)
- The project already has a Workflow tab with graphical and source views, validation, templates and process definitions for feature and bug lifecycle rules. This is an existing work-item workflow, not evidence of a Temporal execution engine. (`MarkView/Views/WorkflowTabView.swift`)
- Control tools already start and report long-running feature-flow jobs. Product-owner actions in that flow require an explicit by-user indication; delegated decisions remain proposed. (`MarkView/Models/ControlToolRunner+Flow.swift`)
- MarkView provides local MCP servers for project artifacts, browser interaction and app control. Agent CLIs run in project terminals; the browser server can operate visible browser tabs. (`README.md`)
- The project contains deployment command execution and connection-failure handling. The presence of these capabilities does not establish that cockpit permissions can already constrain every operation an agent can perform. (`MarkView/Models/DeploymentExecutor.swift`)
- MarkView is a native macOS app. Its repository currently has no XCTest target; relevant standalone checks and focused manual verification are used. (`CLAUDE.md`)
