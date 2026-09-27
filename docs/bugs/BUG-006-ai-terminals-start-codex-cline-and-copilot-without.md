---
type: bug
id: BUG-006
title: AI terminals start Codex, Cline and Copilot without full-access (skip-permissions) flags; only Claude Code bypasses prompts
status: fixed
branch: fix/ai-terminal-resume-full-access
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Какие CLI у вас сейчас спрашивают разрешения при запуске из MarkView?
    why: В коде флаг обхода разрешений есть только у Claude. Нужно понять, затронут ли Claude тоже или только остальные CLI.
    options:
      - label: Кроме Claude
        text: Codex, Copilot, Cline
      - label: Все, включая Claude
        text: Claude тоже спрашивает
      - label: Только Codex
        text: Проблема только у Codex
    status: answered
    answer: Кроме Claude. Codex, Copilot, Cline
  - id: BQ-2
    text: Полный доступ должен включаться всегда или через настройку?
    why: Запуск агентов без подтверждений небезопасен, поэтому от ответа зависит, нужен ли переключатель в настройках.
    options:
      - label: Всегда
        text: Жёстко для всех CLI, как сейчас у Claude
      - label: Настройка
        text: Переключатель, по умолчанию включён
      - label: Настройка, выкл.
        text: Переключатель, по умолчанию выключен
    status: answered
    answer: Всегда. Жёстко для всех CLI, как сейчас у Claude
issue: "#32"
---

# AI terminals start Codex, Cline and Copilot without full-access (skip-permissions) flags; only Claude Code bypasses prompts

## Summary

MarkView's AI terminals start Codex, Cline and Copilot in their default approval mode. WorkspaceManager.startupCommand(for:) (lines 3096–3105) appends `--dangerously-skip-permissions` only for `.claude`; `.codex, .cline, .copilot` return the bare binary plus model args. The user confirmed that all three prompt for permissions. Decision (BQ-2): full access is always on and hard-coded for every CLI, like Claude, with no setting. BUG-005 edits the same function (resume flags), so the two fixes must be coordinated.

## Steps to reproduce

1. Open a workspace in MarkView.
2. In the AI panel, open a Codex terminal.
3. Ask the agent to edit a file or run a shell command.
4. Observe the approval prompt.
5. Repeat with the Copilot and Cline terminals: they show the same prompts.
6. Open a Claude Code terminal: it runs `update && claude ... --dangerously-skip-permissions` and does not prompt.

## Expected

Every AI terminal (Claude Code, Codex, Cline, Copilot) always starts its CLI in full-access / auto-approve mode with no permission prompts. There is no user setting.

## Actual

Only .claude gets --dangerously-skip-permissions. Codex, Cline and Copilot start with just the binary and model args and prompt for each edit or command.

## Environment

MarkView macOS app (Darwin 27.0.0), AI panel terminals. Affected: Codex, Copilot, Cline (user-confirmed). Installed CLI versions unknown.

## Suspected code

- `MarkView/Models/WorkspaceManager.swift` — startupCommand(for:) (3096–3105): the switch adds the bypass flag only in the .claude case; `.codex, .cline, .copilot: return run`.
- `MarkView/Models/CLICompletion.swift` — Holds per-tool CLI knowledge (binaryName, modelArgs). This is the natural home for a per-tool fullAccessArgs property (inference).
- `docs/architecture/security.md` — Should record the decision to always run all agents without approvals.

## Likely causes

- The full-access flag is hard-coded for Claude only in startupCommand(for:); no per-tool equivalent was ever added.
- Flag syntax differs per CLI and changes between versions (external fact, needs checking). Candidates: Codex `--dangerously-bypass-approvals-and-sandbox` / `--yolo`, Copilot `--allow-all-tools` / `--yolo`, Cline auto-approve/yolo equivalent. There is no shared per-tool abstraction for them.

## Missing information

- Exact full-access flags supported by the installed Codex, Copilot and Cline versions. The developer can check them with `<cli> --help`; this does not block starting the fix.
- Merge order and coordination with the BUG-005 change to the same function.

## Clarifications

**BQ-1** Какие CLI у вас сейчас спрашивают разрешения при запуске из MarkView?
→ Кроме Claude. Codex, Copilot, Cline

**BQ-2** Полный доступ должен включаться всегда или через настройку?
→ Всегда. Жёстко для всех CLI, как сейчас у Claude

## Original description

Когда мы стартуем наш CLI, там Codex, Cloud Code, Copilot или CLI, нам нужно его стартовать так, чтобы Permission All Access был.
