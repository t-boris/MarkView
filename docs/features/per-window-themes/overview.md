---
type: feature
id: per-window-themes
title: Per-Window Themes
status: done
owner: Boris Tsekinovsky
created: 2026-11-08
provenance: Created from the quick feature intake
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
intake: quick
questions_left: 0
issue: "#312"
understanding_notes:
  Problem: "Из исходного запроса известно: внешний вид кажется слишком простым; пользователь хочет более выразительный интерфейс."
  Target Users: Функция предназначена пользователям окон рабочих пространств MarkView; дополнительная сегментация для неё не требуется.
  Primary Workflow: В каждом окне выбираются один из четырёх пресетов и акцент; изменения применяются сразу и независимо от других окон.
  Permissions: Особые роли или разрешения для локальной настройки внешнего вида не предусмотрены.
  Failure Scenarios: Для отсутствующих и некорректных настроек предусмотрен пригодный запасной вариант; смена темы должна сохранять документы, несохранённые правки и состояние панелей.
  Data Model: Критерии задают восстановление темы и акцента каждого восстановленного окна и последние выбранные значения для нового окна. Детали хранения остаются за реализацией.
  Notifications: Пользовательские уведомления для этой функции не требуются.
  Security: Новых требований безопасности в пределах функции не выявлено.
  Analytics: Сбор аналитики для этой функции не запрошен.
  Dependencies: Проект использует общий ThemeManager, нативный интерфейс и встроенный редактор WKWebView; состояние панелей уже принадлежит отдельным окнам.
  Acceptance Criteria: Критерии охватывают четыре пресета, поверхности интерфейса, независимость окон, сохранение, обновление, читаемость и сохранность состояния. Предположения о System и границах настройки остаются обозначенными как предположения.
---

# Per-Window Themes

## Idea

Give each workspace window a polished, configurable visual identity through a small collection of coordinated themes, including an IntelliJ-inspired option.

## Problem

MarkView currently offers a basic shared light/dark appearance, leaving users with limited visual variety and no independent theme choice for each workspace window.

## Scope

Add four built-in themes, per-window theme and accent selection, persistence and coordinated styling across MarkView-owned native and web-based interface surfaces. Preserve existing functionality and text-size controls.

## Analysis

MarkView/Models/ThemeManager.swift stores a global light, dark or system preference and applies an app-wide NSApp appearance. MarkView/App/MarkViewApp.swift shares one ThemeManager across workspace windows and sets a dark appearance when a window appears. MarkView/Views/ContentView.swift and MarkView/App/MarkViewApp.swift expose a light/dark toggle. MarkView/Views/EditorView.swift, MarkView/Bridge/WebViewBridge.swift and MarkView/Resources/Editor/index.html synchronize only light or dark editor styling; MarkView/Resources/Editor/terminal.html also has light and dark palettes. MarkView/Views/DDESettingsView.swift provides a global interface text-size setting, while document text has its own slider. MarkView/Models/PanelLayout.swift already demonstrates independent window state with remembered defaults.

## Assumptions

Made by the AI where the request left a choice open; correct them in the discussion.

- A window means a MarkView workspace window; panels within that window share its theme.
- Customization in this release means choosing a preset and overriding its accent color; arbitrary palette editing and theme import are out of scope.
- Darcula-inspired is an original interpretation of the IntelliJ look, not a claim of an exact JetBrains theme.
- The existing interface and document text-size controls remain separate from theme settings.
- System remains a selectable appearance mode that follows macOS; explicitly selected presets have fixed light or dark appearances.

## Acceptance Criteria

- [ ] A theme picker in each workspace window offers System and four visually distinct presets: Darcula-inspired, Midnight, Graphite and Paper. System follows macOS; Paper is light; the others are dark. The existing theme toggle and keyboard shortcut open the picker.
- [ ] Selecting a preset immediately updates the active window’s native interface, editor, Markdown preview, discussion and terminal, including backgrounds, text, controls, syntax highlighting and selection states.
- [ ] Each window offers an accent-color override and a reset to the selected preset’s default. Changing either the preset or accent in one window does not change another open window.
- [ ] A restored window retains its theme and accent after closing and reopening the app. A new window starts with the most recently selected theme and the full collection of per-preset accent overrides (DEC-005), then can be customized independently.
- [ ] Existing users retain their current light or dark appearance on upgrade as Classic Dark or Classic Light until they choose System or a preset (DEC-004); the absent setting, today's default, is Classic Dark. Missing or invalid saved settings fall back to Classic Dark.
- [ ] Text, controls, focus indicators and selections remain legible in every preset. Theme changes preserve open documents, unsaved edits and panel state.
