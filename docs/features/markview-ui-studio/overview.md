---
type: feature
id: markview-ui-studio
title: MarkView UI Studio
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-04
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
  Problem: Нужен единый цикл работы с настоящим UI вместо реконструкции и отдельного переноса изменений.
  Target Users: Пользователи MarkView, работающие с доверенными локальными веб-проектами.
  Primary Workflow: Запуск сценария, выбор элемента, вопрос или правка исходников, проверка, сохранение либо отмена.
  Permissions: Вопросы не меняют файлы; правки затрагивают исходники с историей и контролем конфликтов.
  Failure Scenarios: Определены ошибки подготовки, отмена, устаревшие ответы, конфликты правок и неудачная сборка; неподдерживаемые зависимости раскрываются явно.
  Data Model: Определены сценарии, изменяемое состояние сессии, операции, ревизии и визуальные свидетельства; внутренние форматы выбирает разработчик.
  Notifications: Состояние подготовки, ошибки, ограничения и устаревшее превью показываются внутри Studio.
  Security: Только доверенные проекты; отдельные границы для секретов, соединений, симуляции и агентов.
  Analytics: Продуктовая аналитика в объём функции не входит.
  Dependencies: "Граница подтверждена: клиентский веб-интерфейс независимо от фреймворка, включая Electron renderer; SSR и серверные/нативные адаптеры исключены. Существующие Electron-заглушки не подтверждают воспроизводимость сценария."
  Acceptance Criteria: Граница совместимости уточнена; основной цикл покрывают существующие требования и AC-01–AC-18. Дополнительных продуктовых вопросов сейчас не требуется.
questions_left: 0
issue: "#287"
---

# MarkView UI Studio

## Idea

Добавить в MarkView UI Studio: запускать настоящий интерфейс проекта с управляемыми тестовыми зависимостями, выбирать элементы, задавать вопросы и менять их исходный код через AI, затем проверять, сохранять или отменять результат.

## Problem

Сейчас просмотр работающего приложения и редактирование HTML-реконструкции — разные процессы. Реконструкция может расходиться с реальным интерфейсом, а перенос её изменений в исходники требует отдельного шага. Запрос предлагает единый цикл работы с настоящим UI и воспроизводимыми тестовыми ситуациями.

## Scope

IN: Run the actual project UI inside native MarkView; prepare and simulate supported dependencies; provide one active screen, viewport and zoom controls, DOM selection, AI questions and source edits, operation history and undo, saved scenarios, before/after comparison and feature export. Support client-rendered web interfaces across frameworks, including browser-executable Electron renderer scenarios. Scenarios requiring excluded dependencies must disclose their limitations. OUT: universal application simulation, Next.js/SSR, native SwiftUI execution, GraphQL/WebSocket/server/database adapters, real external authentication and payments, a Figma-level editor, multiple live screens, design variants, collaboration and proof of production backend correctness. VS Code support is optional in the source document and is not established as a required first-release deliverable.

## Existing behaviour

- Найден документ v0.1 от 2026-11-03; фактическое имя содержит «sudio». Он задаёт требования и AC-01–AC-18, но обозначает первый стек и часть ограничений как предложения. (`docs/plans/markview-ui-sudio-tech-reqs.md`)
- MarkView — нативное приложение macOS 13+ на SwiftUI/AppKit с WKWebView. React/Vite из предложения относится к запускаемому проекту, а не к оболочке MarkView. (`CLAUDE.md`)
- Уже обнаруживает веб-приложения, package manager, команды запуска и порты, включая монорепозитории и Electron renderer. Это обнаружение запуска, а не анализ контрактов API. (`MarkView/Models/WebAppPreview.swift`)
- Preview Web App уже открывает работающий локальный сервер либо запускает dev server в терминале и ожидает доступности. Управляемые сценарии UI Studio этим потоком не задаются. (`MarkView/Models/WorkspaceManager.swift`)
- Браузерная вкладка использует WKWebView, позволяет выбрать DOM-элемент и получить снимок его области для передачи агенту. (`MarkView/Models/BrowserSession.swift`)
- Существующий picker подсвечивает элемент, подавляет действия страницы при выборе и возвращает HTML, CSS-путь, текст и геометрию. Связь с исходным компонентом через инструментирование здесь отсутствует. (`MarkView/Resources/Editor/vendor/js/markview-pick-element.js`)
- Prototype Studio хранит отдельную HTML-реконструкцию в docs/prototypes/<slug>/, версии и историю. Её файловые изменения ограничены прототипом; восстановление версии копирует сохранённый site/, а не отменяет отдельную операцию в исходниках приложения. (`MarkView/Models/PrototypeFiles.swift`)
- Передача изменений прототипа в код уже формирует описание для отдельного агента и учитывает изменения исходников относительно baseline; сама исходники не переписывает. (`MarkView/Models/PrototypeHandoff.swift`)
- Уже создаёт feature с требованиями и прикреплёнными снимками через FeatureStore. Это существующий путь включения визуальных материалов в спецификацию. (`MarkView/Models/PrototypeFeatureWriter.swift`)
- Есть вызовы выбранного CLI-ассистента с изображениями, структурированным результатом, тайм-аутом и отменой. Фоновые completion-вызовы работают без права изменять файлы. (`MarkView/Models/CLICompletion.swift`)
- Ранее реализованная фича явно исключала прямое редактирование исходников из Studio и замену реконструкции работающим приложением. UI Studio заменяет создание реконструкций из существующего кода: соответствующие точки входа должны вести в UI Studio. Прототипирование по требованиям сохраняется. Ранее сохранённые реконструкции должны оставаться доступными, но не представляться как сессии работающего приложения. (`docs/features/prototype-and-code-stay-in-step/overview.md`)
