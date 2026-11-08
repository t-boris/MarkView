---
type: feature
id: x-ray-comparison-by-date
title: X-Ray Comparison by Date
status: implemented
owner: Boris Tsekinovsky
created: 2026-11-08
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
understanding_notes:
  Problem: Известна потребность сравнить текущий код с историческим коммитом через выбор даты.
  Target Users: Пользователи X-Ray, исследующие изменения кода; более узкая роль для спецификации не требуется.
  Primary Workflow: Дата, коммит, сравнение с рабочей копией и переключение между двумя картами определены.
  Permissions: Изменение истории или кода не входит в задачу.
  Failure Scenarios: Пустой день предусмотрен; обработка ошибок Git и недоступных данных относится к реализации.
  Data Model: Определены точный календарный день, локальные ветки, базовый коммит и рабочая копия.
  Notifications: Уведомления не требуются.
  Security: Новых полномочий или внешней интеграции в рамках задачи не требуется.
  Analytics: Новая аналитика использования не запрошена.
  Dependencies: Проект уже предоставляет PR X-Ray, просмотр изменений файлов и наложения; совместное отображение исторических изменений и метрик потребуется обеспечить в реализации.
  Acceptance Criteria: Критерии покрывают выбор, сравнение, оба режима карты и совместимость наложений.
questions_left: 0
issue: "#314"
---

# X-Ray Comparison by Date

## Idea

Let a user choose a date, select a commit associated with that date, and inspect the difference between that commit and the current code in X-Ray. Highlight changed parts and allow existing overlays, such as complexity and size, to be applied while examining the difference.

## Problem

A user cannot select a historical point by date and commit to understand how the current code differs from it in X-Ray. Existing PR and branch comparisons do not provide this date-first workflow.

## Scope

In: choosing a date and commit, comparing that baseline with current code, highlighting the difference in X-Ray, and using existing overlays alongside it. Out: changing repository history or code, and introducing new metrics or a new review workflow.

## Existing behaviour

- X-Ray уже показывает представления Code, Logical, Structure и Deployment и поддерживает наложения сложности, размера и других характеристик. Отдельное представление PR X-Ray показывает изменения в контексте архитектуры. (`README.md`)
- Существующее сравнение с веткой открывается в PR X-Ray; прямое сравнение включает коммиты и незакоммиченные изменения текущей рабочей копии. Обратное сравнение тоже доступно. (`MarkView/Models/WorkspaceManager.swift`)
- Источники PR X-Ray включают локальные изменения относительно базовой ветки и, при включённой интеграции GitHub, pull request. Выбор исторического коммита по дате среди этих источников не предусмотрен. (`MarkView/Models/ArchitectureStore.swift`)
- PR X-Ray строит карту затронутых файлов, их родителей и связанных изменений зависимостей. Файл остаётся конечным узлом карты; детали изменений открываются в просмотрщике файла. (`MarkView/Resources/Editor/vendor/js/markview-architecture.js`)
- Документация описывает просмотр diff, анализ изменений и отображение изменений в файлах для PR X-Ray. Существующий режим использует актуальную архитектурную карту как контекст для выбранного изменения. (`docs/architecture/modules/architecture-and-xray.md`)
