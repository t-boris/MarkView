---
type: bug
id: BUG-015
title: X-Ray file outlining times out after 300 seconds and reports a misleading read error
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: "Когда появился тайм-аут: при первом анализе, повторном анализе, после изменений или при открытии деталей index.html?"
    why: Это поможет проверить, почему кэш не был использован и какой путь запускает долгий вызов.
    options:
      - label: Первый запуск
        text: Первый анализ проекта
      - label: Повторный анализ
        text: Повторный анализ без изменений
      - label: После изменения
        text: После изменения файлов
      - label: Детали файла
        text: При открытии деталей файла
    status: answered
    answer: Повторный анализ. Повторный анализ без изменений
  - id: BQ-2
    text: Что показывал прогресс X-Ray в течение этих пяти минут?
    why: Это позволит отделить проблему длительного анализа от проблемы отображения прогресса.
    options:
      - label: Шаг и файл
        text: Показывались шаг «Reading contents» и текущий файл
      - label: Только шаг
        text: Показывался шаг, но не текущий файл
      - label: Без прогресса
        text: Прогресс не менялся
      - label: Не помню
        text: Не помню
    status: answered
    answer: Шаг и файл. Показывались шаг «Reading contents» и текущий файл
  - id: BQ-3
    text: До повторного анализа X-Ray уже показывал детали содержимого index.html?
    why: Это поможет понять, должен ли был существовать готовый к повторному использованию outline.
    options:
      - label: Да, детали были
        text: До повторного анализа X-Ray уже показывал детали содержимого index.html.
      - label: Нет, деталей не было
        text: До повторного анализа деталей содержимого index.html не было.
      - label: Не помню
        text: Не помню, появлялись ли детали содержимого index.html.
    status: answered
    answer: Не помню. Не помню, появлялись ли детали содержимого index.html.
issue: "#69"
---

# X-Ray file outlining times out after 300 seconds and reports a misleading read error

## Summary

Repeat X-Ray analysis of an unchanged project can spend 300 seconds outlining index.html. Progress shows “Reading contents” and the current file, then reports an assistant timeout as a file-read error. A per-file outline cache exists, but the available evidence does not establish whether index.html had a reusable entry.

## Steps to reproduce

1. Open a project containing index.html in X-Ray’s Logical view and run analysis.
2. Without changing project files, run X-Ray analysis again.
3. Observe the “Reading contents” step and current file while outlining runs.
4. Check whether index.html reaches the 300-second Codex timeout and displays “Could not read index.html: Codex did not finish within 300 s.”

## Expected

Reuse a valid outline for unchanged index.html and show available project structure promptly. If outlining times out, identify it as an outline timeout and keep progress aligned with the work underway.

## Actual

On a repeat analysis with no project file changes, X-Ray showed “Reading contents” and the current file. After 300 seconds, it displayed “Could not read index.html: Codex did not finish within 300 s.” The message describes an assistant timeout as a file-read failure.

## Reproduction and root cause

The shipping `MarkView/Resources/Editor/index.html` is 1,649 lines. Before the fix, `needsAssistant(language: "html", lines: 1649)` returned true while the local declaration outliner returned no outline for HTML. A regression check reproduced both conditions. Without a successful per-file cache entry, opening X-Ray and then repeating analysis selected the same file for a full AI call again; a failed or timed-out call wrote no outline to reuse. The request had a 300-second limit. After the file had been read successfully, its catch block still reported “Could not read.”

The cache for that exact file in the reported session was unavailable, so its specific invalidation cause cannot be established. A current valid cache entry for this repository's index.html confirms that successful outlines are reused when their file signature and output language match.

## Resolution

Scanning and repeat analysis now load valid cached outlines and build missing file outlines locally: declarations for code of any length, headings for Markdown, and identified regions or headings for HTML. This first pass makes no per-file AI calls. The file details panel offers a deeper AI outline on demand, using the configured X-Ray model at low effort; different files can run concurrently. Its limit is 60 seconds, and a failure says “Could not outline,” leaving the local outline visible and offering retry. The visible analysis step is now “Indexing file contents.”

The focused check uses the shipping index.html, a long Swift fixture, Markdown headings, cache reuse and invalidation, and timeout wording. The Debug build passes.

## Environment

MarkView on macOS 13+ using X-Ray and the Codex CLI. The failure occurred during repeat analysis without project file changes. App and macOS versions, selected model, project size, index.html size, output-language setting, and prior outline-cache state are unknown.

## Suspected code

- `MarkView/Models/ArchitectureStore.swift` — analyze starts the “Reading contents” phase; buildOutlines loads cached outlines and selects missing files; outlineWithAssistant sets the timeout and formats request failures as read errors.
- `MarkView/Models/XRayContent.swift` — Defines assistant eligibility, selection and concurrency limits, prompt clipping, and cache validation using file size and modification time.
- `MarkView/Models/CLICompletion.swift` — Enforces the request timeout and produces the observed Codex timeout message.

## Likely causes

- Confirmed: ArchitectureStore sets a 300-second limit for each assistant outline request. Its error handler labels request failures “Could not read,” although file loading has already succeeded.
- Unconfirmed: index.html was outlined again because no reusable outline was available. The cache may have been absent, failed its file-signature check, or been excluded after an output-language change.
- Up to 60 eligible files are selected per analysis, longest first, with four assistant requests in parallel. A slow request can keep the “Reading contents” phase active for five minutes.

## Remaining original-report detail

- Whether the first analysis produced a valid outline for index.html is unknown; the user does not remember seeing its content details.
- The prior cache entry and file signature would be needed to determine why index.html was selected in that specific session.
- The app version, selected model, project size, and output-language setting in that session remain unknown.

## Clarifications

**BQ-1** Когда появился тайм-аут: при первом анализе, повторном анализе, после изменений или при открытии деталей index.html?
→ Повторный анализ. Повторный анализ без изменений

**BQ-2** Что показывал прогресс X-Ray в течение этих пяти минут?
→ Шаг и файл. Показывались шаг «Reading contents» и текущий файл

**BQ-3** До повторного анализа X-Ray уже показывал детали содержимого index.html?
→ Не помню. Не помню, появлялись ли детали содержимого index.html.

**Follow-up direction (2026-09-29)** Consider model choice, concurrent calls, and caching as part of the fix.

## Original description

Could not read index.html: Codex did not finish within 300 s.
Слушай, разберись с анализом в X-Ray. Вот он в какой-то момент, например, говорит, не могу прочесть HTML, индекс HTML. Что это значит? Почему он должен все перечитывать? Нет ли у нас каких-то более простых способов, то есть проверять на более высоком уровне или делать какие-то быстрые просмотры более простой моделью файлов. Всех в принципе, а потом из этого всего строить на каждом уровне более сложные конструкции, кэшить. Давай поговорим о том, потому что действительно 5 минут ждать, пока он просмотрит весь проект, это дичайше долго. Либо надо иметь какой-то очень интересный прогресс и в процессе прогресса обновлять X-Ray.
