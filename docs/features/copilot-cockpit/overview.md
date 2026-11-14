---
type: feature
id: copilot-cockpit
title: Copilot Cockpit
status: in-review
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
  Problem: Единый способ направлять и наблюдать цикл проверка → исправление → перепроверка с явными критериями успеха.
  Target Users: Пользователь MarkView, управляющий проектом; отдельные роли не выделены, для первой версии этого достаточно.
  Primary Workflow: Цель → план с шагами и агентами → утверждение → исполнение в Temporal → живой граф, управление и перепланирование.
  Permissions: Переключатели возможностей — рекомендательные инструкции агенту с полным доступом (DEC-006); это осознанно принято.
  Failure Scenarios: Неудачная начальная проверка — пауза и повтор; закрытие MarkView — пауза; прерванный шаг — показ известных результатов и решение пользователя.
  Data Model: Запуски, версии плана, результаты со ссылками на сценарии, баги и сборки; формат определит реализатор.
  Notifications: Отдельные уведомления не входят в объём.
  Security: Агент сохраняет полный доступ; production QA подтверждается через утверждение плана с явным списком действий (DEC-008).
  Analytics: Не требуется.
  Dependencies: Локальный Temporal поставляется с приложением (только arm64), MarkView MCP, существующие E2E QA, баги и логи сборок.
  Acceptance Criteria: Критерии заданы в утверждённых требованиях REQ-001–REQ-006.
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
