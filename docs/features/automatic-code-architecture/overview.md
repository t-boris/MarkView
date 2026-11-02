---
type: feature
id: automatic-code-architecture
title: Automatic Code Architecture
status: implementing
owner: Boris Tsekinovsky
created: 2026-10-31
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: known
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Problem: Нужно понимать структуру кодовой базы по самому коду без ручного описания архитектуры.
  Target Users: Пользователи MarkView, изучающие проекты с кодом; отдельные роли и уровень подготовки не заданы.
  Primary Workflow: Автоматический анализ и три вида диаграмм заданы; связь с X-Ray, выбор сценариев и жизненный цикл анализа ещё открыты.
  Permissions: В проекте уже есть механизм анализа через агента с доступом только для чтения; изменение исходников для этой задачи не требуется.
  Failure Scenarios: Существуют состояния прогресса, ошибки и отмена AI-анализа; поведение новой вкладки при неполном анализе ещё не определено.
  Data Model: Уже есть модель карты архитектуры и отдельная модель генерируемых диаграмм; представления последовательностей в X-Ray пока нет.
  Notifications: Достаточность существующего отображения прогресса предстоит проверить; отдельные уведомления не запрошены.
  Security: Анализ использует существующие настройки и ограничения агентов; автоматический запуск расширит моменты обращения к ним.
  Analytics: Новые продуктовые метрики не запрошены и не нужны для определения основной функции.
  Dependencies: Сканер, X-Ray, генерация диаграмм и подключение агентов уже существуют; гарантируемый набор языков пока не выбран.
  Acceptance Criteria: Базовый результат определён; для проверяемой первой спецификации нужны ответы о поддерживаемых проектах, сценариях и запуске анализа.
questions_left: 4
issue: "#206"
---

# Automatic Code Architecture

## Idea

Provide a Code/Architecture tab that automatically inspects a project's source code and presents diagrams of its architecture layers, components and interaction sequences, without requiring the user to describe the architecture.

## Problem

Users need to understand an unfamiliar codebase without manually reconstructing its architecture. Existing X-Ray and diagram tools provide related capabilities through separate, user-triggered workflows, but do not provide the requested automatic experience across all three diagram types.

## Scope

In: automatic source-code analysis and in-app diagrams of architecture layers, components and interaction sequences for an opened project. Pending decisions: relationship to X-Ray, supported codebases, scenario selection and analysis lifecycle. Out of the initial proposed scope: source-code modification, architecture redesign, application execution or runtime tracing, and new diagram families beyond the three requested. These exclusions are proposed boundaries, not recorded user decisions.

## Existing behaviour

- An architecture tab already exists as X-Ray, for both the project and individual folders. Opening it invokes ArchitectureStore.open. Code-project detection currently exposes an entry point rather than automatically opening the map. (`MarkView/Models/WorkspaceManager.swift:1402`)
- Existing code-project detection recognizes a root build manifest, Xcode project or solution, or at least ten source files within a bounded directory search. It does not classify every folder containing a single source file as a code project. (`MarkView/Models/ArchitectureScanner.swift:236`)
- The local scanner derives folders, source files, imports, type-reference dependencies, declared external packages and metrics. It honors Git ignore rules when listing Git workspace files and excludes common build and dependency directories. (`MarkView/Models/ArchitectureScanner.swift`)
- Opening X-Ray loads cached results and rescans locally. The scan explicitly leaves AI enrichment to the visible Analyze action. AI analysis clusters connected code, names components and groups them into subsystems; results are persisted and AI answers are cached by input. (`MarkView/Models/ArchitectureStore.swift:273`)
- X-Ray provides Logical, Structure, Deployment and Book views, plus PR X-Ray. Logical and Structure support expansion into files and their contents. The documented X-Ray views do not include a sequence-diagram view. (`docs/architecture/modules/architecture-and-xray.md`)
- Separate, user-triggered diagram generation already runs a headless agent against the project, writes a Markdown diagram document and opens it. Code Structure Map separately generates a code-derived architecture-layer diagram and supporting documentation. (`MarkView/Models/AIToolRuns.swift:119`)
- Diagram prompts already cover architecture components, layers and ordered scenario interactions, and instruct the agent to inspect code and provide source evidence. The validator checks node source-path existence but does not prove every relationship. All generated diagram kinds, including Sequence Diagram, currently serialize as flowcharts; sequence interactions use numbered edge labels. (`MarkView/Models/DiagramAI.swift`)
- In-app analysis already uses configured agent CLIs and read-only completion policies. Assistant and model selection are existing settings; this feature does not need a new provider-selection workflow. (`docs/architecture/modules/ai-assistants-and-dictation.md`)
