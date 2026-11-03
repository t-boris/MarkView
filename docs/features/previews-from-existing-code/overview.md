---
type: feature
id: previews-from-existing-code
title: Previews from Existing Code
status: exploring
owner: Boris Tsekinovsky
created: 2026-11-02
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: partial
  Primary Workflow: partial
  Permissions: partial
  Failure Scenarios: partial
  Data Model: partial
  Notifications: n/a
  Security: partial
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: partial
understanding_notes:
  Problem: Нужно начинать работу с превью существующей реализации и передавать визуальные изменения в разработку.
  Target Users: Пользователь MarkView, обсуждающий изменения интерфейса; получатель ссылки пока не определён.
  Primary Workflow: Код → превью → редактирование → ссылка для изменения реализации. Способ воспроизведения кода требует решения.
  Permissions: Не определено, достаточно ли доступа в текущем проекте или нужен внешний доступ.
  Failure Scenarios: В Studio есть остановка, повтор запроса и обработка ошибок превью; сбои создания из кода предстоит разобрать при ревью.
  Data Model: Уже есть сохранённые прототипы, версии и история. Связь превью с исходной реализацией пока не определена.
  Notifications: Отдельные уведомления запросом не предусмотрены; существующий Studio показывает ход работы.
  Security: Текущие прототипы работают без сети; исполнение исходного приложения и внешняя передача потребуют проверки после выбора сценария.
  Analytics: Новые метрики и аналитика для этой функции не запрошены.
  Dependencies: Есть Prototype Studio, Preview Web App и доступ агентов к прототипам; набор поддерживаемых приложений открыт.
  Acceptance Criteria: Основная цепочка определена; точность превью и доступность ссылки зависят от трёх продуктовых решений.
questions_left: 3
issue: "#234"
---

# Previews from Existing Code

## Idea

Создавать в MarkView превью на основе существующего кода, затем редактировать его в привычном процессе и передавать ссылку на результат для изменения реализации.

## Problem

Нужен способ начать визуальное обсуждение изменений с уже реализованного интерфейса. Сейчас просмотр работающего приложения и создание редактируемого прототипа существуют как отдельные сценарии; генерация прототипа ориентирована на требования.

## Scope

IN: Create a preview from existing code; use the established editing and review workflow; pass a preview link for implementation changes. OPEN: execution versus reconstruction, supported application types, and recipient access. OUT of the stated request: automatic bidirectional synchronization between preview and source code, and automatic application of preview edits to production code.

## Existing behaviour

- New Prototype accepts project files or folders and an optional brief. Its UI describes the inputs as requirements; no sources means the whole project. The picker does not restrict inputs to Markdown. (`MarkView/Views/PrototypeCreatorSheet.swift`)
- Generation plans screens from requirement sources and may read referenced code. It produces a new standalone HTML/CSS/JavaScript prototype with simulated data and no network requests. The current prompts do not establish faithful reproduction of an existing implementation as the generation goal. (`MarkView/Models/PrototypeAI.swift`)
- Prototype Studio provides an interactive preview, chat and voice requests, element pointing with optional screenshots, image attachments, version restoration, and approval/export. (`MarkView/Views/PrototypeStudioView.swift`)
- Accepted prototype edits create versions. Conversations persist across reopening. Approval generates SPEC.md and an implementation ZIP containing the prototype and review history. (`MarkView/Models/PrototypeSession.swift`)
- Prototypes and their version snapshots are stored separately from application source code under .dde/prototypes/<slug>/. Prototype edits are validated within the prototype's files. (`MarkView/Models/PrototypeFiles.swift`)
- Preview Web App discovers supported web applications and development-server commands, including browser-only Electron renderers. This is a separate flow from generating a Prototype Studio artifact. (`MarkView/Models/WebAppPreview.swift`)
- Connected agents can list and read saved prototypes, including files, version, assumptions, review history, and SPEC.md when available. This provides existing implementation context access; it does not establish an externally accessible preview link. (`MarkView/Models/ProjectToolRunner.swift`)
