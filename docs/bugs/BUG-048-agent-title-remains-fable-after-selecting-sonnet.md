---
type: bug
id: BUG-048
title: Agent title remains Fable after selecting Sonnet
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: "Какая версия MarkView установлена и где именно вы выбрали Sonnet: в меню Model приложения или внутри самого Claude Code? Сессия локальная или удалённая?"
    why: В коде уже есть исправление похожего случая; версия и способ переключения помогут отличить старую сборку от другого сценария.
    status: answered
    answer: 4.65.4
  - id: BQ-2
    text: Была ли панель Agents открыта в момент переключения модели?
    why: В документации описана потеря переключения именно при скрытой панели Agents.
    options:
      - label: Agents открыт
        text: При выборе Sonnet панель Agents с заголовком агента была видна.
      - label: Другая вкладка
        text: Выбрал Sonnet на другой вкладке, затем открыл Agents.
      - label: Не помню
        text: Не помню, какая панель была открыта.
    status: answered
    answer: Agents открыт. При выборе Sonnet панель Agents с заголовком агента была видна.
issue: "#239"
ready_to_fix: true
---

# Agent title remains Fable after selecting Sonnet

## Summary

BUG-048 (first filed as BUG-045; renumbered because two bugs got that number): the Claude Code coding agent's title remains Fable after Sonnet is selected through /model. Current source and v4.65.4 support a launch-state/runtime-state synchronization gap. The user has approved fixing the affected session's title without restarting the conversation; enough evidence exists to start. Medium severity: misleading model information, with no established data loss, security impact, outage, or broken coding flow. BQ-1 is resolved for version and selection method; its local/remote subquestion remains unknown but non-blocking.

## Steps to reproduce

1. Run MarkView 4.65.4 and open a workspace containing a Claude Code coding terminal whose Agents title identifies Fable.
2. Keep Agents open with that terminal's title visible.
3. Inside the terminal, run /model and select Sonnet.
4. Observe that the title still identifies Fable.
5. Verification extension, not confirmed in the report: capture the CLI confirmation, send a prompt, and check the title again after the assistant reply.
6. Regression verification: reopen Agents and repeat with multiple terminals in the same workspace; confirm correct session targeting and no unintended conversation restart.

## Expected

User-approved scope: after a confirmed in-session model change, update the affected agent's title to reflect its selected model without restarting the conversation. Preserve terminal identity and update only the correct session when multiple agents share a workspace. Reopening Agents must not restart the conversation merely because runtime selection differs from launch preferences. A dedicated model picker inside Agents is a separate enhancement and is outside this fix.

## Actual

User-observed: in MarkView 4.65.4, selecting Sonnet through /model inside the Claude Code coding terminal leaves the visible Agents title showing “CloudCode.fable”. CLI selection confirmation and the model used for a subsequent reply have not been independently verified. Agents has no dedicated per-agent model picker.

## Environment

User-confirmed: MarkView 4.65.4, Claude Code coding terminal in Agents, panel and title visible, Sonnet selected using /model. macOS application; exact macOS and Claude Code versions and local versus remote execution remain unknown. Current source and relevant v4.65.4 title/reconciliation paths were inspected. No BUG-045 image attachment was found in the repository. No runtime reproduction was performed.

## Cause

The tab title and the model MarkView remembers come from the launch (`TerminalSession.model`, set at launch and relaunch) and from preferences.
`/model` inside Claude Code changes neither: the tab kept the launch model and the next start used the old preference (Fable) again. The CLI does
record the truth: `/model` writes a `<local-command-stdout>Set model to …` entry and each reply carries `message.model`. Two more findings: the
panel's observer follows only the project's own assistant, and the activity parser counted the CLI's own command entries as work.

## Resolution

- `ClaudeSessionModel` reads the model the session runs from the log of the terminal's own process (not subagents, not placeholders, only lines
  since the shell started). `WorkspaceManager.claudeModelReported` renames that tab and remembers the model for the project and for the defaults
  (projects without a choice use the last used model). Nothing restarts; a model remembered elsewhere never interrupts a running conversation
  (`aiModelChanged` restarts only for a pick made in MarkView after the agent started, `ModelPickLog`).
- Scope grew with Boris's request to switch the model inside the Agents tab: `AgentModelMenu` in the Agents header. Claude Code gets `/model <alias>`
  pasted and submitted (live, no restart, off while the agent works); other assistants are relaunched with the model, continuing the conversation where
  the CLI can resume.
- `AgentActivityParser.claude` skips the CLI's own command entries, so the agent waits for the user after `/model`.
- Version 5.1.0.

## Verification

- `tools/tests/claude-session-model-tests.sh` (25 checks), `agent-activity-tests.sh` (new /model checks), `project-ai-choice-tests.sh`; Debug build.
- Live in a scratch copy of the Debug build with stand-in CLIs (Claude, Copilot, Codex): the header pick keeps the agent process, the tab and the
  remembered model follow, the next start uses the remembered model, repeated picks work, Copilot and Codex relaunch with their own model flags.
- Against the real Claude Code 2.1.317 in a pty: a pasted `/model sonnet` plus Enter is accepted and answered `Set model to Sonnet 5.5 …`.
- Not verified: a real MarkView window with a real Claude Code session end to end; Cline and Antigravity; remote agents (out of scope).

## Suspected code

- `MarkView/Models/TerminalSession.swift:83` — model explicitly records the launch model. Initialization and restart assign model and title; the inspected bridge has no runtime-model update handler.
- `MarkView/Models/WorkspaceManager.swift:4036` — terminalTitle derives its model suffix from chosenModel, which reads application preferences. relaunch updates both title and launch metadata.
- `MarkView/Models/WorkspaceManager.swift:4182` — aiModelChanged restarts the active local terminal when launch metadata differs from preferences. It cannot detect /model when those values remain unchanged; changing model metadata alone could introduce an unintended restart.
- `MarkView/Views/TerminalView.swift:218` — Panel appearance and preference notifications trigger reconciliation, rather than observing the CLI's current model.
- `MarkView/Views/TerminalView.swift:288` — Agents controls provide creation, dictation, stop and restart, with no dedicated per-agent model picker.
- `MarkView/Views/ContentView.swift:944` — The general toolbar picker edits application/project preferences. It is not a dedicated model control inside Agents, although reconciliation can apply those preferences to the active local terminal.
- `MarkView/Models/LifecycleCapture.swift:9` — AgentModelProbe reads execution-model evidence from Claude assistant logs for lifecycle capture, not title synchronization. Workspace/time matching does not establish exact terminal identity or immediate selection state.
- `tasks/todo.md:112` — The 4.63.2 fix documents reconciliation after application-picker changes while Agents was hidden; it does not cover this visible-panel /model scenario.

## Likely causes

- Source-supported likely cause: the title reflects application-selected launch preferences rather than the CLI's current in-session selection.
- The inspected terminal bridge has no runtime-model update message connecting /model changes to the title.
- Preference reconciliation compares launch metadata with application preferences; both can remain unchanged after /model.
- The documented hidden-panel fix handles application preference changes, not the reported in-session selection while Agents is visible.

## Missing information

- Runtime verification: capture the CLI selection confirmation, then send a prompt and check the title after the reply. Selected model and actual execution evidence must be distinguished.
- Exact macOS and Claude Code versions, and whether the affected session is local or remote. These gaps do not block starting the fix.
- Implementation investigation: identify an authoritative model-state source tied to the exact terminal, including concurrent sessions in one workspace and remote execution.
- Implementation decision: separate runtime selection from launch preferences, or define their synchronization explicitly, so existing preference reconciliation does not cause unintended restarts.
- The exact reported label “CloudCode.fable” has no supporting screenshot; inspected title generation uses “Claude Code · <model>”. Preserve the user's wording without treating its spelling or Fable's model identity as independently verified.

## Clarifications

**BQ-2** Была ли панель Agents открыта в момент переключения модели?
→ Agents открыт. При выборе Sonnet панель Agents с заголовком агента была видна.

**BQ-1** Какая версия MarkView установлена и где именно вы выбрали Sonnet: в меню Model приложения или внутри самого Claude Code? Сессия локальная или удалённая?
→ 4.65.4

## Discussion

### Boris Tsekinovsky · 2026-11-03

Я проверял версию 4.65.4

### AI · 2026-11-03

Версия 4.65.4 уточняет картину: в исходниках её тега уже есть исправление обновления модели при открытии Agents. Вы также подтвердили, что панель была видна — поэтому прежняя причина со скрытой панелью не объясняет ваш случай напрямую. Возможна другая ошибка, но причина пока не установлена; фактически используемая модель тоже не проверена. Прикреплённых изображений в отчёте нет.

Уточните, пожалуйста: Sonnet выбирали в меню Model самого MarkView или командой /model внутри Claude Code? Сессия была локальной или удалённой? Это определяет ожидаемый путь обновления: текущий обработчик MarkView перезапускает и переименовывает только активного локального агента.

Пока этих уточнений не хватает для передачи в разработку. Статус отчёта не меняю.

### Boris Tsekinovsky · 2026-11-03

Командой /model… Может добавить переключение модели через UI?

### AI · 2026-11-03

Теперь сценарий понятнее: в 4.65.4 модель переключали командой `/model` внутри Claude Code. Это меняет направление проверки: речь о синхронизации заголовка после команды CLI, а не о переключателе MarkView. По коду заголовок отражает модель запуска; подтверждения фактически работающей модели пока нет. Изображений для BUG-045 не найдено.

Переключение через UI уже есть, в том числе в теге 4.65.4: меню ассистента с иконкой процессора в верхней панели → Model. Для активного локального агента этот путь предусматривает перезапуск и обновление заголовка. Это отличается от переключения внутри текущего сеанса через `/model`.

Предлагаю сохранить цель BUG-045: заголовок должен отражать модель после `/model`; удобство существующего UI можно обсудить отдельно. Синхронизация точнее решает исходную проблему, но требует надёжного способа узнать текущую модель CLI.

Какое поведение вы хотите: обновлять заголовок после `/model` или достаточно сделать существующий UI заметнее, с учётом перезапуска агента? Пока цель исправления не выбрана, передавать отчёт в разработку рано. Статус не меняю.

### Boris Tsekinovsky · 2026-11-03

You are wrong. There is no model switch in agents tab. We do have the switch for main agent… Not the one we are using to code

### AI · 2026-11-03

Вы правы: я смешал общий переключатель модели с управлением конкретным агентом для разработки. Извините. Вывод отчёта о том, что дело только в заметности существующего управления, необоснован.

Перепроверил текущий код и тег v4.65.4: во вкладке Agents отдельного переключателя модели нет. При этом общий выбор связан с активным локальным терминалом через `aiModelChanged()` и может перезапускать его — поэтому технически эти настройки не полностью независимы. Заголовок хранит модель запуска; обновления после `/model` в проверенном пути нет. Вложений для BUG-045 не найдено.

Теперь разделяю две задачи: исходный баг — устаревший заголовок после `/model`; ваше предложение — добавить управление моделью конкретного агента непосредственно в Agents. Второе нельзя считать уже реализованным.

Для передачи исходного бага в разработку данных достаточно. Предлагаю исправлять синхронизацию заголовка конкретной сессии без перезапуска разговора; проверку подтверждения Sonnet и привязки к нужному терминалу включить в верификацию. Добавление UI требует отдельного согласования поведения.

Подтверждаете передачу BUG-045 в разработку в таком объёме? Статус и файлы не менял.

### Boris Tsekinovsky · 2026-11-03

Да подтверждаю

### AI · 2026-11-03

Подтверждение принято: BUG-045 готов к передаче в разработку в согласованном объёме — обновление заголовка конкретного агента после `/model` без перезапуска разговора. Отдельный переключатель модели в Agents в этот объём не входит.

Повторная проверка кода и tasks/todo.md поддерживает вывод: заголовок формируется из настроек запуска, а существующее исправление обрабатывает изменения настроек MarkView. В проверенном пути обновления после `/model` нет. Вложений BUG-045 не найдено; runtime-проверка не проводилась.

Изменилось понимание объёма: теперь вы явно подтвердили предложенное исправление. Надёжный источник текущей модели и привязку к нужному терминалу предстоит определить при разработке; проверка должна исключить неожиданный перезапуск при повторном открытии Agents. Подтверждение CLI и последующий ответ остаются частью проверки, а не установленными фактами.

Файлы и статус отчёта не менял.

## Original description

В тайтле у агента написано CloudCode.fable, но я как только зашел, сделал переключение на Model, на Sonet, и в тайтле это никак не отразилось. То есть в тайтле показывается, как будто я использую Fable, но это не так, это баг.
