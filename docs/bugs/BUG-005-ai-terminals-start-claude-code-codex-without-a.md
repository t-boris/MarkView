---
type: bug
id: BUG-005
title: AI terminals start Claude Code/Codex without a resume/continue flag, so the previous session is not restored
status: fixed
branch: fix/ai-terminal-resume-full-access
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: В каких случаях должна возобновляться последняя сессия?
    why: "От этого зависит, куда добавлять флаг: при открытии терминала, при перезапуске или при повторном запуске приложения."
    options:
      - label: Всегда
        text: При любом запуске терминала
      - label: Только restart
        text: Только при перезапуске существующего терминала
      - label: После перезапуска приложения
        text: Восстанавливать терминалы и их сессии после повторного запуска MarkView
    status: answered
    answer: После перезапуска приложения. Восстанавливать терминалы и их сессии после повторного запуска MarkView
  - id: BQ-2
    text: Возобновлять автоматически последнюю сессию или показывать выбор?
    why: Выбор между `--continue` и интерактивным `--resume` (пикером) или отдельной кнопкой.
    options:
      - label: Авто
        text: Сразу последняя сессия
      - label: Выбор
        text: Пикер сессий CLI
      - label: Кнопка
        text: Отдельное действие «Продолжить» рядом с «Новый»
    status: answered
    answer: Авто. Сразу последняя сессия
  - id: BQ-3
    text: Для каких инструментов это нужно?
    why: У каждого CLI свой синтаксис resume; для Cline и Copilot его может не быть.
    options:
      - label: Claude + Codex
        text: Только Claude Code и Codex
      - label: Все
        text: Все поддерживаемые CLI
    status: answered
    answer: Все. Все поддерживаемые CLI
  - id: BQ-4
    text: После перезапуска MarkView терминалы должны открываться сами, или достаточно добавить resume при ручном открытии терминала?
    why: Сейчас терминалы между запусками, похоже, не сохраняются. От ответа зависит, нужно ли реализовывать восстановление состояния терминалов.
    options:
      - label: Автоматически
        text: Автоматически открывать те же AI-терминалы с resume
      - label: Только resume
        text: Терминалы открываю вручную, но с продолжением последней сессии
    status: answered
    answer: Settled by the clarifications.
issue: "#30"
---

# AI terminals start Claude Code/Codex without a resume/continue flag, so the previous session is not restored

## Summary

After MarkView is relaunched, AI terminals (Claude Code, Codex, Cline, Copilot) are not restored, and their previous CLI conversations are not resumed. When an AI terminal is opened, MarkView types a startup command with no resume/continue argument, so every launch starts a fresh conversation. Clarified scope: all supported CLIs. Trigger: app relaunch. Expected behaviour: reopen the terminals automatically and resume the most recent session without showing a picker (BQ-1, BQ-2, BQ-3). A quick search found no code that saves or restores open AI terminals between launches. This is an inference, not an exhaustive check. The fix probably needs two parts: persisting and restoring terminal state, and a resume argument for each tool.

## Steps to reproduce

1. Open a workspace in MarkView.
2. In the AI panel, open a Claude Code terminal and have a short conversation.
3. Quit MarkView and launch it again with the same workspace.
4. Observe that the AI terminal is not reopened. If you reopen it manually, it starts a new, empty session.
5. Repeat with Codex, Cline and Copilot.

## Expected

On relaunch, MarkView automatically reopens the AI terminals that were open for the workspace (same tool/profile). Each terminal starts its CLI with that tool's resume option (e.g. `claude --continue`, `codex resume --last`, plus equivalents for Cline and Copilot), with no picker, and continues the most recent conversation for the workspace directory. If there is no previous session, the CLI falls back to a fresh session without errors.

## Actual

On relaunch, no AI terminals are restored. A manually opened terminal runs `claude update && claude <model> --dangerously-skip-permissions`, or `<tool> <model>` for the other CLIs, with no resume argument, so a new empty session starts. The user can only get the previous discussion back by resuming it manually in the CLI.

## Environment

MarkView macOS app (Darwin 27.0.0); AI panel terminals for Claude Code, Codex, Cline and Copilot. CLI versions unknown.

## Suspected code

- `MarkView/Models/WorkspaceManager.swift` — startupCommand(for:) (~3096) builds startup commands with no per-tool resume argument. openAITerminal (~3122) and restartAITerminal (~3150) use it. No logic was found that reopens AI terminals at app launch.
- `MarkView/Models/TerminalSession.swift` — Stores startupCommand and types it into the shell (~418). restart() (~288–301) reuses the same command. Session state does not appear to be persisted.
- `MarkView/Models/CLICompletion.swift` — Holds per-tool CLI knowledge (binaryName, modelArgs); the natural place to add a per-tool resume argument.

## Likely causes

- Resume was never implemented: startupCommand(for:) has no per-tool resume argument.
- Inference: the list of open AI terminals (profile, workspace) is not persisted, so nothing is restored after relaunch.
- Resume syntax differs per tool (claude --continue, codex resume --last); the syntax for Cline and Copilot is unverified.
- Inference: a resume flag may fail or open an interactive picker when no previous session exists.

## Missing information

- Exact resume syntax and no-session behaviour for the installed Cline and Copilot CLI versions (external fact, to verify).
- Whether first open, manual restart and profile switch should also resume (only app relaunch is confirmed).
- Installed CLI versions.

## Clarifications

**BQ-3** Для каких инструментов это нужно?
→ Все. Все поддерживаемые CLI

**BQ-1** В каких случаях должна возобновляться последняя сессия?
→ После перезапуска приложения. Восстанавливать терминалы и их сессии после повторного запуска MarkView

**BQ-2** Возобновлять автоматически последнюю сессию или показывать выбор?
→ Авто. Сразу последняя сессия

## Original description

Когда мы стартуем какой-нибудь Cloud Code или кодекс, или что-либо другое, мы должны задавать параметры resume, чтобы он вспомнил предыдущие, ну последние, последние discussion.
