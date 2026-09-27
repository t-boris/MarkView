---
type: bug
id: BUG-002
title: "AI Tools toolbar menu (wand icon): several items do nothing and prompts arrive truncated in the AI terminal"
status: fixed
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

AI Tools toolbar menu (wand icon): long analysis prompts pasted into the Claude Code AI terminal are cut off mid-text (confirmed by the user). The user also reports that several items do nothing and has delegated finding which ones (BQ-2) and producing a per-item status list (BQ-5) to the fixer. The suspected causes come from reading the code and have not been verified by running the app. TerminalSession.write() stops at the first Darwin.write() that returns <=0 (EAGAIN/EINTR on a full PTY), which drops the rest of the prompt and the closing ESC[201~, and the \r is then sent inside an unclosed bracketed paste. activeDocumentContext() also truncates the document to 15,000 chars without a marker. Items may look dead because of the silent wait-for-quiet (up to 45 s), silent early returns in runAITool, Diagram items opening the Graph Creator sheet instead of sending a prompt, or Recursive Insight requiring an open folder.

## Steps to reproduce

1. Open a workspace folder with Markdown files, open a .md file larger than 15k characters, and start Claude Code in the AI terminal.
2. Click the wand (AI tools) icon next to the theme toggle.
3. Choose Codebase Audit, Constructive Critic, Deep Research and Code Structure Map one at a time.
4. In the terminal, check that each pasted prompt ends with its closing instructions and is submitted exactly once. Repeat 2-3 times and note whether the cut point stays the same.
5. Repeat while Claude Code is still printing output to observe the wait-for-quiet delay (up to 45 s).
6. Choose each Diagrams item (System Architecture, Data Flow, Pipeline, Deployment, Sequence, Entity-Relationship). Check whether the Graph Creator sheet opens and whether its action sends a prompt.
7. Choose Recursive Insight with and without an open folder and record what visibly happens.
8. For each of the 11 items, confirm the name passed from AIToolsMenu matches a WorkspaceAITool raw value, and record the per-item status.

## Expected

Every visible item performs its action or gives visible feedback (progress, error, or precondition message). Prompts are pasted in full, closed with ESC[201~, and submitted exactly once. Document content is included in full or explicitly marked as truncated. A per-item status list is produced; items are removed or disabled later by the user's decision.

## Actual

The prompt pasted into the Claude Code terminal stops mid-text (confirmed). The user reports that several items do nothing; which ones is unconfirmed and delegated to the fixer.

## Environment

MarkView macOS app (SwiftUI + embedded PTY terminal), macOS Darwin 27.0.0, AI backend Claude Code. Build/branch unknown.

## Suspected code

- `MarkView/Models/TerminalSession.swift` — write() (~line 317) breaks on written <= 0, so EAGAIN/EINTR drops the remaining text and the ESC[201~ terminator. paste() then sends \r inside an unclosed paste. pasteWhenReady waits up to 45 s with no feedback.
- `MarkView/Models/WorkspaceManager.swift` — runAITool (line 2836) returns silently when WorkspaceAITool(rawValue:) is nil or aiPrompt() is nil. opensGraphCreator tools go to presentGraphCreator. activeDocumentContext(contentLimit: 15000) truncates without a marker. startRecursiveInsight requires an open folder.
- `MarkView/Views/ContentView.swift` — AIToolsMenu (lines 460-480) passes string names that must match WorkspaceAITool raw values. Recursive Insight bypasses runAITool.
- `MarkView/Models/AIPrompts.swift` — Long prompts plus up to 15k chars of document content exceed the PTY buffer, which triggers partial writes.

## Likely causes

- Partial PTY write: EAGAIN/EINTR is treated as fatal, so the prompt is truncated and the bracketed paste is never closed.
- The active document is silently truncated to 15,000 chars.
- The 45 s wait-for-quiet gives no feedback.
- runAITool returns early without any message (name mismatch or nil prompt).
- The Graph Creator sheet fails to present, or its submit path is broken.
- Recursive Insight fails silently without an open folder.

## Missing information

- Per-item working/broken status (the fixer determines this by reproducing).
- Whether the cut point is fixed or varies between runs (to be checked during reproduction).
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

## Resolution (2026-09-26, 2.17.2)

**Reproduced** with a standalone PTY harness that uses the exact `TerminalSession.write()` loop on a
non-blocking master, as the app does:

- slow raw-mode reader: the loop accepted **1022 of 20275 bytes**, then `write` returned `EAGAIN`
  (errno 35); the reader got 1022 bytes and no `ESC[201~`;
- real Claude Code 2.1.283: again **1022 of 20275 bytes**, `EAGAIN`, on every run (so the cut point
  is fixed at about 1 KB, BQ-4). On screen Claude Code showed `[Pasted text #1 +1 lines]` and did
  nothing more: the paste was never closed, so the `\r` sent 0.25 s later was taken as pasted text,
  not Enter.

Claude Code printed no output for 15 s at an idle prompt, so the wait-for-quiet delivers after ~2 s;
the 45 s fallback is not what made items look dead.

**Root cause.** macOS's terminal driver takes only about 1 KB of input at a time. `TerminalSession`
sets the PTY master to `O_NONBLOCK`, and `write()` stopped at the first `write` that returned ≤ 0,
dropping everything after the first ~1 KB, including the closing `ESC[201~`. Every AI Tools
prompt is longer than that (Codebase Audit 5.2 KB, Code Structure Map ~2.5 KB, Critic/Research and
the Graph Creator prompts include documents), so every item pasted a fragment and was never
submitted. This is both reported symptoms: truncated text and "the item does nothing".

**Fix.**

- `MarkView/Models/PTYWriter.swift` (new): input to the PTY is queued; what the PTY cannot take yet
  is sent from a `DispatchSourceWrite` as the program reads, in order, retrying `EINTR`. The main
  thread never blocks, and an Enter queued after a paste always lands after `ESC[201~`. Input for an
  exited program is dropped.
- `TerminalSession.write()` goes through it (it is created with the PTY and cancelled when the PTY
  closes). This also fixes every other long paste: prompt buttons, graph edits, intake, pasted paths.
- By the reporter's decision, documents are pasted whole: the 15,000-character limit in
  `WorkspaceManager.activeDocumentContext` and the Graph Creator's 3,000-per-file / 15,000-total
  limits are removed.

**Verified.**

- `tools/tests/pty-writer-tests.sh` (new, real PTY with a slow reader): a 20 KB paste + Enter arrives
  byte for byte, ending `ESC[201~\r`; 2000 small writes keep their order; `write` returns at once
  while the PTY is full; cancel and an exited program are handled. All pass.
- Real Claude Code, app paste sequence (`ESC[200~` + text + `ESC[201~`, Enter 0.25 s later): the old
  loop left a fragment unsubmitted; with `PTYWriter` the whole 20 KB paste arrived and was
  submitted. A real Constructive Critic prompt (3.6 KB, shaped as `aiPrompt(.critic)` builds it)
  was taken and Claude Code wrote `review-payments.md`.
- `tools/tests/terminal-link-tests.sh` (compiles the real `TerminalSession`): 82 + 9 checks pass.
  Debug build succeeds.
- Not done: clicking through the menu in the installed app (the app is not restarted by the fixer).

### Per-item status (BQ-2, BQ-5)

All 11 names in `AIToolsMenu` match a `WorkspaceAITool` raw value; `runAITool` never returns early
for them.

| Item | What it does | Before | After |
|------|--------------|--------|-------|
| System Architecture, Data Flow, Pipeline, Deployment, Sequence, Entity-Relationship | Open the Graph Creator sheet with the type preselected; Generate sends the prompt with the selected `.md` files | Sheet opened; prompt cut to ~1 KB, never submitted | Prompt arrives whole and is submitted |
| Constructive Critic | Review of the open document (or the workspace) into `review-<name>.md` | Cut, not submitted | Works (verified with Claude Code) |
| Deep Research | Research report on the open document into `research-<name>.md` | Cut, not submitted | Arrives whole (same path as Critic) |
| Codebase Audit | 5.2 KB audit prompt | Cut, not submitted | Arrives whole |
| Code Structure Map | Writes `code-structure-map.md` | Cut, not submitted | Arrives whole |
| Recursive Insight | Opens an `.insight` tab; does not use the terminal | Not affected by this bug | Unchanged; disabled without a folder with `.md` files, alerts when the CLI or index is missing |

Remaining, not changed (needs the reporter's decision):

- Diagrams items are enabled without an open folder (single-file mode). The sheet then lists no
  files and Generate stays disabled with no explanation. Recursive Insight is disabled in that case.
- The Graph Creator selects all `.md` files when no file is open. Now that documents are pasted
  whole, that can be a very large paste in a big folder.
