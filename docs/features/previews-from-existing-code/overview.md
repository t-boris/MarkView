---
type: feature
id: previews-from-existing-code
title: Previews from Existing Code
status: implemented
owner: Boris Tsekinovsky
created: 2026-11-02
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
  Problem: Нужно начинать визуальное обсуждение с существующего интерфейса; выбран самостоятельный AI-прототип.
  Target Users: Пользователь редактирует превью в MarkView и передаёт его AI-агенту того же проекта.
  Primary Workflow: Код → реконструкция → существующий процесс Studio → ссылка агенту. Выбор файлов и папок уже предусмотрен в PrototypeCreatorSheet.swift.
  Permissions: Получатель уже имеет доступ к проекту; внешняя публикация не требуется.
  Failure Scenarios: Требуется показывать известные пробелы реконструкции. В проекте уже есть обработка ошибок генерации и проверки правок; детали обработки определит реализация.
  Data Model: PrototypeFiles.swift уже хранит прототипы отдельно от исходников, с версиями и историей. Внутренние изменения модели определит реализация.
  Notifications: Отдельные уведомления для этого сценария не нужны.
  Security: Используется существующий локальный прототип без сетевых запросов; исходники не изменяются автоматически. Внешний доступ не входит в объём.
  Analytics: Аналитика не заявлена и не нужна для определения функции.
  Dependencies: Первая версия охватывает веб-интерфейсы и Electron renderer. Prototype Studio и чтение прототипов агентами уже существуют; Preview Web App остаётся отдельным сценарием.
  Acceptance Criteria: Критерии уточнены в трёх существующих требованиях. Дополнительных продуктовых вопросов для этой спецификации не требуется.
questions_left: 0
issue: "#234"
---

# Previews from Existing Code

## Idea

Создавать в MarkView превью на основе существующего кода, затем редактировать его в привычном процессе и передавать ссылку на результат для изменения реализации.

## Problem

Нужен способ начать визуальное обсуждение изменений с уже реализованного интерфейса. Сейчас просмотр работающего приложения и создание редактируемого прототипа существуют как отдельные сценарии; генерация прототипа ориентирована на требования.

## Scope

IN: Create a preview from existing code; use the established editing and review workflow; pass a preview link for implementation changes. DECIDED: AI shall reconstruct the existing interface and its scenarios as a standalone editable prototype; reconstruction limitations must be disclosed. OPEN: supported application types and recipient access. OUT of the stated request: automatic bidirectional synchronization between preview and source code, and automatic application of preview edits to production code.

## Existing behaviour

- New Prototype accepts project files or folders and an optional brief. Its UI describes the inputs as requirements; no sources means the whole project. The picker does not restrict inputs to Markdown. (`MarkView/Views/PrototypeCreatorSheet.swift`)
- Generation plans screens from requirement sources and may read referenced code. It produces a new standalone HTML/CSS/JavaScript prototype with simulated data and no network requests. The current prompts do not establish faithful reproduction of an existing implementation as the generation goal. (`MarkView/Models/PrototypeAI.swift`)
- Prototype Studio provides an interactive preview, chat and voice requests, element pointing with optional screenshots, image attachments, version restoration, and approval/export. (`MarkView/Views/PrototypeStudioView.swift`)
- Accepted prototype edits create versions. Conversations persist across reopening. Approval generates SPEC.md and an implementation ZIP containing the prototype and review history. (`MarkView/Models/PrototypeSession.swift`)
- Prototypes and their version snapshots are stored separately from application source code under .dde/prototypes/<slug>/. Prototype edits are validated within the prototype's files. (`MarkView/Models/PrototypeFiles.swift`)
- Preview Web App discovers supported web applications and development-server commands, including browser-only Electron renderers. This is a separate flow from generating a Prototype Studio artifact. (`MarkView/Models/WebAppPreview.swift`)
- Connected agents can list and read saved prototypes, including files, version, assumptions, review history, and SPEC.md when available. This provides existing implementation context access; it does not establish an externally accessible preview link. (`MarkView/Models/ProjectToolRunner.swift`)
