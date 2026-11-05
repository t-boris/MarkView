---
type: feature
id: mind-map
title: Исследование через mind map
status: implemented
owner: Boris Tsekinovsky
created: 2026-11-04
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Problem: "Известно: вместо линейного отчёта нужна карта для постепенного исследования и перестройки тем."
  Target Users: Известен основной сценарий пользователя MarkView; дополнительная сегментация для этой функции не требуется.
  Primary Workflow: Согласованы начальное исследование, ревью, ручное редактирование, AI-развитие и сохранение старых отчётов.
  Permissions: Новые роли или разрешения в рамках функции не заданы.
  Failure Scenarios: "Known: a stopped, failed or timed-out run keeps every node received and marks the map incomplete with the reason; Continue resumes it (DEC-008). A file that is not a readable map stays in the Markdown source view with the reason (DEC-006). A rejected edit shows a one-line notice and changes nothing (DEC-009)."
  Data Model: Карта имеет иерархию узлов, отдельное визуальное расположение, логические связи и доказательную информацию; внутренний формат остаётся за реализацией.
  Notifications: Новые уведомления в рамках функции не требуются.
  Security: Действующий research ограничивает содержимое веб-запросов и позволяет отключить веб-поиск; эти правила остаются применимыми.
  Analytics: Новые аналитические события не запрошены.
  Dependencies: "Known: the archive SRC-002 (markview-v10.zip) was unpacked and compared with docs/prototypes/markview/site; all seven prototype files are byte-identical, so the repository prototype v10 is the archive's prototype. No new libraries: the map is drawn with the page's own DOM and SVG, the file format and the rules live in Swift."
  Acceptance Criteria: Основные проверяемые действия и сохранение доказательной информации определены; детали реализации и пограничные случаи остаются на проверку при разработке.
questions_left: 0
issue: "#293"
---

# Исследование через mind map

## Idea

Исследование начинается с центральной сути вопроса и развивается изнутри наружу: AI создаёт основные ветви и более детальные уровни, а пользователь ревьюит и продолжает карту вручную или с помощью AI. Карта открывается в отдельной вкладке и ориентируется на приложенный прототип.

## Problem

Сейчас research выдаёт линейный Markdown-отчёт. Для задуманного сценария пользователю нужна наглядная карта, которую можно постепенно развивать и перестраивать по мере исследования.

## Scope

Входит: новый research в отдельной вкладке-карте, начальное исследование AI, иерархия от сути к деталям, ревью, ручное добавление и перенос узлов, развитие ветвей по запросу пользователя. Граница функций прототипа, представление карты в Markdown и обработка изменений во внешнем текстовом редакторе требуют решений. Существующие Markdown-отчёты сохраняются в текущем виде; их преобразование не входит в эту функцию. Вне текущего запроса: изменения других инструментов анализа и реализация самой функции.

## Existing behaviour

- MarkView — нативное приложение macOS; поставляемый редактор находится в MarkView/Resources/Editor. Содержимое EditorWeb пока не подключено к приложению. (`CLAUDE.md`)
- New Research сейчас запускается в фоне и сохраняет отчёт с источниками в docs/research/. Остановленный результат помечается как неполный; исследование можно продолжить или углубить. (`README.md`)
- Текущий сценарий принимает вопрос, целевые документы и вложения, исследует репозиторий, сохраняет Markdown и открывает его. Для отчёта также доступны продолжение и комментарии. (`MarkView/Models/ResearchJobs.swift`)
- Текущий research различает факты проекта, внешние факты, выводы AI и открытые предположения; указывает источники и ограничивает содержание веб-запросов. Веб-поиск можно отключить. (`MarkView/Models/ResearchPrompt.swift`)
- В приложении есть запуск нового исследования и запуск исследования из папки. (`MarkView/Models/WorkspaceManager.swift`)
- В репозитории есть прототип v10 карты исследования: в нём предусмотрены выбор, добавление, редактирование, удаление и визуальное перемещение узлов, связи и панель свойств. Это прототип, а не подтверждение наличия этих возможностей в приложении. The attached ZIP (SRC-002) matches this prototype byte for byte (checked during implementation). (`docs/prototypes/markview/versions/v10/screens/research-map.js`)
