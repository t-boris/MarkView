---
type: bug
id: BUG-002
title: "AI Tools toolbar menu (wand icon): several items do nothing and prompts arrive truncated in the AI terminal"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-09-26
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где именно вы видели обрезанный текст?
    why: "Так станет понятно, в чём причина: в записи в терминал или в лимите в 15 000 символов на документ."
    options:
      - label: В терминале
        text: Промпт, вставленный в AI-терминал, обрывается на середине
      - label: В документе
        text: В файл или документ записывается неполный результат
      - label: Не помню
        text: Точно не помню
    status: answered
    answer: В терминале. Промпт, вставленный в AI-терминал, обрывается на середине
  - id: BQ-2
    text: "Какие пункты меню у вас не сработали? Опишите, что происходило: ничего, ошибка, долгое ожидание и т.п."
    why: Нужно отличить пункты, которые молча ничего не делают, от задержки вставки (до 45 с) и от проблем Graph Creator.
    status: answered
    answer: Сам исследуй
  - id: BQ-3
    text: Какой AI-бэкенд был включён в терминале?
    why: Claude Code и Codex по-разному принимают bracketed paste, а обрезка зависит от того, как программа читает PTY.
    options:
      - label: Claude Code
        text: Claude Code
      - label: Codex
        text: Codex
      - label: Другой
        text: Другой или не знаю
    status: answered
    answer: Claude Code. Claude Code
  - id: BQ-4
    text: Промпт обрывается всегда примерно в одном и том же месте или каждый раз по-разному?
    why: Если в одном месте, значит, срабатывает фиксированный лимит. Если по-разному, это частичная запись в PTY.
    options:
      - label: Всегда одинаково
        text: Обрыв примерно в одном и том же месте
      - label: По-разному
        text: Место обрыва меняется от запуска к запуску
      - label: Не знаю
        text: Не обращал внимания
    status: answered
    answer: Не знаю. Не обращал внимания
  - id: BQ-5
    text: Какие пункты меню должны остаться? Решите сами или доверьте это исправляющему.
    why: В исходном описании просили проверить, какие пункты не нужны. Без этого решения нельзя убрать или отключить неподдерживаемые пункты.
    options:
      - label: Оставить все
        text: Только починить, ничего не удалять
      - label: Убрать неработающие
        text: Скрыть те, что нельзя быстро починить
      - label: Решу позже
        text: Сначала покажите список с их статусом
    status: answered
    answer: Решу позже. Сначала покажите список с их статусом
issue: "#22"
---

# AI Tools toolbar menu (wand icon): several items do nothing and prompts arrive truncated in the AI terminal

## Summary

AI Tools toolbar menu (wand icon): long analysis prompts pasted into the Claude Code AI terminal are cut off mid-text (confirmed by the user). The user also reports that several items do nothing and has delegated finding out which ones to the fixer (BQ-2). Code reading suggests these causes, none verified by running the app: TerminalSession.write() gives up at the first Darwin.write() that returns <=0 (for example EAGAIN on a full non-blocking PTY). That drops the rest of the prompt and the closing ESC[201~, and paste() then sends \r inside a bracketed paste that was never closed. activeDocumentContext() also cuts the active document to 15,000 chars without saying so. runAITool (WorkspaceManager.swift:2836) maps names through WorkspaceAITool(rawValue:) and returns silently on an unknown name or a nil prompt. Diagram tools with opensGraphCreator open the Graph Creator sheet instead of sending a prompt. Recursive Insight bypasses runAITool and needs an open folder. Items that seem to do nothing may be caused by the silent wait-for-quiet of up to 45 s, those silent returns, a Graph Creator sheet that doesn't appear, or the folder precondition. The fixer must also produce a per-item status list (BQ-5).

## Steps to reproduce

1. Open a workspace folder with Markdown files, open a .md file larger than 15k characters, and start Claude Code in the AI terminal.
2. Click the wand (AI tools) icon next to the theme toggle.
3. Choose Codebase Audit, Constructive Critic, Deep Research and Code Structure Map one at a time.
4. In the terminal, check that each pasted prompt ends with its closing instructions and is submitted exactly once. Repeat 2-3 times and note whether the cut point is the same each time.
5. Repeat while Claude Code is still printing output, to observe the wait-for-quiet delay (up to 45 s).
6. Choose each Diagrams item (System Architecture, Data Flow, Pipeline, Deployment, Sequence, Entity-Relationship). Check whether the Graph Creator sheet opens and whether its action sends a prompt.
7. Choose Recursive Insight with and without an open folder and record what visibly happens.
8. For each of the 11 items, confirm the name passed from AIToolsMenu matches a WorkspaceAITool raw value.

## Expected

Every visible item performs its action or gives visible feedback (progress, error, or a precondition message). Analysis prompts are pasted in full, closed with ESC[201~, and submitted exactly once. Document content is included in full or explicitly marked as truncated. A per-item status list is produced, and items are removed or disabled later based on it, following the user's decision.

## Actual

The prompt pasted into the Claude Code terminal stops mid-text (confirmed). The user reports that several items do nothing; which ones is unconfirmed and left to the fixer to determine.

## Environment

MarkView macOS app (SwiftUI + embedded PTY terminal), macOS Darwin 27.0.0, AI backend Claude Code. Build/branch unknown.

## Suspected code

- `MarkView/Models/TerminalSession.swift` — write() (~line 317) breaks on written <= 0, so EAGAIN/EINTR drops the remaining text and the ESC[201~ terminator. paste() then sends \r inside an unclosed paste. pasteWhenReady waits up to 45 s with no feedback.
- `MarkView/Models/WorkspaceManager.swift` — runAITool (line 2836) silently returns when WorkspaceAITool(rawValue:) is nil or aiPrompt() returns nil. Tools with opensGraphCreator go to presentGraphCreator instead of the terminal. activeDocumentContext(contentLimit: 15000) (~line 3508) truncates without a marker. startRecursiveInsight (~line 2094) requires an open folder.
- `MarkView/Views/ContentView.swift` — AIToolsMenu (lines 460-480) passes string names to runAITool. Each must match a WorkspaceAITool raw value. Recursive Insight bypasses runAITool.
- `MarkView/Models/AIPrompts.swift` — Long prompts plus up to 15k chars of document content exceed the PTY buffer capacity, which triggers partial writes.

## Likely causes

- Partial PTY write: EAGAIN/EINTR is treated as fatal, so the prompt is truncated and the bracketed paste is never closed.
- Silent 15,000-char truncation of the active document inside prompts.
- The 45 s wait-for-quiet has no feedback, so items look like they do nothing.
- Silent early returns in runAITool (name mismatch with WorkspaceAITool, or nil prompt).
- Diagrams items route to the Graph Creator sheet; if the sheet fails to present or its submit path is broken, nothing visible happens.
- Recursive Insight fails silently or only shows an alert when no folder is open.

## Missing information

- Per-item working/broken status, to be determined by the fixer through reproduction (the user delegated this).
- Whether the cut point is a fixed length or varies between runs (to be checked during reproduction).
- Build/branch.

## Clarifications

**BQ-1** Где именно вы видели обрезанный текст?
→ В терминале. Промпт, вставленный в AI-терминал, обрывается на середине

**BQ-3** Какой AI-бэкенд был включён в терминале?
→ Claude Code. Claude Code

**BQ-4** Промпт обрывается всегда примерно в одном и том же месте или каждый раз по-разному?
→ Не знаю. Не обращал внимания

**BQ-5** Какие пункты меню должны остаться? Решите сами или доверьте это исправляющему.
→ Решу позже. Сначала покажите список с их статусом

**BQ-2** Какие пункты меню у вас не сработали? Опишите, что происходило: ничего, ошибка, долгое ожидание и т.п.
→ Сам исследуй

## Original description

Перепроверь вот этот функционал с AI-ный функционал, который у нас справа наверху, ну рядом с изменением темы находится вот эта кнопка. Там довольно много подпунктов в этом меню, и многие из них вообще не работают. Поэтому почини это немедленно. Причем перепроверь, какие работают, какие не нужны, какие не нужны, и проверь, как они вообще работают. Потому что я видел, он, допустим, вставляет нам обрезанный текст.
