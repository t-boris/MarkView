---
type: research-map
id: 2026-11-24-a-hocu-ctoby-ty-sdelal-riserc-po-kazdomu
title: Агенты разработки в MarkView
question: Я хочу, чтобы ты сделал рисерч по каждому из агентов, которые у нас есть. Я имею в виду Клод, Кодекс, Капайлот, Антигравити. По функциональности, которые у них есть. То есть, иногда некоторые поддерживают гол, некоторые поддерживают оркестрацию, некоторые, можно сказать, например, разбить это на фазы, делать параллельно некоторые фазы. То есть, есть очень много у каждого подходов. Код ревью, например, у каждого есть. Я хотел бы, чтобы ты сделал исследования, какие функциональности есть, и как мы могли бы их применить в MarkView. Так что, когда запускается, например, какой-то процесс, если он не напрямую идет, а запускается через кнопочки какие-нибудь, например, Implement VDI, что-нибудь в этом роде, он сам бы понимал, как настроить этот процесс, то есть, как дать задание, чтобы он распараллелил, как, может быть, ограничить длительность работы и все остальное. То есть, я хочу, чтобы ты еще раз сделал ресерш по всем агентам, которые у нас есть, что они могут сделать, какой функционал у них есть, который мы могли бы использовать для разработки. Спасибо.
created: 2026-11-24
status: complete
web_queries:
  - Claude Code official docs goal command subagents agent teams parallel code review headless SDK max turns budget ...
  - site:code.claude.com/docs/en Claude Code goal subagents agent teams dynamic workflows code review CLI reference ...
  - https://code.claude.com/docs/en/goal
  - site:code.claude.com/docs/en Claude Code workflows /workflow scripts parallel phases goal headless review ultrareview ...
  - "'non-interactive'"
  - https://code.claude.com/docs/en/workflows
  - "'--worktree'"
  - site:learn.chatgpt.com/docs Codex subagents max_threads max_depth goals app server changelog ...
  - "'--json-schema'"
  - https://antigravity.google/docs/commands/goal
  - https://antigravity.google/docs/cli/best-practices
  - "'Review this git diff'"
  - https://code.claude.com/docs/en/permission-modes
  - Claude Code subagents context worktree background official documentation ...
  - https://code.claude.com/docs/en/sub-agents
  - "'What loads at startup'"
  - "'`pipeline()`'"
  - "'`isolation: worktree`'"
  - Claude Code /goal completion condition goal clear evaluator paused blocked managed settings print mode site:code.claude.com/docs ...
  - "'--safe-mode'"
  - "'SIGTERM'"
  - https://code.claude.com/docs/en/agent-sdk/agent-loop
  - Claude Code official Plan mode permission mode ExitPlanMode headless CLI ...
  - "'In non-interactive' in https://code.claude.com/docs/en/permission-modes"
  - "'When plan mode ends'"
  - "'--permission-prompts none'"
  - "'ExitPlanMode' in https://code.claude.com/docs/en/tools-reference"
  - "'Hook results in streaming output'"
  - https://github.com/openai/codex/tree/main/codex-rs/app-server
  - https://api.github.com/repos/openai/codex/contents/codex-rs/app-server/src
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_goal.rs
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread.rs
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors.rs
  - "'no_daemon'"
  - "'async fn run_interactive_tui'"
  - "'ThreadGoalRequestProcessor::new'"
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_goals.rs
  - "'can_reuse_implicit_local_daemon'"
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/Cargo.toml
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/ext/goal/src/lib.rs
  - "'launch::'"
  - "'pub async fn get_goal'"
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_goal_processor.rs
  - "'EmitThreadGoalUpdated'"
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_processor.rs
  - "'EventMsg::ThreadGoalUpdated'"
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/outgoing_message.rs
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_events.rs
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server/src/request_processors/thread_lifecycle.rs
  - GitHub Copilot CLI fleet subagents tasks non-interactive --fleet official documentation ...
  - "'available_commands_update'"
  - https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically
  - GitHub Copilot CLI JSONL fleet subagent.started subagent.completed GitHub Copilot SDK events session event schema
  - "'sendFleet'"
  - site:docs.github.com Copilot CLI plan autopilot goal max-autopilot-continues AI Credits /goal ...
  - site:docs.github.com setting an AI credit session limit GitHub Copilot CLI max-ai-credits limits soft cap quota ...
  - "'`/plan [PROMPT]`'"
  - "'stayInAutopilot'"
  - "'Use `--title` only with `--commit`.' in https://learn.chatgpt.com/docs/developer-commands"
  - site:antigravity.google Antigravity CLI /plan /goal plan approval goal completion pause ...
  - "'Slash commands in streaming mode'"
  - https://antigravity.google/docs/cli/reference
  - "'--disable-slash-commands'"
  - "'accept the plan'"
  - Google Antigravity Dynamic Workflows /run-workflow Python parallel pipeline phase JSON schema official documentation ...
  - Google Antigravity CLI agy acp official documentation session diff code review artifact Git diff ...
  - "'Review changes with `/diff`'"
  - "'expected shape'"
  - Claude Code official model configuration opus sonnet haiku coding cost speed Anthropic ...
  - site:docs.github.com Copilot CLI supported AI models model comparison task OpenAI Claude GitHub ...
  - GitHub Copilot CLI model supported change model Claude Sonnet 5.5 organization policy GitHub CLI cloud documentation
  - "'daily coding tasks'"
  - "'Gemini 4 Hydrogen is optimized'"
---

# Агенты разработки в MarkView

## Question

Я хочу, чтобы ты сделал рисерч по каждому из агентов, которые у нас есть. Я имею в виду Клод, Кодекс, Капайлот, Антигравити. По функциональности, которые у них есть. То есть, иногда некоторые поддерживают гол, некоторые поддерживают оркестрацию, некоторые, можно сказать, например, разбить это на фазы, делать параллельно некоторые фазы. То есть, есть очень много у каждого подходов. Код ревью, например, у каждого есть. Я хотел бы, чтобы ты сделал исследования, какие функциональности есть, и как мы могли бы их применить в MarkView. Так что, когда запускается, например, какой-то процесс, если он не напрямую идет, а запускается через кнопочки какие-нибудь, например, Implement VDI, что-нибудь в этом роде, он сам бы понимал, как настроить этот процесс, то есть, как дать задание, чтобы он распараллелил, как, может быть, ограничить длительность работы и все остальное. То есть, я хочу, чтобы ты еще раз сделал ресерш по всем агентам, которые у нас есть, что они могут сделать, какой функционал у них есть, который мы могли бы использовать для разработки. Спасибо.

## Map

- [Агенты разработки в MarkView](#n1)
  - [Claude Code](#n2)
    - [Цель и лимиты](#n8)
      - [Проверяемый критерий завершения](#n42)
      - [Вердикты и восстановление цели](#n43)
        - [Оценка при фоновой работе](#n48)
      - [Доверие к проекту и права](#n44)
      - [Область лимита ходов](#n45)
      - [Расходы и возобновление запуска](#n46)
      - [Причина остановки в JSON](#n47)
    - [Подагенты, команды и workflows](#n9)
      - [Контекст и права подагента](#n36)
      - [Координация в Agent Teams](#n37)
      - [Повторяемый сценарий Dynamic Workflows](#n38)
        - [Повторное выполнение внутри сессии](#n39)
      - [Делегирование в терминале Cockpit](#n40)
      - [Видимость делегирования в MarkView](#n41)
    - [Локальное и облачное ревью](#n10)
    - [Планирование и хуки](#n27)
      - [Утверждение плана](#n49)
        - [Утверждение плана без терминала](#n50)
      - [Решение хука Stop](#n51)
        - [Сбой скрипта проверки](#n52)
      - [Проверки до и после вызова](#n53)
      - [Источники настроек хуков](#n54)
  - [OpenAI Codex](#n3)
    - [Цель и управление сессией](#n11)
      - [Привязка к сохранённой сессии](#n55)
      - [Состояние цели и продолжение работы](#n56)
      - [Бюджет и счётчики цели](#n57)
      - [Уточнение и остановка хода](#n58)
        - [Пауза цели после прерывания](#n61)
      - [Подключение и обновления в окне](#n59)
      - [Совместимость CLI и длина цели](#n60)
    - [План и параллельные роли](#n12)
      - [Согласование плана в Codex CLI](#n77)
        - [События плана в App Server](#n82)
      - [Постановка подзадач и сбор результатов](#n78)
        - [События делегирования для интерфейса](#n83)
      - [Роли и предел параллелизма](#n79)
      - [Права подагентов в MarkView](#n80)
      - [Отдельные запуски с worktree](#n81)
        - [Просмотр рабочих копий в MarkView](#n84)
      - [Поисковые запросы ветки](#n85)
    - [CLI и отдельный ревьюер](#n13)
  - [GitHub Copilot](#n4)
    - [Plan, Autopilot и цель](#n14)
      - [Согласование плана в Copilot CLI](#n69)
        - [Автоматический переход из Plan](#n70)
      - [Явная цель и панель прогресса](#n71)
        - [Поисковые запросы ветки](#n76)
      - [Лимит цели и возобновление](#n72)
        - [Расхождение документации о `/limits`](#n73)
      - [Разрешения и уточняющие вопросы](#n74)
      - [Остановка и режим следующего запроса](#n75)
    - [Fleet и границы ACP](#n15)
      - [Несовместимость `--fleet` и `--acp`](#n62)
      - [Обнаружение команд в ACP](#n63)
        - [Поисковые запросы ветки](#n68)
      - [Управление подзадачами через `/tasks`](#n64)
      - [Машиночитаемый вывод Fleet](#n65)
      - [Запуск и события Fleet через SDK](#n66)
      - [Инструкции и права подагентов](#n67)
    - [Ревью в CLI и GitHub](#n16)
  - [Google Antigravity](#n5)
    - [Plan, Goal и тайм-аут](#n17)
      - [Вход в режим планирования](#n86)
        - [Подтверждение плана в терминале](#n91)
      - [Жизненный цикл `/goal`](#n87)
        - [Возврат к беседе после прерывания](#n92)
      - [Передача задачи в терминал MarkView](#n88)
      - [Дедлайн CLI и тайм-аут MarkView](#n89)
        - [Два лимита запроса `/usage`](#n93)
      - [Итог разового запуска](#n90)
        - [Граница поддержки `/goal` через NDJSON](#n94)
      - [Запросы и границы проверки ветки](#n95)
    - [Параллельные и последовательные этапы](#n18)
      - [Параллельные задачи и изоляция](#n96)
      - [Последовательные задачи и передача результатов](#n97)
      - [Согласование скрипта и наблюдение фаз](#n98)
      - [Перепланирование внутри Orchestrator](#n99)
        - [Выбор модели Orchestrator в Cockpit](#n100)
      - [Итог workflow для шага Cockpit](#n101)
      - [Поисковые запросы ветки](#n102)
    - [Ревью и программный интерфейс](#n19)
  - [Сценарии MarkView](#n6)
    - [Кнопка и текущая передача задачи](#n20)
    - [Этапы и зависимости](#n21)
      - [Реализация в worktree](#n24)
        - [Ветка и исходный коммит](#n117)
        - [Границы параллельных правок](#n118)
        - [Запуск в корне рабочей копии](#n119)
          - [Аудит изменений в корне Cockpit](#n122)
        - [Коммиты для передачи интегратору](#n120)
        - [Сведение правок в ветке задачи](#n121)
          - [Перенос после переименования файлов](#n123)
      - [Проверки и независимое ревью](#n25)
        - [Матрица проверок по изменению](#n124)
          - [Что выбирает `--changed`](#n125)
          - [Разбор нестабильного теста](#n131)
        - [Изоляция артефактов тестов](#n126)
        - [Задание независимому ревьюеру](#n127)
          - [Охват ревью PR X-Ray](#n129)
        - [Разбор замечаний с исполнителем](#n128)
          - [Передача замечаний из PR X-Ray](#n132)
        - [Перепроверка после исправлений](#n130)
          - [Итоги обязательных проверок PR](#n133)
      - [Доставка по правилам проекта](#n26)
        - [Правила выполнения и перехода статуса](#n134)
          - [Настройки конкретного запуска](#n138)
          - [Подтверждение внешнего события доставки](#n139)
        - [Путь изменений в `main`](#n135)
          - [Повышение версии до коммита](#n140)
          - [Доставка изменений только в документации](#n141)
          - [Связь PR с задачей и коммитом](#n142)
        - [Релиз из слитого коммита](#n136)
          - [Проверка подписанного установщика](#n143)
          - [Проверка тега и состава релиза](#n144)
        - [Сверка внешнего состояния перед повтором](#n137)
          - [Возобновление после создания или слияния PR](#n145)
          - [Возобновление прерванной публикации](#n146)
      - [План по спецификации](#n30)
        - [Назначение пары в плане Cockpit](#n104)
        - [Допуск агента и модели](#n105)
          - [Разрешение модели по умолчанию](#n106)
        - [Пара для чтения спецификации](#n107)
        - [Codex для реализации по спецификации](#n108)
        - [Claude Code для сложной диагностики](#n109)
        - [Copilot для задач GitHub](#n110)
        - [Antigravity для исполнения через Gemini](#n111)
        - [Cline с настроенным провайдером](#n112)
        - [Модель по цене ошибки](#n113)
        - [Обоснование выбора в карточке шага](#n114)
        - [Калибровка на задачах MarkView](#n115)
        - [Поисковые запросы ветки](#n116)
    - [Время, повторы и остановка](#n22)
    - [Выбор возможностей по режиму](#n23)
    - [Кнопка и передача задачи](#n28)
    - [Доказательства и состояние задачи](#n29)
    - [Create new project](#n103)
  - [Проверка источников](#n7)
    - [Объём и проверка запуска](#n31)
    - [Запросы о Claude Code](#n32)
    - [Запросы о Codex](#n33)
    - [Запросы о GitHub Copilot](#n34)
    - [Запросы об Antigravity](#n35)

## Nodes

### Агенты разработки в MarkView {#n1}

- tags: агенты, оркестрация

MarkView может задавать этапы, ограничения и правила завершения, а каждому агенту делегировать те части процесса, для которых у него есть подходящий интерфейс. Кнопка запуска может выбирать этот сценарий по типу задачи и возможностям активного агента.

#### Evidence

- [Project fact] Руководство описывает единый реестр ассистентов, точку входа AIOperation и общий механизм запуска дочерних процессов. — `CLAUDE.md`
- [AI inference] Эти точки позволяют разделить политику выполнения сценария и особенности конкретного агента.

### Claude Code {#n2}

- tags: Claude

Цели, подагенты, совместная работа и ревью в Claude Code, с привязкой к существующим способам запуска из MarkView.

### Цель и лимиты {#n8}

- tags: цель, лимиты
- position: 1766, -773

`/goal` запускает повторные ходы с проверкой условия завершения. MarkView уже формирует эту команду для терминала. Для управляемого запуска Anthropic также документирует `-p` с потоком `stream-json`, лимитом ходов и оценочным лимитом расходов.

#### Evidence

- [Project fact] ClaudeProvider формирует `/goal` для передачи цели. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:25`
- [External fact] Цель проверяется после каждого хода отдельной моделью. Цикл поддерживается и в print mode. — <https://code.claude.com/docs/en/goal>
- [External fact] `--max-turns` и `--max-budget-usd` действуют в print mode. Оценка расходов может превысить заданный порог. — <https://code.claude.com/docs/en/cli-reference>

### Проверяемый критерий завершения {#n42}

- tags: критерии, доказательства

Модель-оценщик опирается на то, что появилось в разговоре. Условие цели может требовать конкретный результат и способ его подтвердить, например успешный код выхода тестов и вывод команды. MarkView уже добавляет к цели реализации требования `Definition of done` и просит показать доказательство для каждого обязательного пункта.

#### Evidence

- [External fact] Оценщик цели не запускает команды и не читает файлы самостоятельно. Anthropic рекомендует указывать измеримый результат и способ проверки. — <https://code.claude.com/docs/en/goal#write-an-effective-condition>
- [Project fact] `HandoffPrompt.feature` добавляет непустой `DefinitionOfDone.goalText()` к тексту цели. — `MarkView/Models/Lifecycle/HandoffPrompt.swift:22`
- [Project fact] `goalText()` требует для каждого обязательного пункта вывод команды, ссылку или файл и запрашивает итоговый список с отметками. — `MarkView/Models/Lifecycle/DefinitionOfDone.swift:137`

### Вердикты и восстановление цели {#n43}

- tags: сессия, вердикт

Вердикт «ещё не выполнено» запускает следующий ход. Достижение или невозможность выполнения снимают цель с записью в стенограмме. `/goal` показывает состояние, `/goal clear` снимает активную цель, а возобновление сессии восстанавливает ещё активное условие и сбрасывает счётчик ходов, таймер и базу учёта токенов.

#### Evidence

- [External fact] Документированы три вердикта оценщика. При достижении или невозможности выполнения Claude Code записывает соответствующий исход в стенограмму. — <https://code.claude.com/docs/en/goal#how-evaluation-works>
- [External fact] `/goal` без аргументов показывает состояние и последнюю причину вердикта, а `/goal clear` снимает цель. — <https://code.claude.com/docs/en/goal#check-status>
- [External fact] При возобновлении сессии восстанавливается только цель, которая оставалась активной. Счётчик ходов, таймер и база учёта токенов начинаются заново. — <https://code.claude.com/docs/en/goal#resume-with-an-active-goal>

### Оценка при фоновой работе {#n48}

- tags: фоновые задачи

Если в конце хода ещё работает фоновый подагент или shell-команда, оценка откладывается. Завершение фоновой работы запускает новый ход с её результатом. В интерактивном режиме Claude Code также может сам начать ход для проверки зависшей работы, а в `-p` такая проверка возможна только в конце очередного хода.

#### Evidence

- [External fact] Claude Code пропускает оценку, пока есть фоновая работа. Проверка её состояния во время простоя доступна только интерактивной сессии. — <https://code.claude.com/docs/en/goal#background-work-defers-evaluation>

### Доверие к проекту и права {#n44}

- tags: доверие, разрешения

Доступность `/goal` зависит от доверия к рабочей папке и политики хуков. Цель сохраняет текущий режим разрешений, поэтому при ручном режиме запуск проверки может ждать подтверждения. Работу `/goal` с параметрами текущего фонового запуска MarkView нужно подтвердить отдельно.

#### Evidence

- [External fact] Для `/goal` действуют правила доверия к рабочей папке для хуков. `disableAllHooks` и управляемый `allowManagedHooksOnly` делают команду недоступной. Поисковый запрос — `Claude Code /goal completion condition goal clear evaluator paused blocked managed settings print mode site:code.claude.com/docs`. — <https://code.claude.com/docs/en/goal#requirements>
- [External fact] Постановка цели сохраняет режим разрешений. В Manual mode Claude запрашивает разрешение на вызовы инструментов, которые настройки ещё не разрешили. — <https://code.claude.com/docs/en/goal#set-a-goal>
- [Project fact] В фоновом вызове `ClaudeProvider.launch` передаёт `--safe-mode` и выбирает инструменты чтения и веб-поиска по параметрам запроса. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:172`
- [Open assumption] Работает ли встроенный оценщик `/goal` при текущем наборе аргументов `ClaudeProvider.launch`, в живом запуске не проверялось.

### Область лимита ходов {#n45}

- tags: ходы, CLI

`--max-turns` ограничивает агентные ходы в режиме `-p`. При потоковом вводе `--input-format stream-json` ожидающее сообщение получает собственный лимит после исчерпания предыдущего. Ограничение по ходам или времени внутри текста `/goal` оценивает модель по ходу разговора.

#### Evidence

- [External fact] `--max-turns` действует в print mode. При потоковом вводе оставшееся в очереди сообщение запускает следующий ход со своим лимитом. Поисковый запрос — `Claude Code CLI --max-turns --max-budget-usd stream-json result error_max_budget_usd site:code.claude.com/docs`. — <https://code.claude.com/docs/en/cli-reference#cli-flags>
- [External fact] Ограничение, записанное в условие `/goal`, проверяется оценщиком по сообщениям о прогрессе в разговоре. — <https://code.claude.com/docs/en/goal#write-an-effective-condition>

### Расходы и возобновление запуска {#n46}

- tags: бюджет, возобновление

`--max-budget-usd` учитывает расходы подагентов и сверяет оценку после получения ответов модели. Ответ, на котором достигнут порог, тоже учитывается, поэтому возможен перерасход. При `--continue` или `--resume` расходы прошлых запусков могут отображаться в общем итоге, но в лимит нового запуска они не входят.

#### Evidence

- [External fact] CLI применяет бюджет к оценке расходов текущего запуска с учётом подагентов. Восстановленные расходы прошлых запусков из лимита исключаются. — <https://code.claude.com/docs/en/cli-reference#cli-flags>
- [External fact] Оценка обновляется после ответа модели. Превышение может включать стоимость этого ответа и расходы фоновых подагентов до их остановки. — <https://code.claude.com/docs/en/agent-sdk/agent-loop#budget-headroom>
- [External fact] При продолжении разговора JSON-вывод включает общую оценку `total_cost_usd` с расходами предыдущих запусков. — <https://code.claude.com/docs/en/headless#pipe-data-through-claude>

### Причина остановки в JSON {#n47}

- tags: stream-json, диагностика

Схема результата Anthropic различает `error_max_turns` и `error_max_budget_usd`. Текущий парсер MarkView читает стоимость и общий признак `is_error`. Для отдельного статуса по каждому лимиту нужен разбор `subtype`.

#### Evidence

- [External fact] `SDKResultMessage` перечисляет отдельные подтипы `error_max_turns` и `error_max_budget_usd`, а также поля `num_turns` и `total_cost_usd`. — <https://code.claude.com/docs/en/agent-sdk/typescript#sdkresultmessage>
- [Project fact] `ClaudeProvider.launch` включает `stream-json` без аргументов `--max-turns` и `--max-budget-usd`. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:172`
- [Project fact] В ветке `result` парсер сохраняет `total_cost_usd`, а при `is_error` формирует общее сообщение об ошибке без чтения `subtype`. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:254`

### Подагенты, команды и workflows {#n9}

- tags: параллельность
- position: 1381, -1075

Для независимого анализа подходят подагенты. Agent Teams добавляет обмен между участниками, а Dynamic Workflows позволяет зафиксировать порядок и параллельные этапы в JavaScript. В MarkView эти варианты подходят для исследования и проверки в пределах одного этапа Cockpit.

#### Evidence

- [External fact] Claude Code поддерживает специализированных подагентов с отдельным контекстом. — <https://code.claude.com/docs/en/sub-agents>
- [External fact] Agent Teams экспериментален и по умолчанию отключён. — <https://code.claude.com/docs/en/agent-teams>
- [External fact] Dynamic Workflows хранит порядок, ветвления и промежуточные результаты в JavaScript и показывает ход этапов. — <https://code.claude.com/docs/en/workflows>
- [AI inference] Внешний сценарий может принимать итог этапа, оставляя внутреннее делегирование Claude.

### Контекст и права подагента {#n36}

- tags: подагенты, контекст

Обычный подагент получает отдельное окно контекста и сформулированное для него поручение. Для исследования MarkView в поручение стоит включать вопрос, допустимые пути, правила чтения и формат ссылок на доказательства.

#### Evidence

- [External fact] Обычный подагент не видит историю родительского диалога. Встроенный Explore работает с инструментами чтения и стартует без CLAUDE.md. Исключение по наследованию истории — режим fork. — <https://code.claude.com/docs/en/sub-agents>
- [AI inference] Явная передача ограничений нужна, когда подагент должен соблюдать область исследования и возвращать воспроизводимые ссылки на строки.

### Координация в Agent Teams {#n37}

- tags: Agent Teams, координация

Команда подходит для проверки конкурирующих гипотез, когда участникам нужно обсуждать промежуточные результаты. Ведущий распределяет задачи и сводит выводы. Участники с инструментами `Task` видят общий список и могут брать свободные задачи без незакрытых зависимостей.

#### Evidence

- [External fact] Участники обмениваются сообщениями напрямую. Общий список поддерживает зависимости и защищает одновременное взятие задачи файловой блокировкой. Anthropic описывает проверку конкурирующих гипотез как сценарий применения. — <https://code.claude.com/docs/en/agent-teams>
- [External fact] Статус задачи может отставать от фактического выполнения и блокировать зависимые задачи. Команды `/resume` и `/rewind` не восстанавливают участников в режиме in-process. — <https://code.claude.com/docs/en/agent-teams#limitations>

### Повторяемый сценарий Dynamic Workflows {#n38}

- tags: Dynamic Workflows, JavaScript

Для повторяемого исследования можно сохранить JavaScript в `.claude/workflows/` и запускать его командой `/<name>`. Сценарий может параллельно собрать находки, проверить их по заданной схеме и передать на сведение. Для результата проверки `null` стоит учитывать как пропуск, требующий разбора. Поисковый запрос — `Claude Code Dynamic Workflows JavaScript parallel stages official documentation`.

#### Evidence

- [External fact] `agent()` запускает подагента и может потребовать JSON по `schema`; `parallel()` ждёт весь набор; `pipeline()` распределяет работу по элементам; `phase()` группирует работу в индикаторе прогресса. `pipeline()` сохраняет `null` на месте отдельных неудачных результатов. — <https://code.claude.com/docs/en/workflows#what-the-saved-script-looks-like>
- [External fact] Сценарии из `.claude/workflows/` доступны участникам репозитория как команды `/<name>`. — <https://code.claude.com/docs/en/workflows#save-the-workflow-for-reuse>
- [AI inference] Если просто удалить `null`, итог может выглядеть полным при фактически непроверенной части задания.

### Повторное выполнение внутри сессии {#n39}

- tags: возобновление, сессия

При перезапуске Claude Code может вернуть сохранённые результаты завершившихся подагентов. Сбой подагента или изменение его поручения может вызвать повтор и последующих вызовов, включая ранее завершённые. Cockpit запускает новую сессию на шаг, поэтому сохранённые результаты Claude не следует считать контрольной точкой между попытками Cockpit.

#### Evidence

- [External fact] При повторе Claude Code воспроизводит порядок запусков, переиспользует доступные результаты и повторяет вызовы начиная с изменившегося или неудачного. В новой сессии прежний запуск недоступен. — <https://code.claude.com/docs/en/workflows#resume-after-a-pause>
- [Project fact] `CockpitAgentAttempt` открывает терминал с `resuming: false` и завершает его при получении результата. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:54`
- [Project fact] Обработчик результата завершает терминальную сессию и ждёт её остановки перед передачей результата дальше. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:166`

### Делегирование в терминале Cockpit {#n40}

- tags: Cockpit, PTY, CLI

Исполнитель шага получает поручение в новом интерактивном PTY. Это даёт Agent Teams необходимый режим запуска, если функция включена в Claude Code. Одноразовый вызов MarkView через `claude -p` использует другой набор инструментов, в котором отсутствуют `Agent` и `Workflow`.

#### Evidence

- [Project fact] `CockpitAgentAttempt` открывает новый AI-терминал, получает его PTY и отправляет задание через `pasteWhenReady`. Поручение запрещает запускать и управлять другими агентами через MarkView во время шага. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:78`
- [Project fact] Одноразовый вызов Claude запускается с `-p`, `--safe-mode` и `--tools`. В список могут войти `Read`, `Grep`, `Glob`, `WebSearch` и `WebFetch`. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:170`
- [External fact] Agent Teams требует интерактивной сессии. В `claude -p` и Agent SDK именованный агент запускается как обычный подагент даже при включённой функции. — <https://code.claude.com/docs/en/agent-teams#enable-agent-teams>
- [Open assumption] Фактический запуск команды и атрибуция MCP-вызовов её участников в терминале Cockpit с установленным Claude Code остаются непроверенными в этом исследовании.

### Видимость делегирования в MarkView {#n41}

- tags: наблюдаемость, журнал, Cockpit

Индикатор Claude может показать вызов подагента по записи ведущей сессии. Подробности работы каждого исполнителя в текущий разбор активности не попадают. Если результат шага зависит от нескольких подагентов, в отчёте ведущего стоит указать, кто что проверил и где остались пробелы.

#### Evidence

- [Project fact] Парсер активности Claude пропускает записи с `isSidechain: true`. Вызовы `Task` и `Agent` он показывает как действие подагента с описанием, если оно доступно. — `MarkView/Models/AI/Providers/AgentActivity.swift:54`
- [Project fact] Для `Task` и `Agent` формируется подпись `Subagent: …` либо `Running a subagent`. — `MarkView/Models/AI/Providers/AgentActivity.swift:312`
- [External fact] Claude Code хранит стенограммы подагентов в отдельных файлах `agent-{agentId}.jsonl` в подкаталоге `subagents/` сессии. — <https://code.claude.com/docs/en/sub-agents#auto-compaction>
- [AI inference] Видимый вызов подагента сам по себе подтверждает запуск работы, но не её выполнение или полноту покрытия.

### Локальное и облачное ревью {#n10}

- tags: ревью
- position: 1350, -130

Для локального ревью доступна команда `/code-review`. Для сценариев с машиночитаемым результатом есть `claude ultrareview --json`, а облачный Code Review публикует проверенные замечания в GitHub PR на Team и Enterprise.

#### Evidence

- [External fact] Anthropic отдельно описывает `/code-review` и облачный Code Review для GitHub PR. — <https://code.claude.com/docs/en/code-review>
- [External fact] У `claude ultrareview` есть `--json` и `--timeout`. Публикация комментария в PR требует `--post`. — <https://code.claude.com/docs/en/cli-reference>
- [AI inference] MarkView может показывать вывод ревью перед решением о публикации.

### Планирование и хуки {#n27}

- tags: план, хуки
- layout: right
- position: 1375, -350

Plan mode подходит для предварительного анализа. Через `Stop` hook можно проверять конкретное условие скриптом. Текущий разовый профиль MarkView запускает Claude в `--safe-mode` с ограниченным набором инструментов, поэтому для управляемой реализации нужен отдельный профиль.

#### Evidence

- [External fact] Claude Code документирует Plan mode и хуки жизненного цикла, включая проверку при завершении хода. — <https://code.claude.com/docs/en/permission-modes>
- [External fact] `Stop` hook может выполнить детерминированную проверку скриптом. — <https://code.claude.com/docs/en/goal>
- [Project fact] Разовый запуск использует `-p`, `--safe-mode`, потоковый JSON и разрешает только заданные инструменты чтения или поиска. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:170`

### Утверждение плана {#n49}

- tags: Claude Code, Plan mode

В Plan mode Claude изучает проект и предлагает план. Вызов `ExitPlanMode` выводит план на утверждение. В терминале пользователь может вернуть план на доработку или утвердить его и выбрать режим прав для реализации.

#### Evidence

- [External fact] Plan mode можно включить через `--permission-mode plan`. После утверждения плана сессия переходит в режим прав, выбранный пользователем. — <https://code.claude.com/docs/en/permission-modes#analyze-before-you-edit-with-plan-mode>
- [External fact] `ExitPlanMode` представляет план для утверждения и служит точкой выхода из режима планирования. — <https://code.claude.com/docs/en/tools-reference>
- [Project fact] MarkView показывает вызов `ExitPlanMode` как `Presenting a plan` в сводке активности агента. — `MarkView/Models/AI/Providers/AgentActivity.swift:319`

### Утверждение плана без терминала {#n50}

- tags: CLI, MCP

Чтобы встроить утверждение в интерфейс MarkView, неинтерактивному запуску нужен канал для ответа на запрос прав. Claude Code поддерживает MCP-обработчик через `--permission-prompt-tool`. В текущей разовой сессии MarkView этот обработчик отсутствует, а сохранение сессии отключено. Поисковый запрос был `Claude Code official Plan mode permission mode ExitPlanMode headless CLI`.

#### Evidence

- [External fact] `--permission-prompt-tool` передаёт запросы прав указанному MCP-инструменту в неинтерактивном запуске. — <https://code.claude.com/docs/en/cli-reference#cli-flags>
- [External fact] Для автоматического восстановления Plan mode через `-p --resume` документация требует, среди прочего, `--permission-prompt-tool`, доступный `ExitPlanMode` и включённые запросы прав. Явно переданный `--permission-mode` задаёт режим нового запуска. — <https://code.claude.com/docs/en/sessions#resume-in-plan-mode-with--p>
- [Project fact] Разовый запуск использует `--no-session-persistence`. В полном наборе аргументов этого запуска `--permission-prompt-tool` отсутствует. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:172`

### Решение хука Stop {#n51}

- tags: хуки, Stop

Когда основной агент готов закончить ход, синхронный скрипт `Stop` может вернуть `decision: "block"` с `reason` или завершиться кодом `2` с объяснением в stderr. Claude получает причину и продолжает ход. Поисковый запрос был `Claude Code official hooks Stop StopFailure stop_hook_active exit code JSON async safe mode`.

#### Evidence

- [External fact] `Stop` срабатывает при завершении ответа основного агента. JSON с `decision: "block"` и `reason` или код выхода `2` с сообщением в stderr позволяют продолжить ход. — <https://code.claude.com/docs/en/hooks#stop-decision-control>
- [External fact] Флаг `stop_hook_active` показывает, что ход уже продолжился по решению хука. После восьми последовательных продолжений без вызова инструмента Claude Code пропускает следующую блокировку. Вызов инструмента сбрасывает этот счётчик. — <https://code.claude.com/docs/en/hooks#stop-input>

### Сбой скрипта проверки {#n52}

- tags: Stop, проверка

Проверка может обнаружить невыполненное условие или сама завершиться с ошибкой. Код `1` без валидного JSON обычно позволяет ходу закончиться, а `onFailure: "block"` для `Stop` не действует. Если результат проверки определяет приёмку, MarkView стоит требовать явного подтверждения, что проверка выполнилась и прошла.

#### Evidence

- [External fact] Обычный ненулевой код, например `1` без валидного JSON, считается неблокирующей ошибкой для `Stop`. Настройка `onFailure: "block"` на это событие не распространяется. — <https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails>
- [External fact] При прерывании пользователем `Stop` не вызывается. При ошибке API вызывается `StopFailure`, результат которого игнорируется, за исключением `terminalSequence`. — <https://code.claude.com/docs/en/hooks#stopfailure>
- [AI inference] Само завершение хода не подтверждает выполнение проверки. Для приёмки пригодится отдельный явный результат скрипта или проверка со стороны MarkView.

### Проверки до и после вызова {#n53}

- tags: PreToolUse, PostToolUse

`PreToolUse` может остановить вызов до его выполнения. `PostToolUse` подходит для быстрых проверок после успешной операции, например для форматирования изменённого файла. В MarkView уже есть пример `PreToolUse` в профиле Remote Work.

#### Evidence

- [External fact] `PreToolUse` запускается перед вызовом и может его заблокировать. `PostToolUse` запускается после успешного выполнения, когда побочные эффекты уже произошли. — <https://code.claude.com/docs/en/hooks#hook-events>
- [Project fact] Профиль Remote Work создаёт `claude-settings.json` с командным хуком `PreToolUse`, общим matcher и тайм-аутом в пять секунд. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:280`
- [Project fact] Тест Remote Work проверяет наличие `PreToolUse` в сгенерированном файле и отдельно проверяет ответы защитного обработчика на разрешённые и запрещённые имена инструментов. — `MarkViewHostedTests/RemoteWorkspaceHostTests.swift:378`

### Источники настроек хуков {#n54}

- tags: настройки, CLI

`--safe-mode` отключает обычные пользовательские и проектные хуки, но сохраняет хуки, заданные политикой администратора. У MarkView есть пример передачи собственного файла через `--settings` и пустого списка обычных источников через `--setting-sources`. Для профиля реализации нужно проверить, какие хуки фактически загружаются с выбранной версией CLI и политикой машины.

#### Evidence

- [External fact] `--safe-mode` отключает обычные настройки хуков. Хуки из управляемой политики продолжают действовать. — <https://code.claude.com/docs/en/cli-reference#cli-flags>
- [External fact] Хуки из разных источников объединяются. Администратор может ограничить их запуск через `allowManagedHooksOnly`. — <https://code.claude.com/docs/en/hooks#configure-hooks>
- [Project fact] Remote Work передаёт сгенерированный файл через `--settings` и пустую строку через `--setting-sources`. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:285`
- [Open assumption] Какие хуки загрузятся в отдельном профиле реализации на целевой машине, по коду и документации не установлено. Живой запуск CLI не проводился.

### OpenAI Codex {#n3}

- tags: Codex
- position: -218, -653

Долгие задачи, делегирование, машинно-читаемый запуск и ревью в Codex.

### Цель и управление сессией {#n11}

- tags: цель, JSON-RPC
- position: -499, -1082

MarkView уже отправляет `/goal` в терминал. App Server открывает путь к управлению целью из окна MarkView, включая чтение состояния, учёт токенов и отдельную остановку текущего хода.

#### Evidence

- [Project fact] CodexProvider формирует `/goal` для терминала. — `MarkView/Models/AI/Providers/CodexProvider.swift:24`
- [External fact] В интерактивном Codex CLI цель можно задать, приостановить, возобновить или очистить. — <https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex>
- [External fact] App Server документирует `thread/goal/set`, `thread/goal/get`, `thread/goal/clear`, `tokenBudget`, уведомления об изменении и `turn/interrupt`. — <https://learn.chatgpt.com/docs/app-server>

### Привязка к сохранённой сессии {#n55}

- tags: Remote Work, threadId

В Remote Work MarkView уже находит сохранённую сессию Codex по каталогу, обновляет её контекст через App Server и передаёт тот же `threadId` терминалу. Этот путь показывает, откуда можно получить идентификатор для обращения к сохранённой цели.

#### Evidence

- [Project fact] `RemoteCodexContext.prepare` запрашивает последнюю обновлённую сессию для каталога, проверяет UUID и путь, при изменении контекста вызывает `thread/resume` и `thread/inject_items`, затем закрывает клиент и возвращает ID. — `MarkView/Models/Remote/RemoteCodexContext.swift:16`
- [Project fact] `RemoteHostController` передаёт найденный ID как `resumeThreadID` при подготовке команды терминала. — `MarkView/Models/Remote/RemoteHostController.swift:138`
- [AI inference] Для чтения цели можно привязаться к тому же `threadId`. Для управления активным ходом нужна отдельная проверка подключения к серверу, который ведёт эту сессию.

### Состояние цели и продолжение работы {#n56}

- tags: цель, App Server

Цель хранится в конкретной сессии Codex. App Server и `/goal` обращаются к одному сохранённому состоянию. Codex может начать следующий ход, когда цель активна, бюджет позволяет продолжать, сессия свободна и пользовательский ввод не ждёт обработки.

#### Evidence

- [External fact] OpenAI описывает цель как сохранённое состояние сессии и перечисляет условия автоматического продолжения между ходами. — <https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex#how-goals-are-designed-in-codex>
- [External fact] `thread/goal/get` читает цель, `thread/goal/set` меняет её, `thread/goal/clear` удаляет её. Документация указывает, что это то же сохранённое состояние, которое показывает `/goal`. — <https://learn.chatgpt.com/docs/app-server#manage-a-thread-goal>

### Бюджет и счётчики цели {#n57}

- tags: токены, бюджет

App Server возвращает `tokenBudget`, `tokensUsed` и `timeUsedSeconds` для цели. Смена текста цели сбрасывает учёт. Изменение статуса или бюджета с сохранением текущей незавершённой цели сохраняет накопленные значения.

#### Evidence

- [External fact] Ответ `thread/goal/set` и уведомление `thread/goal/updated` содержат бюджет, расход токенов и время. Документация описывает условия сброса и сохранения счётчиков. — <https://learn.chatgpt.com/docs/app-server#manage-a-thread-goal>
- [Project fact] `CodexUsage.Log` вычисляет приращения общего счётчика токенов сессии из записей `token_count`. — `MarkView/Models/AI/Providers/CodexProvider.swift:419`
- [AI inference] Для индикатора расхода цели в MarkView подходят счётчики App Server. Общий счётчик сессии охватывает и работу за пределами этой цели.

### Уточнение и остановка хода {#n58}

- tags: App Server, ход

`turn/steer` добавляет ввод к уже идущему ходу. `turn/interrupt` запрашивает остановку по `threadId` и `turnId`. Интерфейс может подтвердить остановку после `turn/completed` со статусом `interrupted`, а состояние цели затем прочитать отдельно.

#### Evidence

- [External fact] Документация App Server описывает `turn/steer` как передачу ввода в активный ход и `turn/completed` как итоговое уведомление после отмены. — <https://learn.chatgpt.com/docs/app-server#lifecycle-overview>
- [External fact] `turn/interrupt` принимает `threadId` и `turnId`, возвращает пустой результат при успехе и завершает ход со статусом `interrupted`. — <https://learn.chatgpt.com/docs/app-server#interrupt-a-turn>
- [AI inference] Интерфейсу MarkView нужны отдельные индикаторы текущего хода и сохранённой цели. По одному результату `turn/interrupt` состояние цели определить нельзя.

### Пауза цели после прерывания {#n61}

- tags: пауза, возобновление

Руководство OpenAI указывает, что прерывание приостанавливает цель. После остановки хода пользователь может возобновить её через `/goal resume`. Переходы лучше показывать по событиям хода и затем сверять с состоянием цели.

#### Evidence

- [External fact] OpenAI описывает прерывание как причину паузы цели и указывает, что возобновление сессии может восстановить цель при подходящих условиях. — <https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex#how-goals-are-designed-in-codex>
- [External fact] CLI документирует `/goal pause`, `/goal resume`, `/goal edit` и `/goal clear`. — <https://learn.chatgpt.com/docs/developer-commands#set-or-view-a-task-goal-with-goal>
- [AI inference] После `turn/completed` можно обновить индикацию паузы по `thread/goal/get` или уведомлению `thread/goal/updated`.

### Подключение и обновления в окне {#n59}

- tags: App Server, уведомления

Для окна со статусом цели нужен клиент, который принимает уведомления App Server. При подключении можно прочитать цель через `thread/goal/get`, затем обновлять её по `thread/goal/updated` и `thread/goal/cleared`. Возможность подключиться к серверу уже открытого терминала MarkView остаётся непроверенной.

#### Evidence

- [Project fact] Одноразовый клиент `RemoteCodexContext` ждёт ответ с ID своего запроса и пропускает сообщения, у которых этот ID отсутствует или отличается. — `MarkView/Models/Remote/RemoteCodexContext.swift:87`
- [External fact] App Server различает ответы с ID и уведомления без ID. Протокол документирует события изменения и удаления цели. — <https://learn.chatgpt.com/docs/app-server#api-overview>
- [External fact] Официальное руководство описывает запуск TUI с подключением к уже работающему App Server через `codex --remote`. — <https://learn.chatgpt.com/docs/app-server#connect-the-cli-terminal-ui>
- [Open assumption] Не проверено, может ли окно MarkView подключиться к тому же экземпляру App Server при текущем запуске локального терминала, в том числе после переподключения.
- [Project fact] Штатный запуск локального Codex в MarkView собирает команду интерактивного CLI без явного `--remote`. `TerminalSession` вводит её в оболочку через PTY после первого вывода, а для окна публикует байты терминала. — `MarkView/Models/Workspace/AITerminalsController.swift:94`
- [Project fact] Если для Codex включены MCP-серверы MarkView, локальный запуск добавляет оконные настройки `mcp_servers.*.command` и `mcp_servers.*.args` через `-c`. — `MarkView/Models/AI/Providers/CodexProvider.swift:111`
- [External fact] В проверенном исходном коде Codex CLI параметры `-c mcp_servers.*` исключают автоматический выбор общего демона. При явном `--remote` отдельный путь запуска позволяет выбрать общий сервер через Unix-сокет. — <https://github.com/openai/codex/blob/main/codex-rs/tui/src/daemon_startup.rs#L54-L115>
- [AI inference] При включённых MCP-серверах MarkView и версии CLI с проверенной логикой обычная локальная вкладка использует встроенный App Server. Подключение окна к сокету отдельного демона в этой конфигурации не даст поток событий этой вкладки. На установленном CLI это не проверялось.
- [Project fact] При восстановлении локальных вкладок MarkView хранит профили и индекс показанной вкладки. Сохранённая запись не содержит `threadId` или адреса App Server, а Codex при возобновлении получает `resume --last`. — `MarkView/Models/Workspace/AITerminalsController.swift:257`
- [Project fact] При возобновлении Codex в Remote Work `RemoteCodexContext` запускает отдельный `app-server --stdio` и закрывает его до запуска терминала. Между этими этапами передаётся идентификатор сохранённой сессии. — `MarkView/Models/Remote/RemoteHostController.swift:138`
- [External fact] `thread/goal/get` читает сохранённую цель по `threadId` и работает для сохранённой сессии, даже если она ещё не загружена в память App Server. При отсутствии цели возвращается `goal: null`. Вызов сам по себе не оформляет подписку на сессию. — <https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_goal_processor.rs#L236-L326>
- [External fact] В проверенной реализации App Server рассылает `thread/goal/updated` и `thread/goal/cleared` клиентам того же сервера. Окно может выбрать нужное событие по `threadId` без подписки на события ходов этой сессии. При `thread/resume` сервер также может прислать снимок сохранённой цели, включая `thread/goal/cleared`, если цели уже нет. — <https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_lifecycle.rs#L1002-L1044>

### Совместимость CLI и длина цели {#n60}

- tags: CLI, совместимость

OpenAI указывает поддержку Goals начиная с Codex `0.128.0`. Текст цели должен быть непустым и содержать не более 4 000 символов. Для длинной постановки можно передать ссылку на файл. Методы App Server можно сверить со схемой, которую выдаёт установленная версия Codex.

#### Evidence

- [Project fact] `CLIToolLocator.probe` запускает команду версии, проверяет вход в аккаунт и возвращает строку версии. `CodexProvider.goalPrompt` добавляет `/goal` к переданному тексту. — `MarkView/Models/AI/AIAssistants.swift:297`
- [Project fact] В `CodexProvider.goalPrompt` нет проверки длины или версии CLI. — `MarkView/Models/AI/Providers/CodexProvider.swift:24`
- [External fact] В руководстве OpenAI для Goals минимальная версия указана как `0.128.0`. — <https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex#quickstart-using-goals>
- [External fact] Справка CLI указывает лимит в 4 000 символов. Поисковый запрос OpenAI Docs — `Codex App Server thread goal set get clear tokenBudget thread resume turn interrupt Codex CLI /goal pause resume`. — <https://learn.chatgpt.com/docs/developer-commands#set-or-view-a-task-goal-with-goal>
- [External fact] `codex app-server generate-json-schema` выдаёт схему для запущенной версии CLI. — <https://learn.chatgpt.com/docs/app-server#message-schema>

### План и параллельные роли {#n12}

- tags: план, подагенты
- layout: up
- position: -178, -1392

`/plan` подходит для подготовки плана. Подагентам можно явно передать независимые роли и собрать их результаты. Для двух исполнителей с правом записи MarkView может разнести задачи по worktree.

#### Evidence

- [External fact] Codex CLI документирует `/plan` и `codex exec --worktree` для новых запусков. — <https://learn.chatgpt.com/docs/developer-commands?surface=cli>
- [External fact] Codex поддерживает параллельных подагентов и пользовательские роли из TOML. Для предсказуемого делегирования документация советует запросить его явно. — <https://learn.chatgpt.com/docs/agent-configuration/subagents>
- [AI inference] Для параллельного анализа достаточно разделения ролей, а запись стоит изолировать на уровне Git.

### Согласование плана в Codex CLI {#n77}

- tags: CLI, план

В интерактивном терминале `/plan` переводит текущий чат в режим планирования. Команда принимает текст задачи сразу после `/plan`, а также вставленный текст и изображения. Во время активного хода slash-команду можно поставить в очередь клавишей `Tab`. После согласования вариант **Yes, clear context and implement** переносит полный план в новый чат.

#### Evidence

- [External fact] Документация `/plan` описывает переключение режима, вложения и переход к реализации в новом чате. Если перенести полный план не удаётся, Codex оставляет открытым текущий чат. — <https://learn.chatgpt.com/docs/developer-commands#switch-to-plan-mode-with-plan>
- [External fact] CLI разбирает поставленные в очередь slash-команды после завершения текущего хода. — <https://learn.chatgpt.com/docs/developer-commands#built-in-slash-commands>
- [AI inference] Если реализация начнётся в новом чате, в сам план стоит включить исходные ограничения, границы задач и критерии проверки.

### События плана в App Server {#n82}

- tags: App Server, события

Программный клиент может выбрать режим через `turn/start.collaborationMode`. Для отображения хода работы служит `turn/plan/updated` со статусами `pending`, `inProgress` и `completed`. Текст предложенного плана можно показывать из `item/plan/delta`, а для согласования брать окончательный `plan` из `item/completed`.

#### Evidence

- [External fact] `collaborationMode/list` перечисляет экспериментальные пресеты. В `turn/start.collaborationMode` значение `settings.developer_instructions: null` применяет встроенные инструкции выбранного режима. — <https://learn.chatgpt.com/docs/app-server#api-overview>
- [External fact] `turn/plan/updated` передаёт список шагов и их статусы. Окончательный текст плана может отличаться от склеенных дельт, поэтому документация указывает использовать `plan` из `item/completed`. — <https://learn.chatgpt.com/docs/app-server#turn-events>
- [Project fact] Существующий `RemoteCodexContext` использует App Server для обновления инструкций сохранённой ветки перед передачей её терминалу. Эта операция проходит без запуска хода модели. — `MarkView/Models/Remote/RemoteCodexContext.swift:7`

### Постановка подзадач и сбор результатов {#n78}

- tags: подагенты, CLI

В запросе на делегирование полезно задать каждому подагенту свой вопрос, формат результата и момент, к которому ведущий должен дождаться ответа. Например, один агент может найти точки входа функции, а другой — подобрать существующие тесты для проверки. В CLI команда `/subagents` открывает отдельную ветку для просмотра или продолжения работы.

#### Evidence

- [External fact] В локальном Codex делегирование запускает прямой запрос пользователя или применимая инструкция проекта либо навыка. OpenAI рекомендует задать разбиение работы, условие ожидания и ожидаемый результат. — <https://learn.chatgpt.com/docs/agent-configuration/subagents#triggering-subagent-workflows>
- [External fact] Codex умеет перенаправлять уточнения, ждать запрошенные результаты и закрывать ветки подагентов. Каждый подагент выполняет собственные вызовы модели и инструментов, увеличивая общий расход токенов. — <https://learn.chatgpt.com/docs/agent-configuration/subagents#orchestration-and-thread-controls>
- [External fact] `/subagents` переключает активную ветку терминала на выбранного подагента для просмотра или продолжения его работы. — <https://learn.chatgpt.com/docs/developer-commands#switch-agent-threads-with-subagents>

### События делегирования для интерфейса {#n83}

- tags: App Server, MarkView

App Server отдаёт элемент `collabToolCall` со статусом и идентификаторами связанных веток. По этим данным интерфейс мог бы показать связь подзадачи с ведущим ходом и её состояние. Текущий парсер одноразовых запусков MarkView извлекает текст ответа, отдельные события активности и итог хода.

#### Evidence

- [External fact] Тип `collabToolCall` включает `tool`, `status`, `senderThreadId`, а при наличии также `receiverThreadId`, `newThreadId` и `agentStatus`. Итоговое состояние элемента приходит через `item/completed`. — <https://learn.chatgpt.com/docs/app-server#items>
- [Project fact] `CodexStreamParser` передаёт активность для команд, рассуждений и поиска, извлекает `agent_message` и обрабатывает результат хода. Отдельной обработки событий подагентов в этом парсере нет. — `MarkView/Models/AI/Providers/CodexProvider.swift:286`

### Роли и предел параллелизма {#n79}

- tags: TOML, роли

Codex предоставляет встроенные роли `default`, `worker` и `explorer`. Для повторяемой роли можно завести отдельный TOML-файл с `name`, `description` и `developer_instructions` в `.codex/agents/` для проекта или `~/.codex/agents/` для пользователя. Параметр `agents.max_concurrent_threads_per_session` ограничивает одновременно открытые ветки подагентов, исключая ведущую.

#### Evidence

- [External fact] Имя роли берётся из `name`. Пользовательская роль с именем встроенной получает приоритет. Заданные в файле роли `model` и `model_reasoning_effort` имеют приоритет над значениями, разрешёнными при запуске подагента. — <https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents>
- [External fact] `agents.max_threads` поддерживается как прежнее имя `agents.max_concurrent_threads_per_session`. При отсутствии настройки предел выбирает Codex. — <https://learn.chatgpt.com/docs/agent-configuration/subagents#global-settings>

### Права подагентов в MarkView {#n80}

- tags: права, Remote Work

Подагенты наследуют действующие ограничения песочницы и правила подтверждения ведущего хода. Просьба к `explorer` только читать файлы задаёт поведение, а доступ на уровне файловой системы определяется родительским запуском. Локальный AI Terminal MarkView передаёт Codex флаг полного доступа. Для Remote Work провайдер задаёт `read-only`, `never` и `features.multi_agent=false`.

#### Evidence

- [External fact] Применяются текущие права родительского хода, включая изменения через `/permissions`. TOML роли не переопределяет песочницу и правила подтверждения. В неинтерактивном запуске действие, требующее нового разрешения, завершается ошибкой, если запросить его невозможно. — <https://learn.chatgpt.com/docs/agent-configuration/subagents#approvals-and-sandbox-controls>
- [Project fact] `AITerminalsController.startupCommand` добавляет `tool.fullAccessArgs` к локальной команде запуска ассистента. — `MarkView/Models/Workspace/AITerminalsController.swift:94`
- [Project fact] Значение `fullAccessArgs` для Codex включает `--dangerously-bypass-approvals-and-sandbox`. — `MarkView/Models/AI/Providers/CodexProvider.swift:13`
- [Project fact] `CodexProvider.arguments` для Remote Work задаёт `--sandbox read-only`, `--ask-for-approval never` и отключает `features.multi_agent`. — `MarkView/Models/AI/Providers/CodexProvider.swift:347`

### Отдельные запуски с worktree {#n81}

- tags: Git, worktree, CLI

Для двух исполнителей с правом записи можно запустить две локальные сессии в отдельных рабочих копиях. Codex CLI создаёт управляемый worktree для нового `codex exec --worktree` или для `codex exec fork <SESSION_ID> --worktree`. Одноразовый запуск MarkView сейчас использует `--ephemeral`. Для управляемого worktree ему понадобится отдельный сценарий запуска либо заранее созданная рабочая копия, переданная через `-C`.

#### Evidence

- [External fact] `codex exec --worktree` требует локального выполнения и несовместим с `resume`, `review`, `--ephemeral` и `--ignore-user-config`. Для ответвления сохранённого контекста документирован `codex exec fork <SESSION_ID> --worktree`. — <https://learn.chatgpt.com/docs/developer-commands?surface=cli#cli-codex-exec>
- [Project fact] Одноразовый вызов провайдера передаёт `--sandbox read-only`, `--ephemeral` и рабочий каталог через `-C`. — `MarkView/Models/AI/Providers/CodexProvider.swift:237`
- [Project fact] При общей рабочей копии руководство MarkView предписывает использовать `git worktree add` для отдельной ветки, чтобы сохранить незакоммиченные изменения других сессий. — `CLAUDE.md:148`
- [AI inference] Передача отдельного каталога через `-C` задаст рабочую копию. Для исполнителя потребуется также явно выбрать подходящий режим записи, поскольку существующий одноразовый путь запускается с `read-only`.

### Просмотр рабочих копий в MarkView {#n84}

- tags: Git, интерфейс

После создания отдельной копии её можно открыть из меню **Working Copies** на панели Git. MarkView получает список из `git worktree list --porcelain` и подсчитывает изменённые пути в каждой рабочей копии.

#### Evidence

- [Project fact] `GitClient.loadWorktrees` загружает рабочие копии через `git worktree list --porcelain`, скрывает список при единственной копии и подсчитывает изменения через `git status` для каждой копии с рабочим каталогом. — `MarkView/Models/Git/GitClient.swift:485`
- [Project fact] Меню **Working Copies** показывает название ветки и папки. Выбор вызывает `openFolder` для пути рабочей копии. — `MarkView/Views/Git/GitView.swift:841`

### Поисковые запросы ветки {#n85}

- tags: источники

- `Codex CLI slash command /plan plan mode app server proposed plan collaboration mode`
- `Codex subagents custom roles agents max_threads max_depth sandbox permissions`
- `Codex CLI exec --worktree and Codex app worktrees parallel agents`
- `Codex plan mode implement this plan switch default mode proposed plan approvals`
- `Codex non-interactive JSONL collab agent tool call todo list app server subagent events`

### CLI и отдельный ревьюер {#n13}

- tags: CLI, ревью
- layout: right
- position: 369, -1236

`codex exec --json` подходит для коротких этапов со структурированным ответом. Для ревью можно вызвать `codex review` на заданном коммите или относительно базы. App Server предлагает отдельный вызов `review/start`.

#### Evidence

- [Project fact] Текущий разовый запуск использует `codex exec --json` с песочницей `read-only` и поддерживает схему ответа. — `MarkView/Models/AI/Providers/CodexProvider.swift:235`
- [External fact] CLI документирует JSONL, `--output-schema`, `workspace-write` и отдельный `codex review` с выбором цели ревью. — <https://learn.chatgpt.com/docs/non-interactive-mode>
- [External fact] `review/start` запускает встроенного ревьюера для треда и сообщает о ходе работы. — <https://learn.chatgpt.com/docs/app-server>
- [Project fact] MarkView передаёт запрос в Codex через stdin и всегда добавляет `--ephemeral` и `--skip-git-repo-check`. Одноразовый запуск можно выполнить вне Git-репозитория. — `MarkView/Models/AI/Providers/CodexProvider.swift:237`
- [Project fact] Перед передачей схемы MarkView рекурсивно закрывает объекты через `additionalProperties: false` и делает все объявленные свойства обязательными. Открытый объект без объявленных свойств превращается в схему пустого объекта. — `MarkView/Models/AI/Providers/CodexProvider.swift:261`
- [Project fact] В потоке `--json` MarkView извлекает текст ответа из `item.completed` с типом `agent_message`. `turn.failed` записывается как ошибка запуска, а отдельное событие `error` сохраняется как предупреждение на случай отсутствия ответа. — `MarkView/Models/AI/Providers/CodexProvider.swift:298`
- [Project fact] Ревью спецификации в MarkView запрашивает у выбранного ассистента массив `findings` с тайм-аутом 900 секунд. Приложение пропускает уже известные заголовки и сохраняет новые замечания в записи `F`. Это отдельный сценарий продукта со своей схемой результата. — `MarkView/Models/Lifecycle/FeatureAI.swift:1128`
- [Project fact] Клиент App Server в `RemoteCodexContext` использует `thread/list`, `thread/resume` и `thread/inject_items`, чтобы обновить инструкции перед возвратом в терминал. Этот путь не запускает ход модели или `review/start`. — `MarkView/Models/Remote/RemoteCodexContext.swift:7`
- [External fact] `codex review --uncommitted` охватывает индексированные, неиндексированные и неотслеживаемые изменения. `--uncommitted`, `--base`, `--commit` и пользовательский `PROMPT` взаимоисключающие. `--title` доступен только с `--commit`. Поисковый запрос «Codex CLI codex review JSON output non-interactive codex exec review». Поиск по странице «Use `--title` only with `--commit`.» — <https://learn.chatgpt.com/docs/developer-commands#codex-review>
- [External fact] По умолчанию `review/start` работает в переданном треде (`delivery: "inline"`). Для отдельного ревью документация описывает `thread/start` для чистой истории или `thread/fork` для копии существующей истории, после чего `review/start` вызывается с новым `threadId`. Итоговый текст приходит в `item/completed` с `item.type: "exitedReviewMode"` в поле `review`. Поисковый запрос «Codex App Server review/start detached inline exitedReviewMode». — <https://learn.chatgpt.com/docs/app-server#review>
- [External fact] `--ephemeral` отключает сохранение файлов истории сеанса на диск. При обычном запуске `codex exec resume` позволяет продолжить сохранённую сессию по её ID или выбрать последнюю через `--last`. — <https://developers.openai.com/codex/noninteractive#resume-a-non-interactive-session>

### GitHub Copilot {#n4}

- tags: Copilot
- position: -773, -415

Планирование, агентные режимы и ревью Copilot с учётом различий между CLI и сервисами GitHub.

### Plan, Autopilot и цель {#n14}

- tags: цель, лимиты
- position: -1350, -848

MarkView уже передаёт задачу через `/autopilot`. Актуальный Copilot CLI принимает и `/goal` как синоним при явной цели. Для крупных изменений можно сначала согласовать план, затем запустить Autopilot. Порог AI Credits и число автоматических продолжений ограничивают разные вещи.

#### Evidence

- [Project fact] CopilotProvider формирует `/autopilot` для терминального запуска. — `MarkView/Models/AI/Providers/CopilotProvider.swift:21`
- [External fact] `/goal` и `/autopilot` принимают явную цель и лимит AI Credits для неё. `--max-autopilot-continues` действует вне активной цели. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference>
- [External fact] GitHub описывает переход из Plan в Autopilot с возможностью проверки плана перед исполнением. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode>

### Согласование плана в Copilot CLI {#n69}

- tags: Plan, CLI

В интерактивной сессии `Shift`+`Tab` открывает Plan, а `/plan [PROMPT]` запрашивает план реализации. План можно уточнить, открыть снова через `/session plan` и затем принять действием `Accept plan and continue in Autopilot execution mode`.

#### Evidence

- [External fact] GitHub описывает интерактивный переход из Plan в Autopilot с правкой и явным принятием плана. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#moving-from-a-plan-to-autopilot-mode>
- [External fact] `/plan [PROMPT]` составляет план реализации до написания кода. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#slash-commands-in-the-interactive-interface>
- [External fact] `/session plan` показывает текущий план сессии. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/work-with-multiple-sessions#session-slash-commands>

### Автоматический переход из Plan {#n70}

- tags: Plan, Autopilot

`copilot --plan --mode autopilot` начинает реализацию сразу после готовности плана, пропуская его ручное утверждение. Для этого сочетания нужен именно `--mode autopilot`. Сочетание `--plan --autopilot` справочник исключает.

#### Evidence

- [External fact] GitHub описывает автоматический переход к исполнению после составления плана при запуске с `--plan --mode autopilot`. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#moving-from-a-plan-to-autopilot-mode>
- [External fact] В справочнике `--plan` совместим с `--mode autopilot`, а сочетание с флагом `--autopilot` запрещено. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference>

### Явная цель и панель прогресса {#n71}

- tags: цель, CLI

MarkView отправляет Copilot явную цель. В ней уже есть требование сверить реализацию со спецификацией и, если задано, выполнить условия Definition of Done. В CLI панель активной цели показывает её текст, расход AI Credits и ход списка задач. При вызове команды без текста CLI выводит намерение из контекста и показывает последний запрос.

#### Evidence

- [Project fact] `HandoffPrompt.feature` включает проверку реализации по спецификации и добавляет непустой `done.goalText()` к тексту цели. — `MarkView/Models/Lifecycle/HandoffPrompt.swift:22`
- [Project fact] `CopilotProvider.goalPrompt` передаёт текст цели в `/autopilot` как аргумент. — `MarkView/Models/AI/Providers/CopilotProvider.swift:21`
- [External fact] Справочник различает явную цель и намерение, выведенное из контекста, и описывает закреплённую панель активной цели с расходом и прогрессом. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#slash-commands-in-the-interactive-interface>

### Поисковые запросы ветки {#n76}

- tags: источники

- `site:docs.github.com Copilot CLI plan autopilot goal max-autopilot-continues AI Credits /goal`
- `site:docs.github.com GitHub Copilot CLI plan autopilot approve permissions /plan exit plan mode /goal status stop`
- `site:github.com/github/copilot-cli /goal autopilot goal verify completed ai credits`
- `site:docs.github.com setting an AI credit session limit GitHub Copilot CLI max-ai-credits limits soft cap quota`
- `site:github.com/github/copilot-cli releases goal explicit objective completion verification /goal autopilot`

### Лимит цели и возобновление {#n72}

- tags: AI Credits, лимиты

`/goal OBJECTIVE --max-ai-credits N` задаёт бюджет явной цели. При исчерпании бюджета Copilot ставит её на паузу. Команда `/goal --max-ai-credits N` без нового текста возобновляет ту же цель с новым бюджетом на указанную сумму. Вне активной цели `--max-autopilot-continues` ограничивает число автоматических продолжений, по умолчанию до пяти.

#### Evidence

- [External fact] CLI показывает расход при паузе и позволяет открыть новый бюджет для прежней цели из панели или командой `/goal --max-ai-credits N`. Введённая сумма целиком становится новым пределом. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#slash-commands-in-the-interactive-interface>
- [External fact] `--max-autopilot-continues=COUNT` применяется вне активной цели. Значение по умолчанию равно 5. Допустимы целые неотрицательные числа. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference>

### Расхождение документации о `/limits` {#n73}

- tags: AI Credits, проверка

Справочник описывает `/limits set max-ai-credits VALUE` как мягкий предел на ответ со сбросом при каждом пользовательском сообщении. Руководство описывает накопительный расход на всю интерактивную сессию и минимум 30 AI Credits. Область действия `/limits` в установленной версии CLI остаётся открытым вопросом.

#### Evidence

- [External fact] Справочник указывает мягкий лимит на ответ и его сброс при каждом пользовательском сообщении. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#slash-commands-in-the-interactive-interface>
- [External fact] Руководство указывает общий расход по сообщениям интерактивной сессии, минимум в 30 AI Credits и возможность небольшого превышения, пока текущий ответ завершается. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/set-session-limit#setting-an-ai-credit-session-limit>
- [Open assumption] Какой из описанных вариантов реализован в установленной версии Copilot CLI, живым запуском не проверено.

### Разрешения и уточняющие вопросы {#n74}

- tags: Autopilot, права

Autopilot отвечает за автоматическое продолжение работы. MarkView добавляет `--allow-all` при запуске терминала Copilot, а уточняющие вопросы в CLI регулируются отдельным флагом `--no-ask-user`. Если Autopilot работает с `Manual Approval`, Copilot автоматически отклоняет вызовы инструментов, требующие разрешения.

#### Evidence

- [Project fact] `startupCommand` добавляет `tool.fullAccessArgs` к команде запуска терминала агента. — `MarkView/Models/Workspace/AITerminalsController.swift:94`
- [Project fact] У Copilot `fullAccessArgs` содержит `--allow-all`. — `MarkView/Models/AI/Providers/CopilotProvider.swift:13`
- [External fact] GitHub описывает автоматическое отклонение действий, требующих одобрения, при `Manual Approval` в Autopilot. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#configuring-permissions>
- [External fact] Autopilot управляет продолжением, `--allow-all` управляет правами на действия, а `--no-ask-user` отключает уточняющие вопросы. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#comparing-autopilot-mode---allow-all-and---no-ask-user>

### Остановка и режим следующего запроса {#n75}

- tags: Autopilot, остановка

Двойное нажатие `Esc` прерывает текущий ход. `Shift`+`Tab` позволяет выбрать режим для следующего запроса. По умолчанию CLI остаётся в Autopilot после завершения задачи. Настройка `/settings stayInAutopilot false` возвращает CLI в Interactive после каждой завершённой задачи.

#### Evidence

- [External fact] Руководство описывает двойное нажатие `Esc` для прерывания хода и `Shift`+`Tab` для смены режима. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#stopping-and-reviewing-work>
- [External fact] `stayInAutopilot` включён по умолчанию и определяет режим следующего запроса после завершения текущей задачи. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/use-autopilot-mode#choosing-the-mode-for-the-next-task>

### Fleet и границы ACP {#n15}

- tags: параллельность, ACP

`/fleet` распределяет независимые задачи по подагентам. Флаг `--fleet` поддерживает запуск с `-p`. Текущий ACP-профиль MarkView годится для локального чтения, а управляемый Fleet потребует отдельного способа запуска.

#### Evidence

- [External fact] Документация показывает Plan → Autopilot + Fleet, дочерних агентов и мониторинг через `/tasks`. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/speed-up-task-completion>
- [External fact] В CLI `--fleet` поддерживает неинтерактивный запуск с `-p` или stdin. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference>
- [Project fact] ACP запускается только с `view`, `grep`, `glob`. В этом профиле отключены shell, редактирование, веб и подагенты. — `MarkView/Models/AI/Providers/CopilotProvider.swift:29`

### Несовместимость `--fleet` и `--acp` {#n62}

- tags: Fleet, ACP

GitHub прямо исключает сочетание `--fleet` с `--acp`. Набор инструментов Copilot фиксируется при старте ACP-сервера, поэтому `session/new` сохраняет ограничения профиля MarkView. Включение Fleet флагом требует отдельного запуска CLI.

#### Evidence

- [External fact] Руководство Fleet прямо указывает, что `--fleet` не поддерживается в режиме ACP-сервера. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/speed-up-task-completion#starting-in-fleet-mode-from-the-command-line>
- [External fact] Фильтры инструментов задаются аргументами запуска ACP-сервера и наследуются его сессиями. Через `session/new` изменить их нельзя. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server#options-applied-to-every-session>
- [Project fact] `CopilotProvider.launchProfile` передаёт `--acp` и ограничивает инструменты списком `view`, `grep`, `glob`. — `MarkView/Models/AI/Providers/CopilotProvider.swift:29`
- [External fact] Справочник CLI указывает `task` как инструмент запуска подагентов. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#agent-and-task-delegation-tools>

### Обнаружение команд в ACP {#n63}

- tags: ACP, команды

Copilot объявляет доступные slash-команды через `available_commands_update`. Текущий обработчик MarkView пропускает это уведомление, поэтому поддержка `/fleet` в конкретной сессии остаётся непроверенной. Когда команды нет в объявленном списке, ACP передаёт её текст модели как обычный запрос.

#### Evidence

- [External fact] GitHub называет `available_commands_update` актуальным списком команд сессии. Команды вне списка передаются модели как текст. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server#discovering-available-commands>
- [Project fact] `RunState.receive` обрабатывает `agent_message_chunk`, `agent_thought_chunk` и `tool_call`, а остальные типы пропускает. — `MarkView/Models/AI/ACPAssistant.swift:443`
- [Open assumption] Нужно проверить, объявляет ли установленная версия Copilot `/fleet` для сессии с профилем MarkView. Запуск CLI в рамках исследования не проверялся.

### Поисковые запросы ветки {#n68}

- tags: поиск

- `GitHub Copilot CLI fleet subagents tasks non-interactive --fleet official documentation`
- `GitHub Copilot CLI ACP session modes fleet initialize agent client protocol official GitHub`
- `GitHub Copilot CLI JSONL fleet subagent.started subagent.completed GitHub Copilot SDK events session event schema`

### Управление подзадачами через `/tasks` {#n64}

- tags: терминал, отмена

В терминальном Copilot через `/tasks` можно открыть детали подзадачи и остановить выбранный процесс. В ACP эта команда недоступна. При отмене текущий ACP-клиент MarkView отправляет `session/cancel` для активной сессии и завершает дочерний процесс.

#### Evidence

- [External fact] В терминале `/tasks` показывает подзадачи Fleet и позволяет открыть детали или остановить выбранный процесс. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/speed-up-task-completion#monitoring-progress>
- [External fact] GitHub перечисляет `/tasks` среди команд, требующих интерактивного терминала. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server#commands-that-cannot-be-used-over-acp>
- [Project fact] `ACPConnection.cancel()` отправляет `session/cancel` с идентификатором сессии и планирует завершение дочернего процесса. — `MarkView/Models/AI/ACPAssistant.swift:565`

### Машиночитаемый вывод Fleet {#n65}

- tags: CLI, JSONL

Для отдельного запуска `copilot --fleet -p` CLI поддерживает `--output-format json` с выдачей JSONL. MarkView понадобится обработчик этого потока. Состав событий подагентов в stdout остаётся проверить на целевой версии Copilot.

#### Evidence

- [External fact] Программный справочник документирует `--fleet` для `-p` и формат JSONL для `--output-format json`. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference#command-line-options>
- [Project fact] Текущий обработчик ACP собирает ответ из уведомлений `agent_message_chunk`. — `MarkView/Models/AI/ACPAssistant.swift:443`
- [AI inference] Потоку JSONL отдельного запуска Fleet потребуется собственный разбор, поскольку текущий обработчик ожидает уведомления ACP.
- [Open assumption] Наличие и поля событий подагентов в stdout конкретной версии CLI не проверялись.

### Запуск и события Fleet через SDK {#n66}

- tags: SDK, RPC, события

Copilot SDK предоставляет экспериментальный RPC `session.fleet.start`. События `subagent.started`, `subagent.completed` и `subagent.failed` позволяют показать запуск, успех и сбой отдельного подагента. Для интеграции с таким API GitHub рекомендует фиксировать версии SDK и CLI.

#### Evidence

- [External fact] GitHub документирует экспериментальный RPC `session.fleet.start` и рекомендует фиксировать версии SDK и среды выполнения CLI. — <https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/fleet-mode#starting-fleet-mode>
- [External fact] В SDK события завершения и сбоя связываются с запуском подагента через `toolCallId`. Событие сбоя содержит `error`. — <https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/streaming-events#sub-agent-and-skill-events>

### Инструкции и права подагентов {#n67}

- tags: подагенты, права, инструкции

Подагенты Copilot наследуют права родительской сессии. Получение инструкций репозитория зависит от типа агента. Для пользовательского подагента требуется `include-custom-instructions: true`, а `--no-custom-instructions` отключает загрузку для всей сессии. В MarkView этот флаг входит в профиль ACP, а `CLAUDE.md` задаёт обязательный порядок доставки изменений приложения.

#### Evidence

- [External fact] Подагенты наследуют разрешения родительской сессии и не могут их расширять. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#file-and-subagent-permissions>
- [External fact] `general-purpose` получает инструкции репозитория, пользовательский подагент получает их при `include-custom-instructions: true`, а `--no-custom-instructions` имеет приоритет для всех агентов. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#repository-custom-instructions-for-subagents>
- [Project fact] `CopilotProvider.launchProfile` передаёт `--no-custom-instructions`. — `MarkView/Models/AI/Providers/CopilotProvider.swift:29`
- [Project fact] `CLAUDE.md` требует ветку, pull request и его слияние после проверок для каждого изменения приложения. — `CLAUDE.md`

### Ревью в CLI и GitHub {#n16}

- tags: ревью, GitHub
- position: -1280, -19

`/review` подходит для проверки локальных изменений до коммита. GitHub Copilot Code Review работает с PR и может запускаться автоматически. Для этапа Cockpit удобно привязывать замечания к конкретному снимку изменений.

#### Evidence

- [External fact] CLI позволяет сузить `/review` до запроса, пути или шаблона файлов. — <https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/agentic-code-review>
- [External fact] GitHub Copilot Code Review оставляет замечания и предложения в GitHub PR и имеет отдельные правила доступности. — <https://docs.github.com/en/copilot/concepts/agent-capabilities/agent-powered-workflows-and-operations/code-review>
- [AI inference] Результат этапа можно привязать к проверенному SHA или сохранённому diff.

### Google Antigravity {#n5}

- tags: Antigravity
- height: 43
- layout: left
- position: -536, 535

Режимы работы Antigravity и поверхность, доступная из MarkView.

### Plan, Goal и тайм-аут {#n17}

- tags: цель, лимиты
- position: -877, 413

В `agy` доступны `/plan` с согласованием плана и `/goal` с проверяемым условием завершения. MarkView сейчас передаёт Antigravity цель обычным текстом. Для разового запуска можно отдельно передать `--print-timeout` и получить структурированный ответ.

#### Evidence

- [Project fact] AntigravityProvider использует стандартный `goalPrompt` из AssistantProvider, который формирует текст задачи. — `MarkView/Models/AI/Providers/AssistantProvider.swift:147`
- [External fact] `/plan` останавливается на согласовании, а `/goal` продолжает работу без встроенного лимита итераций и сохраняет правила разрешений. — <https://antigravity.google/docs/commands/goal>
- [External fact] Headless CLI поддерживает `--print-timeout`, `stream-json` и `--json-schema`. — <https://antigravity.google/docs/cli/headless/>

### Вход в режим планирования {#n86}

- tags: CLI, план

В интерактивном `agy` команда `/plan <задача>` запускает разбор задачи, а `/plan` без аргументов начинает уточнение. `--mode=plan` добавляет инструкции `/plan` к запросам сессии и показывает план в терминале перед правками. Для перехода к исполнению через `/goal` Google предлагает передать агенту уже согласованный план.

#### Evidence

- [External fact] Документация описывает обе формы `/plan` в интерактивном CLI и отображение плана в терминале. — <https://antigravity.google/docs/plan/>
- [External fact] `--mode=plan` добавляет инструкции `/plan` к запросам, а агент изучает файлы средствами чтения и представляет план на согласование перед правками. — <https://antigravity.google/docs/cli/modes#analyze-tasks-before-editing-with-plan-mode>
- [External fact] Для крупных задач Google предлагает сначала согласовать подход через `/plan` или `/grill-me`, затем передать утверждённый план в `/goal`. — <https://antigravity.google/docs/commands/goal#write-effective-goals>

### Подтверждение плана в терминале {#n91}

- tags: согласование, TUI

Команда `/artifact` или `Ctrl+R` открывает список артефактов, где можно просмотреть план и отправить решение агенту. Параметр `artifactReviewPolicy` управляет ожиданием проверки артефакта. Разрешения на правку файлов действуют отдельно.

#### Evidence

- [External fact] Документация CLI описывает просмотр артефактов, принятие клавишей `y`, отклонение клавишей `n` и отправку решений по `Esc`. — <https://antigravity.google/docs/cli/artifacts/#overview-of-artifact>
- [External fact] `artifactReviewPolicy` задаёт ожидание ревью артефакта, а права на правку файлов определяются отдельно. — <https://antigravity.google/docs/cli/reference#configuration-keys-settingsjson>

### Жизненный цикл `/goal` {#n87}

- tags: CLI, цель

В одной беседе активна одна цель. При попытке завершить ход встроенный хук напоминает исходную задачу и просит подтвердить каждый результат файлами, тестами или логами. Просьба остановиться отменяет цель, а новая команда `/goal` заменяет текущую.

#### Evidence

- [External fact] Google описывает перехват попыток завершить ход, повторную сверку результатов с исходным запросом, явную отмену и замену активной цели новой. — <https://antigravity.google/docs/commands/goal#how-goal-mode-works>

### Возврат к беседе после прерывания {#n92}

- tags: возобновление

CLI восстанавливает беседу в её рабочем каталоге через `/resume` или `--continue`. Для оркестрации длительной задачи отдельно важно проверить, восстанавливается ли активное состояние `/goal` после принудительного завершения процесса.

#### Evidence

- [External fact] Google описывает привязку истории к рабочему каталогу и возобновление беседы через интерактивный выбор или `--continue`. — <https://antigravity.google/docs/cli/conversations/#resuming-sessions>
- [Project fact] `AntigravityProvider` задаёт `--continue` для возобновления терминальной сессии. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:12`
- [Open assumption] Восстановление контекста беседы может сохранять активную цель и её счётчики после принудительного завершения процесса. Это требует проверки на установленной версии `agy`.

### Передача задачи в терминал MarkView {#n88}

- tags: MarkView, терминал

`Implement with AI` отправляет в терминал Antigravity текст спецификации с доступным `DefinitionOfDone` и просьбой продолжать до проверки. Для запуска встроенного режима цели в этой беседе оператор может ввести `/goal <цель>` в интерактивном `agy`.

#### Evidence

- [Project fact] `startImplementation` вызывает `sendToAssistant(submit: true)` и формирует текст через `HandoffPrompt.feature`. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:342`
- [Project fact] `HandoffPrompt.feature` добавляет текст `DefinitionOfDone` и передаёт задачу в `goalPrompt` с завершающей просьбой о проверке. — `MarkView/Models/Lifecycle/HandoffPrompt.swift:21`
- [Project fact] `AntigravityProvider` использует стандартную реализацию `goalPrompt`, которая соединяет задачу и завершающую просьбу. — `MarkView/Models/AI/Providers/AssistantProvider.swift:147`
- [External fact] Google документирует ручной ввод `/goal` с целью в интерактивном приглашении CLI. — <https://antigravity.google/docs/commands/goal#antigravity-cli>

### Дедлайн CLI и тайм-аут MarkView {#n89}

- tags: тайм-аут, MarkView

В print mode `--print-timeout` по умолчанию равен `0s`, то есть время ожидания ответа не ограничено самим `agy`. Для обычного разового запроса MarkView использует собственный тайм-аут `CLICompletion` с базовым значением 180 секунд. При его срабатывании завершается вся группа локального процесса, а вызывающий код получает `Failure.timedOut`.

#### Evidence

- [External fact] Справочник определяет `--print-timeout` как предельное время ожидания ответа в print mode и указывает значение по умолчанию `0s`. — <https://antigravity.google/docs/cli/headless/#flag-reference>
- [Project fact] Обычный запуск `AntigravityProvider.launch` формирует аргументы print mode без `--print-timeout`. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:62`
- [Project fact] `CLICompletion.Request.timeout` задаёт общий лимит с базовым значением 180 секунд. `nil` предусмотрен для долгой работы с явной отменой. — `MarkView/Models/AI/CLICompletion.swift:68`
- [Project fact] `Invocation` передаёт лимит в `SubprocessSpec`, а при истечении времени возвращает `Failure.timedOut`. — `MarkView/Models/AI/CLICompletion.swift:315`

### Два лимита запроса `/usage` {#n93}

- tags: квоты, тайм-аут

Опрос квот в MarkView запускает отдельный `agy -p /usage` с `--print-timeout 20s`. Внешний лимит транспорта составляет 25 секунд, чтобы ограничить ожидание процесса, в том числе при запросе входа.

#### Evidence

- [Project fact] `AntigravityUsage.fetchOfficial` передаёт CLI лимит 20 секунд и устанавливает транспортный тайм-аут 25 секунд. Комментарий описывает ожидание кода входа при отсутствии авторизации. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:135`

### Итог разового запуска {#n90}

- tags: NDJSON, результат

Разовый вызов MarkView передаёт запрос в `stdin` как событие `user` и читает NDJSON. `step_update` показывает промежуточный текст и обращения к инструментам, а итоговый `result` несёт `status`, `response` и, при заданной схеме, `structured_output`. Чтобы судить о выполнении задачи, нужно сверить результат с её критериями и учесть отказы в разрешениях.

#### Evidence

- [Project fact] `AntigravityProvider.launch` передаёт один `user` через `stdin`, включает `stream-json` для ввода и вывода и добавляет `--json-schema`, если схема задана. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:62`
- [Project fact] `AntigravityStreamParser` обрабатывает `step_update`, читает `structured_output` и `denied_actions` из `result` и превращает статус, отличный от `SUCCESS`, в ошибку. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:84`
- [External fact] Google описывает поля `result` и уточняет, что `SUCCESS` означает завершение запуска с ответом. Действие, требующее недоступного подтверждения, может быть отклонено с сохранением кода выхода `0`. — <https://antigravity.google/docs/cli/headless/#handle-exit-codes-and-errors>
- [AI inference] Технический успех процесса или соответствие ответа схеме сами по себе не подтверждают выполнение критериев задачи.

### Граница поддержки `/goal` через NDJSON {#n94}

- tags: NDJSON, совместимость

Руководство потокового режима указывает, что команды, обрабатываемые непосредственно CLI, например `/usage`, завершают потоковую сессию с `ERROR`. Для `/goal` показан интерактивный запуск. Поддержку этой команды в NDJSON-вызове MarkView нужно проверять на установленной версии `agy`.

#### Evidence

- [External fact] Руководство по `/goal` показывает запуск в интерактивном приглашении CLI. — <https://antigravity.google/docs/commands/goal#antigravity-cli>
- [External fact] Для команд, обрабатываемых непосредственно CLI, руководство по потоковому вводу указывает итоговый `ERROR` и код выхода `2`, приводя `/model` и `/usage` в качестве примеров. — <https://antigravity.google/docs/cli/headless/#unsupported-messages>
- [Open assumption] Сообщение `user` с `/goal` может активировать встроенную цель и дождаться её проверенного завершения в разовом вызове, который закрывает `stdin`. Этот сценарий требует отдельной проверки.

### Запросы и границы проверки ветки {#n95}

- tags: источники

Сверка выполнена по исходникам MarkView и официальной документации Google. Проверка поведения установленного `agy` остаётся открытой. Выполнены два поисковых запроса.

- `site:antigravity.google Antigravity CLI /plan /goal plan approval goal completion pause`
- `site:antigravity.google Antigravity CLI --print-timeout stream-json --json-schema headless timeout exit`

#### Evidence

- [External fact] Открыто официальное руководство Google по планированию. — <https://antigravity.google/docs/plan/>
- [External fact] Открыто официальное руководство Google по использованию цели. — <https://antigravity.google/docs/commands/goal>
- [External fact] Открыто официальное руководство Google по разовому и потоковому запускам. — <https://antigravity.google/docs/cli/headless/>

### Параллельные и последовательные этапы {#n18}

- tags: workflow, подагенты
- position: -1124, 919

`/run-workflow` координирует подагентов через Python с именованными фазами, `parallel()` и `pipeline()`. Это вариант для сложного внутреннего этапа Cockpit. Отдельный режим Orchestrator связывает модель-планировщик с моделью-исполнителем и зависит от тарифа.

#### Evidence

- [External fact] Dynamic Workflows работает в приложении и CLI на всех планах. Подагенты возвращают ответы по JSON Schema, а скрипт можно сохранить для повторного запуска. — <https://antigravity.google/docs/dynamic-workflows>
- [External fact] Режим Orchestrator доступен на указанных платных планах и разделяет планирование и исполнение между моделями. — <https://antigravity.google/docs/features?tab=cli>
- [AI inference] MarkView может принять итог такого этапа, сохранив собственный порядок переходов дальше.

### Параллельные задачи и изоляция {#n96}

- tags: parallel, worktree

`parallel()` подходит для независимых проверок. Скрипт получает результаты в порядке входного списка, а сбой одной задачи отменяет остальные. Для одновременных правок `workspace="branch"` выделяет каждому агенту отдельный Git worktree.

#### Evidence

- [External fact] `parallel(items, fn)` запускает обработку всех элементов одновременно, возвращает результаты в исходном порядке и отменяет остальные задачи при сбое одной. — <https://antigravity.google/docs/dynamic-workflows/#script-building-blocks>
- [External fact] По умолчанию агент наследует рабочую область. `branch` создаёт отдельный Git worktree, а `share` даёт новую рабочую копию с общим хранилищем репозитория. — <https://antigravity.google/docs/dynamic-workflows/#script-building-blocks>

### Последовательные задачи и передача результатов {#n97}

- tags: pipeline, JSON Schema

`pipeline()` обрабатывает элементы по одному, что удобно для общего набора тестов или пересекающихся правок. Зависимость между фазами задаёт сам скрипт. Например, результат поиска файлов становится входным списком для следующей фазы проверок.

#### Evidence

- [External fact] `pipeline(items, fn)` выполняет обработку по одному элементу и возвращает результаты в порядке входа. В примере `Discover` возвращает массив путей, который скрипт передаёт в фазу `Review`. — <https://antigravity.google/docs/dynamic-workflows/>
- [External fact] Подагент отправляет результат через `finish`, который проверяет его по JSON Schema. Скрипт получает разобранное значение и может передать его следующему агенту. — <https://antigravity.google/docs/dynamic-workflows/#script-building-blocks>

### Согласование скрипта и наблюдение фаз {#n98}

- tags: CLI, разрешения

В интерактивном CLI запрос на запуск относится к конкретному Python-скрипту. Дерево в `/tasks` показывает фазы, журналы, вывод и ожидающих разрешения агентов. Терминал Antigravity в MarkView запускается с `--dangerously-skip-permissions`, поэтому фактические запросы в этом режиме требуют отдельной проверки.

#### Evidence

- [External fact] Если профиль разрешений требует подтверждения, оно распространяется на точный скрипт. Подагенты запрашивают разрешения в собственных беседах. `Ctrl`+`O` раскрывает дерево в стенограмме, а `/tasks` открывает подробности фоновой задачи. — <https://antigravity.google/docs/dynamic-workflows/>
- [Project fact] Команда запуска AI-терминала добавляет `tool.fullAccessArgs`. — `MarkView/Models/Workspace/AITerminalsController.swift:99`
- [Project fact] Для Antigravity `fullAccessArgs` содержит `--dangerously-skip-permissions`. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:11`
- [Open assumption] В живом запуске не проверялось, какие запросы подтверждения появляются для самого скрипта и подагентов с аргументами MarkView.

### Перепланирование внутри Orchestrator {#n99}

- tags: Orchestrator, планирование

В начале хода планировщик изучает проект в режиме чтения и задаёт условия перепланирования. Исполнитель выполняет правки и проверки, а при неожиданном результате возвращает управление планировщику. Передача управления автоматическая и происходит внутри одной беседы.

#### Evidence

- [External fact] Документация описывает передачу управления обратно планировщику при затруднениях, например после повторного провала проверки или при расхождении с ожидаемым поведением интерфейса. — <https://antigravity.google/docs/models#orchestrator>
- [External fact] Gemini Enterprise использует фиксированную пару Gemini 4 Carbon (High) и Gemini 4 Hydrogen (High). Выбор моделей по ролям зависит от плана и интерфейса. — <https://antigravity.google/docs/models#orchestrator>

### Выбор модели Orchestrator в Cockpit {#n100}

- tags: модель, CLI

Cockpit передаёт выбранную в плане модель в команду запуска терминала. Для автоматического выбора Orchestrator стоит проверить идентификатор из `agy models`: строка с пробелами в текущей команде запуска может разбиться на несколько аргументов.

#### Evidence

- [External fact] CLI принимает имя или идентификатор в `--model`. `agy models` показывает идентификаторы, доступные аккаунту. Для Gemini Enterprise документирован `gemini-pro-orchestrator`. — <https://antigravity.google/docs/models#select-orchestrator>
- [Project fact] Cockpit берёт `chosenModel` из утверждённого шага по его идентификатору. — `MarkView/Models/Cockpit/CockpitSession.swift:291`
- [Project fact] Терминал собирает команду строковым объединением аргументов, включая значение модели. — `MarkView/Models/Workspace/AITerminalsController.swift:94`
- [AI inference] Документированное имя вида `Orchestrator (Neon)` при такой сборке требует экранирования. Выбор по идентификатору без пробелов снимает именно эту проблему.

### Итог workflow для шага Cockpit {#n101}

- tags: Cockpit, Temporal

Возможная схема встраивания: один утверждённый шаг Cockpit запускает внутренние фазы Antigravity, после чего назначенный агент сводит результаты и вызывает `markview_cockpit_complete_step`. Cockpit сохраняет итог с идентификатором шага и отпечатком плана. Отрицательный результат ставит процесс на паузу.

#### Evidence

- [External fact] После завершения скрипта главный агент получает его журналы и вывод и подводит итог в беседе. — <https://antigravity.google/docs/dynamic-workflows/#how-it-works>
- [Project fact] Задание требует от назначенного агента вызвать `markview_cockpit_complete_step` с билетом, `passed`, `detail` и `build` после выполнения своей части. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:125`
- [Project fact] Регистрация завершения проверяет принадлежность билета проекту и погашает билет после принятия результата. — `MarkView/Models/Cockpit/CockpitAgentRegistry.swift:55`
- [Project fact] Temporal записывает итог под идентификатором шага и отпечатком плана и при `Passed == false` переводит процесс в `paused`. — `tools/cockpit-temporal/workflow.go:249`
- [Open assumption] Сквозной запуск `/run-workflow` из задания Cockpit с последующей отправкой результата по билету не проверялся.

### Поисковые запросы ветки {#n102}

- tags: источники

- `Google Antigravity Dynamic Workflows /run-workflow Python parallel pipeline phase JSON schema official documentation`
- `Google Antigravity Orchestrator mode planner executor model official docs Antigravity CLI`

#### Evidence

- [External fact] Открыта документация Google по фазам, функциям скрипта и разрешениям Dynamic Workflows. — <https://antigravity.google/docs/dynamic-workflows/>
- [External fact] Открыта документация Google по передаче управления между моделями и выбору Orchestrator. — <https://antigravity.google/docs/models#orchestrator>

### Ревью и программный интерфейс {#n19}

- tags: ревью, ACP
- position: -1113, 1274

Для ревью Google показывает разовый запрос к `agy` по Git diff. `/diff` открывает просмотр изменений, а Artifact Review согласует план. Для отдельного интерактивного интерфейса Google документирует `agy acp`.

#### Evidence

- [Project fact] Одноразовая интеграция MarkView использует `agy` с потоковым JSON и разбирает `structured_output`. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:59`
- [External fact] Руководство Google показывает инженерное ревью diff через `agy -p`. — <https://antigravity.google/docs/cli/best-practices>
- [External fact] `/diff` открывает интерактивный просмотр изменений, а Artifact Review управляет согласованием плана. — <https://antigravity.google/docs/cli/reference>
- [External fact] `agy acp` предоставляет JSON-RPC поверх stdio для редакторов, включая события вызовов инструментов и запросы разрешений. — <https://antigravity.google/docs/ide/extensions/acp>
- [Project fact] MarkView пока не подключает `agy acp`. Тест провайдеров явно проверяет, что `CLITool.antigravity.provider.acp == nil`. — `MarkViewHostedTests/AssistantPipelineHostTests.swift:60`
- [Project fact] В X-Ray операция `xray-pr-review` сама получает diff, обрезает его после 200 000 символов и передаёт выбранному для проекта ассистенту. Схема ответа требует общий итог, вердикт и риск по каждому файлу, а также замечания с номерами строк в новой версии файла. — `MarkView/Models/Architecture/ChangeReviewStore.swift:642`
- [Project fact] Для разового запуска MarkView передаёт `--sandbox` и при наличии схемы добавляет `--json-schema`. Парсер переносит `denied_actions` в список отказов, а статус, отличный от `SUCCESS`, обрабатывает отдельно как ошибку запуска. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:61`
- [External fact] Начиная с `v1.5.7`, при отсутствии `agentMode` разовый `agy -p` использует `auto` там, где он доступен. В этом режиме правки в рабочей области могут применяться автоматически. Если инструменту требуется подтверждение, которое нельзя получить в headless-режиме, CLI пропускает действие и может завершиться с кодом `0`. Поэтому один код выхода не подтверждает, что все запрошенные проверки выполнены. — <https://antigravity.google/docs/cli/headless/>
- [External fact] В `/diff` есть три представления. `All Changes` включает неотслеживаемые файлы, `Per Turn` группирует изменения по ходам агента, а `Commit Tree` показывает историю коммитов. При выходе пользователь может отправить построчные комментарии агенту как следующий запрос или отбросить их. — <https://antigravity.google/docs/cli/commands/diff/>
- [External fact] В терминальном `/artifact` можно просматривать Markdown, diff и визуальные материалы, оставлять построчные комментарии и принимать или отклонять отдельные артефакты. — <https://antigravity.google/docs/cli/artifacts/>
- [External fact] ACP-клиент может показывать поступающие правки как diff прямо в редакторе. Сервер поддерживает загрузку, возобновление, перечисление и закрытие сессий. Возобновление открывает прежнюю беседу без повторной передачи её истории клиенту. — <https://antigravity.google/docs/ide/extensions/acp>
- [External fact] Google также документирует локальный Python SDK `google-antigravity`, который управляет инструментами, контекстом и сессиями агента, и управляемый облачный Antigravity Agent в Gemini Interactions API. Поисковые запросы: `Google Antigravity CLI agy acp official documentation session diff code review artifact Git diff`, `Google Antigravity CLI official docs agy code review git diff json schema artifact review /diff acp`, `Google Antigravity CLI agy acp agent client protocol official documentation session modes capabilities`. — <https://antigravity.google/docs/sdk/overview/>

### Сценарии MarkView {#n6}

- tags: интеграция
- layout: radial
- position: 973, 381

Точки входа, план этапов, параллельное выполнение, остановка и критерии успешного завершения.

### Кнопка и текущая передача задачи {#n20}

- tags: интерфейс, запуск
- position: 1280, 330

Возьмём за точку входа существующую кнопку `Implement with AI`: она предлагает Definition of Done, отправляет цель выбранному агенту и фиксирует начало работы. Для небольшой задачи достаточно этого пути. Для работы с несколькими этапами кнопка может открыть предзаполненный план Cockpit.

#### Evidence

- [Project fact] Кнопка вызывает `implementWithAI`, а `startImplementation` отправляет цель в выбранный терминал и только после отправки отмечает начало. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:334`
- [Project fact] Цель включает требования, уже принятые решения и Definition of Done. — `MarkView/Models/Lifecycle/HandoffPrompt.swift:8`
- [Open assumption] `Implement VDI` обозначает пример сценарной кнопки. Ближайшая подтверждённая точка входа называется `Implement with AI`.

### Этапы и зависимости {#n21}

- tags: этапы, параллельность
- position: 984, 533

Начать с шаблона последовательных этапов Cockpit. Внутри этапа разрешать подагентов для независимой работы, если это подтверждено на выбранном интерфейсе. Параллельные этапы между разными провайдерами потребуют явных зависимостей, отдельных идентификаторов попыток и контроля одновременной записи.

#### Evidence

- [Project fact] Планировщик формирует последовательный план с агентом, моделью, заданием и условием завершения каждого шага. — `MarkView/Models/Cockpit/CockpitPlanning.swift:15`
- [Project fact] Temporal запускает одну activity и ждёт её результат или сигнал отмены перед переходом к следующему шагу. — `tools/cockpit-temporal/workflow.go:197`
- [AI inference] Встроенное делегирование позволяет испытать параллельную работу до изменения модели исполнения Cockpit.

### Реализация в worktree {#n24}

- tags: реализация
- number: 2
- position: 945, 716

Один агент с правом записи реализует согласованный план. Параллельная запись допускается при независимых участках с отдельными worktree и явным этапом интеграции.

#### Evidence

- [AI inference] Один интегратор отвечает за итоговый diff, сборку и разрешение конфликтов между изменениями.

### Ветка и исходный коммит {#n117}

- tags: Git, worktree
- number: 1
- position: 1031, 820

Начинайте реализацию на `feat/<slug>` или `fix/<bug-id>-<slug>` от актуального `origin/main`. Перед первой правкой зафиксируйте путь worktree, ветку и SHA базы. При параллельной работе эти данные задают общую точку сравнения для всех исполнителей.

#### Evidence

- [Project fact] Для каждой функции или ошибки руководство требует отдельную ветку от актуального `origin/main`. — `CLAUDE.md:134`
- [Project fact] При общей рабочей копии руководство предписывает создать отдельный worktree через `git worktree add` и сохранить чужие незакоммиченные правки. — `CLAUDE.md:148`
- [AI inference] Запись пути, ветки и SHA базы позволяет сверить место правки и исходную точку diff при передаче результата.

### Границы параллельных правок {#n118}

- tags: параллелизм, контракты
- number: 2
- position: 1041, 891

Разделяйте участки по файлам и общим контрактам. Изменение сообщения моста поручайте одному исполнителю вместе с его Swift- и JavaScript-сторонами. Общие файлы сборки и версию закрепляйте за интегратором.

#### Evidence

- [Project fact] Руководство требует согласовать `MarkView.xcodeproj` и `Packages/MarkViewCore/Package.swift` при изменениях принадлежности файлов к целям или настроек сборки, а изменения сообщения моста проводить на обеих сторонах. — `CLAUDE.md:62`
- [Project fact] Руководство предписывает один подъём версии максимального применимого уровня для изменений, коммитящихся вместе. — `CLAUDE.md:162`
- [AI inference] Разные каталоги могут быть связаны одним контрактом. Если задачи затрагивают этот контракт, их стоит поручить одному исполнителю или выполнить последовательно.

### Запуск в корне рабочей копии {#n119}

- tags: Cockpit, терминал
- number: 3
- position: 1043, 977

Для реализации через Cockpit откройте выделенный worktree как проект до запуска. Терминал шага открывается в корне проекта. В задании шага путь отдельного worktree можно указать текстом, но рабочий каталог запуска задаёт окно проекта.

#### Evidence

- [Project fact] `CockpitHost` создаёт `CockpitSession` с корнем открытого проекта. — `MarkView/Models/Workspace/CockpitHost.swift:38`
- [Project fact] `openAITerminal` передаёт `root` как `TerminalSession.directory`. — `MarkView/Models/Workspace/AITerminalsController.swift:206`
- [Project fact] `CockpitAgentAttempt` завершает терминал при несовпадении его исходного каталога с корнем Cockpit. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:54`

### Аудит изменений в корне Cockpit {#n122}

- tags: Cockpit, запись
- position: 769, 985

При выключенном `fixBugs` Cockpit сравнивает снимки своего корня до и после шага, включая видимые Git изменения исходников и смену `HEAD`. Это проверка постфактум. Для ограничения записи в соседние рабочие копии нужны права файловой системы или песочницы агента.

#### Evidence

- [Project fact] Cockpit снимает состояние корня до запуска и после завершения процессов терминала. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:190`
- [Project fact] При выключенном `fixBugs` аудит в Git-проекте проверяет изменения исходных файлов и `HEAD`. Обнаруженное нарушение помечает шаг как неуспешный, а изменения остаются на диске. — `MarkView/Models/Cockpit/CockpitStepAudit.swift:6`
- [AI inference] Снимки одного корня не подтверждают состояние соседнего worktree. Ограничения реальной записи должны действовать на уровне процесса и файловой системы.

### Коммиты для передачи интегратору {#n120}

- tags: Git, передача
- number: 4
- position: 1048, 1067

Передавайте ветку и SHA базы, список коммитов в порядке переноса и перечень затронутых путей. В Cockpit эти сведения можно положить в `detail`, который поступит следующему шагу в `priorResults`.

#### Evidence

- [Project fact] `CockpitHostResult` содержит `detail` и `build`. Выделенных полей для ветки и коммитов в структуре результата нет. — `MarkView/Models/Cockpit/CockpitHostBridge.swift:7`
- [Project fact] Temporal передаёт результаты предыдущих шагов в `PriorResults`, а агент получает задание с ними в JSON. — `tools/cockpit-temporal/workflow.go:197`
- [Project fact] Промпт Cockpit вставляет закодированное задание и предыдущие результаты в терминал агента. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:124`
- [AI inference] Список SHA в порядке переноса позволяет интегратору забрать нужный набор правок и сверить его охват.

### Сведение правок в ветке задачи {#n121}

- tags: Git, интеграция
- number: 5
- position: 1051, 1162

Перенесите принятые коммиты в ветку задачи в порядке их зависимостей. После разрешения конфликтов сопоставьте итоговый diff с согласованным планом и списками затронутых файлов, затем передайте SHA общего результата на проверку.

#### Evidence

- [Project fact] Руководство требует одну ветку и один pull request на функцию или исправление ошибки. Прямое локальное слияние в `main` запрещено. — `CLAUDE.md:134`
- [AI inference] При переносе коммитов стоит сверить объединённый diff после разрешения конфликтов, поскольку решение конфликта само может изменить поведение или потерять часть правок.

### Перенос после переименования файлов {#n123}

- tags: Git, конфликты
- position: 741, 1154

Если база рабочего участка отстала, проверьте, куда переехали файлы и их вызовы в ветке задачи. После переноса сверяйте назначение правки по актуальным путям, особенно если Git распознал переименование автоматически.

#### Evidence

- [Project fact] Архитектурный обзор зафиксировал две рабочие копии с незакоммиченными правками по старым путям и отставанием базы на 160–176 коммитов. В обзоре указано, что перенос зависел от распознавания переименований. — `docs/architecture/architecture-review-2026-11-followup.md:490`
- [AI inference] После реорганизации каталогов корректный перенос требует сверки назначения правки и её вызовов на новой базе.

### Проверки и независимое ревью {#n25}

- tags: тесты, ревью
- number: 3
- layout: outline
- position: 1311, 719

Запустить тесты и ревью одного снимка изменений параллельно, если проверкам не нужны общие изменяемые артефакты. Замечания с severity, `file:line` и основанием передать исполнителю. После исправлений повторить проверки для нового SHA.

#### Evidence

- [AI inference] Один снимок позволяет сопоставить результаты проверок, а новый SHA требует повторной проверки изменённых участков.

### Матрица проверок по изменению {#n124}

- tags: тесты, покрытие
- position: 1343, 816

Для Swift и встроенного редактора взять за основу Debug-сборку, тесты MarkViewCore, набор `pure` и подборку `--changed`. Если компиляция не проверяет затронутое поведение, добавить целевой сценарий с подходящей фикстурой.

#### Evidence

- [Project fact] Руководство перечисляет базовые команды проверки и требует целевой проверки поведения, которое компиляция не покрывает. — `CLAUDE.md:168`
- [Project fact] Функциональные тесты проверяют поведение по реальному пути приложения. Структурные ограничения проверяются отдельными lint-скриптами. — `CLAUDE.md:94`

### Что выбирает `--changed` {#n125}

- tags: runner, покрытие
- position: 1596, 820

В чистой рабочей копии передать явный диапазон `BASE...HEAD`; скрипт также учитывает незакоммиченные и неотслеживаемые файлы. Перед запуском сверить подборку через `--dry-run`: по умолчанию действует `pure`, а код `3` означает проблему с выбором наборов или с чтением изменений Git.

#### Evidence

- [Project fact] `--changed` принимает явный диапазон, по умолчанию использует `origin/main...HEAD` при наличии этой ссылки и добавляет файлы из `git status`. — `tools/tests/run.sh:88`
- [Project fact] Уровень по умолчанию `pure`. Выбор использует совпадения с путями или именами файлов из манифеста, а код `3` возвращается при ошибке Git или отсутствии совпадений среди выбранных наборов. — `tools/tests/run.sh:19`
- [Project fact] При отсутствии совпадений скрипт сообщает, доступно ли покрытие на другом уровне, и предлагает выбрать подходящий уровень или назвать наборы. — `tools/tests/run.sh:113`

### Разбор нестабильного теста {#n131}

- tags: тесты, CI
- position: 1345, 894

Сохранить журнал первого сбоя и повторить конкретный тест на том же SHA. Сравнить условия локального запуска и CI. Если тест зависит от готовности интерфейса, дождаться наблюдаемого состояния с ограниченным сроком и сохранить исходную проверку поведения.

#### Evidence

- [Project fact] В hosted-тесте WebKit фиксированное ожидание заголовка заменили ожиданием фактической готовности с дедлайном и диагностикой. В тесте больших диаграмм после успешного повтора причину прежнего выброса оставили открытой и сохранили порог. — `docs/architecture/architecture-review-2026-11-remaining-tasks.md:44`
- [AI inference] Первичный журнал и повтор на том же SHA помогают выяснить, зависит ли сбой от условий запуска.

### Изоляция артефактов тестов {#n126}

- tags: Xcode, параллелизм
- position: 1343, 944

Ревью исходников можно вести одновременно со сборкой. Для параллельных сборок выделить отдельные `DerivedData`; если hosted-тесты используют общую сборку, сначала завершить её, а затем запускать независимые группы с отдельными результатами.

#### Evidence

- [Project fact] CI один раз выполняет `build-for-testing`. Пять групп hosted-тестов зависят от этого задания и запускаются с готовой сборкой. — `.github/workflows/ci.yml:106`
- [AI inference] Отдельные каталоги для независимых локальных сборок предотвращают конкурирующую запись в одни и те же артефакты. Ревью исходников может идти во время сборки, если ревьюер не читает её промежуточные результаты.

### Задание независимому ревьюеру {#n127}

- tags: ревью, критерии
- position: 1345, 1017

Передать отдельному ревьюеру критерии приёмки и диапазон `base SHA`–`head SHA`. Попросить в режиме чтения проследить затронутый путь приложения, проверить ожидаемое поведение и поискать пропущенные сценарии. Для выводов о поведении указать, подтверждены ли они запуском или чтением кода.

#### Evidence

- [Project fact] В архитектурном ревью MarkView зафиксирован SHA, выполнены семь параллельных проходов в режиме чтения, а наиболее серьёзные выводы дополнительно сверены с кодом. Последствия, выведенные статически, отмечены отдельно. — `docs/architecture/architecture-review-2026-11.md:3`
- [AI inference] Роль ревьюера и критерии приёмки стоит задать отдельно от реализации, чтобы ревьюер мог проверить поведение по спецификации и коду.

### Охват ревью PR X-Ray {#n129}

- tags: PR X-Ray, ревью
- position: 1567, 1008

`Review with AI` открывает PR X-Ray для выбранного PR. Модель получает diff объёмом до 200 000 символов и возвращает замечания по файлам. Для большого PR или проверки вызовов за пределами diff дать отдельному ревьюеру доступ к полным исходникам проверяемого SHA.

#### Evidence

- [Project fact] Кнопка открывает источник `gh:<n>`. Автоматический запуск ревью после загрузки зависит от `GitHubSettings.autoReview`. — `MarkView/Models/Architecture/CodeAndXRayCoordinator.swift:438`
- [Project fact] Реализация ограничивает diff через `String.count` и поручает модели работать по diff. Схема замечаний включает номер строки новой версии файла, `severity` и сообщение. — `MarkView/Models/Architecture/ChangeReviewStore.swift:655`
- [AI inference] Для проверки смежных путей и изменений за пределом обрезки нужен проход по полным исходникам.

### Разбор замечаний с исполнителем {#n128}

- tags: ревью, приёмка

Для каждого замечания записать `severity`, `file:line`, имя символа, условия возникновения и наблюдаемый или ожидаемый эффект. Связать исправление с исходным замечанием и указать тест или измеримый критерий, по которому ревьюер сможет подтвердить результат.

#### Evidence

- [Project fact] Архитектурное ревью использует идентификаторы и severity, а имя символа служит устойчивой ссылкой при смещении номеров строк. — `docs/architecture/architecture-review-2026-11.md:8`
- [Project fact] Для архитектурного замечания руководство требует измеримого критерия закрытия и записи фактического значения. — `CLAUDE.md:88`
- [AI inference] Связь исправления и новой проверки с исходным замечанием позволяет ревьюеру сверить, что устранена именно описанная проблема.

### Передача замечаний из PR X-Ray {#n132}

- tags: PR X-Ray, терминал
- position: 1588, 1112

`Send to terminal` вставляет список в приглашение AI-терминала. Перед Enter сверить SHA и состав задач. Список включает активные замечания и, если выполнен анализ, его дополнительные проверки и риски.

#### Evidence

- [Project fact] `tasksText()` пропускает снятые замечания и группирует задачи под `Bugs`, `Concerns`, `Notes` и `To check`. — `MarkView/Models/Architecture/ChangeReviewModel.swift:202`
- [Project fact] Обработчик `prTasksToTerminal` передаёт список с `submit: false`. — `MarkView/Models/Architecture/CodeAndXRayCoordinator.swift:557`

### Перепроверка после исправлений {#n130}

- tags: SHA, повтор

На новом `head SHA` повторить сценарии, связанные с исправлениями, и независимо сверить закрытие замечаний. Перед завершением сопоставить текущий SHA PR с проверенным. Для PR X-Ray команда `Review again` перечитывает изменения и пересчитывает ревью без кэша.

#### Evidence

- [Project fact] `reviewAgain` заново загружает изменения и вызывает `reviewPR` с `fresh: true`. Обычное ревью может использовать кэш по SHA-256 diff. — `MarkView/Models/Architecture/ChangeReviewStore.swift:292`
- [Project fact] Сборщик событий CI извлекает SHA последнего коммита каждого подходящего PR. Workflow отменяет предыдущие запуски на той же ссылке. — `MarkView/Models/Lifecycle/LifecycleCapture.swift:78`
- [AI inference] Сверка текущего SHA предотвращает перенос результатов со снимка, который исполнитель уже обновил.

### Итоги обязательных проверок PR {#n133}

- tags: CI, PR
- position: 1597, 1242

Открыть результаты отдельных обязательных проверок для текущего PR. Сводный значок MarkView может показывать успех при нейтральных исходах, в том числе `skipped` или `cancelled`.

#### Evidence

- [Project fact] `GHOutcome` относит `skipped` и `cancelled` к нейтральным исходам. `checksOutcome` возвращает `.success`, если список непуст и в нём нет неудачных или текущих проверок. — `MarkView/Models/Git/GitHubClient.swift:194`
- [Project fact] Карточка PR показывает сводный значок, число успешных проверок и подробности каждой проверки во всплывающей подсказке. — `MarkView/Views/Git/GitHubViews.swift:341`

### Доставка по правилам проекта {#n26}

- tags: PR, CI
- number: 4
- layout: outline
- position: 1930, 708

Применить пункты `require`, `ask` и `skip` из Definition of Done. Для PR, CI, merge и релиза сохранять фактические результаты, учитывая состояние внешних операций при остановке и возобновлении.

#### Evidence

- [Project fact] Definition of Done поддерживает три режима и включает пункты про ветку, тесты, PR, CI, merge и доставку. — `MarkView/Models/Lifecycle/DefinitionOfDone.swift:11`
- [AI inference] Перед повтором отправки PR или релиза нужно проверить, успела ли завершиться предыдущая попытка.

### Правила выполнения и перехода статуса {#n134}

- tags: политика, согласование
- position: 1933, 800

Для запуска согласуйте Definition of Done с руководством проекта и выбранным вариантом процесса. `require` требует доказательства, `ask` требует явного согласия до действия, а `skip` исключает действие из цели. Переход статуса проверяет вариант процесса, поэтому возможное расхождение видно до начала доставки.

#### Evidence

- [Project fact] `goalText()` превращает режимы в инструкции для агента и требует итоговый чек-лист с доказательствами по обязательным пунктам. — `MarkView/Models/Lifecycle/DefinitionOfDone.swift:127`
- [Project fact] После принятия процесса правила переходов берутся из него. Сводка показывает расхождения с Definition of Done как предупреждения. — `MarkView/Models/Lifecycle/WorkflowDone.swift:3`

### Настройки конкретного запуска {#n138}

- tags: настройки, версия
- position: 2226, 774

Встроенный чек-лист ставит `merge` в `ask`, а `version` и `deploy` в `skip`. Для изменения приложения в MarkView руководство требует повышение версии, слияние проверенного PR и выпуск. Согласуйте эти пункты перед запуском и сохраняйте их как проектные настройки только при необходимости повторного использования.

#### Evidence

- [Project fact] Стандартные режимы `merge`, `version` и `deploy` равны `ask`, `skip` и `skip` соответственно. — `MarkView/Models/Lifecycle/DefinitionOfDone.swift:56`
- [Project fact] В диалоге запуска чек-лист можно изменить. Выбранные значения сохраняются для проекта, если включён `Save as this project's default`. — `MarkView/Views/Lifecycle/DefinitionOfDoneView.swift:42`
- [Project fact] Руководство привязывает повышение версии к изменениям приложения, а слияние и выпуск входят в завершение такой задачи. — `CLAUDE.md:141`

### Подтверждение внешнего события доставки {#n139}

- tags: приёмка, доставка
- position: 2225, 709

Если вариант процесса требует подтверждения события вроде установки, проверьте в `markview_issue_context`, кто вправе его подтвердить. Агент с таким правом передаёт в `markview_confirm_delivery` наблюдаемый результат и способ проверки. MarkView проверяет остальные условия доставки перед переходом статуса.

#### Evidence

- [Project fact] `markview_confirm_delivery` принимает идентификатор задачи и доказательство, сверяет право агента на подтверждение и направляет к человеку, если подтверждение оставлено за ним. — `MarkView/Models/AgentTools/ProjectAgentTools.swift:142`
- [Project fact] После записи подтверждения обработчик заново оценивает завершение доставки и сообщает итоговый статус или наличие недостающих доказательств. — `MarkView/Models/AgentTools/ProjectToolRunner+Lifecycle.swift:125`

### Путь изменений в `main` {#n135}

- tags: PR, merge
- position: 1933, 891

Для фич и исправлений MarkView используется один PR на задачу с описанием изменений, версией и планом тестирования. После локальной проверки и обязательных проверок PR выполняется merge через GitHub, если Борис не попросил оставить PR открытым. Для документационных изменений действует отдельный путь.

#### Evidence

- [Project fact] Руководство описывает отдельную ветку, создание PR в `main`, правила merge и исключение для документационных изменений. — `CLAUDE.md:124`

### Повышение версии до коммита {#n140}

- tags: SemVer, PR
- position: 2224, 835

Для изменений приложения выберите `patch` для исправления, `minor` для обратно совместимой фичи или заметного улучшения и `major` для несовместимости либо удаления или переработки пользовательской функции. До коммита обновите `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` через `./bump-version.sh`, затем укажите новую версию в PR.

#### Evidence

- [Project fact] Руководство определяет уровни повышения версии, требует изменения до коммита и перечисляет исключения для документации, `tasks/` и одних лишь скриптов сборки. — `CLAUDE.md:152`
- [Project fact] `bump-version.sh` присваивает обоим полям одинаковую версию и проверяет обновление для Debug и Release. — `bump-version.sh:19`

### Доставка изменений только в документации {#n141}

- tags: документация, main
- position: 2225, 895

Для отдельного изменения только в документации руководство разрешает прямой коммит и push в `main` после обновления из `origin/main`. Подготовьте к коммиту только свои файлы. Сборка приложения и DMG для этой задачи исключены из обязательных результатов.

#### Evidence

- [Project fact] Исключение для документации включает README, `docs/`, `tasks/`, презентации и записи о фичах и багах. Руководство требует сначала обновиться из `origin/main` и запрещает `--force`. — `CLAUDE.md:130`
- [Project fact] Для документационных изменений руководство исключает сборку приложения и DMG. — `CLAUDE.md:209`

### Связь PR с задачей и коммитом {#n142}

- tags: PR, SHA
- position: 2225, 958

Укажите в описании PR однозначный идентификатор задачи, например `Feature: <slug>` или ключ бага. После слияния сохраните URL PR и SHA коммита слияния. Для процесса с обязательным PR MarkView проверяет состояние `MERGED` в GitHub.

#### Evidence

- [Project fact] Сборщик читает описания PR для привязки изменений. Он распознаёт путь фичи, строку `Feature: <slug>`, ключ бага и однозначно связанный номер GitHub issue. — `MarkView/Models/Lifecycle/IssueEvidenceCollector.swift:277`
- [Project fact] Общий номер GitHub issue без дополнительного идентификатора считается неоднозначной привязкой. — `MarkView/Models/Lifecycle/IssueEvidenceCollector.swift:184`
- [Project fact] Сборщик читает `mergeCommit`, `mergedAt` и `state`. При обязательном PR отсутствие подтверждения GitHub делает слияние недоказанным. — `MarkView/Models/Lifecycle/IssueEvidenceCollector.swift:355`
- [AI inference] URL PR и SHA коммита слияния дают отдельные идентификаторы для сверки интеграции и выпуска.

### Релиз из слитого коммита {#n136}

- tags: Release, DMG
- position: 1937, 1046

Для изменений приложения выпускайте локальную Release-сборку и подписанный DMG из слитого коммита `origin/main`. Доказательства выпуска включают URL релиза, локальные пути, версию приложения, подпись и результат `spctl`. Для того же коммита дождитесь успешного `Build & Release`.

#### Evidence

- [Project fact] Руководство требует локальный `./release.sh --publish`, успешный `Build & Release` на коммите слияния и проверку итоговых артефактов. — `CLAUDE.md:199`
- [Project fact] `Build & Release` компилирует Release-конфигурацию и сам не публикует установщик. — `.github/workflows/build-release.yml:1`

### Проверка подписанного установщика {#n143}

- tags: подпись, SHA-256
- position: 2224, 1079

`./release.sh --publish` проверяет чистоту рабочей копии, равенство `HEAD` свежему `origin/main` и доступность версии для публикации. Он создаёт `build/release/MarkView.app` и `build/MarkView-<version>.dmg`, проверяет подпись приложения, подписывает DMG, проходит нотарификацию, прикрепляет билет и выводит SHA-256. Релиз `v<version>` публикуется с двумя именами установщика.

#### Evidence

- [Project fact] Перед сборкой скрипт обновляет `origin/main`, требует чистую рабочую копию и останавливается, если GitHub уже возвращает релиз `v<version>`. — `release.sh:51`
- [Project fact] Скрипт проверяет подпись приложения через `codesign`, проходит нотарификацию DMG, прикрепляет билет, выполняет `spctl` и вычисляет SHA-256. — `release.sh:68`
- [Project fact] Публикация указывает `HEAD` как целевой коммит и загружает версионный DMG вместе с копией `MarkView.dmg` в релиз Latest. — `release.sh:104`

### Проверка тега и состава релиза {#n144}

- tags: тег, GitHub
- position: 2221, 1013

Если процесс требует GitHub-релиз, MarkView ищет опубликованный тег, история которого содержит коммит доставки. Для выпуска MarkView дополнительно сверьте подписанные файлы релиза с локальным DMG. `Publish Release` допускает публикацию неподписанного предварительного релиза при отсутствии настроенной подписи.

#### Evidence

- [Project fact] Сборщик исключает черновики, рассматривает публикации от момента слияния и засчитывает попадание коммита в тег при результате сравнения `ahead` или `identical`. — `MarkView/Models/Lifecycle/IssueEvidenceCollector.swift:395`
- [Project fact] Workflow `Publish Release` помечает подписанный вариант как Latest, а неподписанный публикует с `--prerelease --latest=false`. — `.github/workflows/publish-release.yml:151`
- [AI inference] Сопоставление тега, имён файлов и контрольной суммы DMG позволяет отдельно подтвердить наличие ожидаемого установщика.

### Сверка внешнего состояния перед повтором {#n137}

- tags: возобновление, GitHub
- position: 1938, 1185

После прерывания доставки сверяйте удалённый результат операции по её идентификатору. Если исход неизвестен, сохраняйте частичные данные и выбирайте точку продолжения после сверки.

#### Evidence

- [Project fact] После перезапуска Cockpit помечает активный шаг `interrupted`, приостанавливает запуск и указывает, что отделённые фоновые процессы могут продолжаться. — `MarkView/Models/Cockpit/CockpitRun.swift:284`
- [AI inference] Удалённый результат следует перепроверить по номеру PR, SHA или тегу перед любым повтором внешней операции.

### Возобновление после создания или слияния PR {#n145}

- tags: PR, возобновление
- position: 2225, 1158

После прерванного `push` сверьте SHA удалённой ветки. Если прервалось создание PR, найдите его по исходной ветке и целевой `main`, затем сохраните номер и URL. После прерывания merge перечитайте состояние PR и SHA коммита слияния. При подтверждённом слиянии продолжайте со сборки или другой следующей операции по плану.

#### Evidence

- [Project fact] Сборщик читает удалённое состояние PR, его `headRefOid`, `mergeCommit` и `mergedAt`. — `MarkView/Models/Lifecycle/IssueEvidenceCollector.swift:355`
- [AI inference] Сверка ветки, номера PR и SHA помогает продолжить с первой невыполненной операции, даже если предыдущая команда завершилась без локального отчёта.

### Возобновление прерванной публикации {#n146}

- tags: Release, возобновление
- position: 2226, 1230

Перед повтором найдите `v<version>`, проверьте состояние публикации, коммит тега и оба ожидаемых DMG. Если релиз полный, сохраните его URL и перейдите к итоговым проверкам. При неполной загрузке зафиксируйте отсутствующие файлы, а при сбое чтения оставьте результат неизвестным до повторной сверки GitHub.

#### Evidence

- [Project fact] `release.sh --publish` останавливается для уже существующего релиза и при публикации отправляет два файла с привязкой к `HEAD`. — `release.sh:51`
- [Project fact] Скрипт публикует `MarkView-<version>.dmg` и `MarkView.dmg`, затем отдельно читает URL релиза. — `release.sh:104`
- [AI inference] Отдельная проверка тега и файлов различает завершённую публикацию, частичную загрузку и временную недоступность GitHub.

### План по спецификации {#n30}

- tags: план
- number: 1
- layout: left
- position: 657, 722

Этап чтения извлекает требования, принятые решения, разрешённые действия и проверки. Из них формируется план с зависимостями, ожидаемыми артефактами и решениями, которые нужно принять перед запуском.

#### Evidence

- [AI inference] Спецификация и Definition of Done дают исходные данные для формирования плана кнопки.

### Назначение пары в плане Cockpit {#n104}

- tags: Cockpit, спецификация

Cockpit уже предлагает агента и модель для каждого шага и позволяет изменить их перед утверждением. Для плана по спецификации можно использовать этот механизм: передать планировщику спецификацию и Definition of Done, затем показать предложенные назначения. Текущая кнопка `Implement with AI` передаёт цель и Definition of Done непосредственно в терминал.

#### Evidence

- [Project fact] В схеме шага есть `agent`, `model`, `assignment` и `completionCondition`. Планировщик получает имена агентов и идентификаторы доступных моделей. — `MarkView/Models/Cockpit/CockpitPlanning.swift:15`
- [Project fact] Карточка шага позволяет менять агента и модель. — `MarkView/Views/Cockpit/CockpitStepCard.swift:128`
- [Project fact] `startImplementation` формирует `HandoffPrompt.feature` с `done` и отправляет его в терминал через `sendToAssistant`. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:340`
- [AI inference] План Cockpit даёт готовое место для рекомендации исполнителей до передачи задачи в терминал.

### Допуск агента и модели {#n105}

- tags: доступность, инструменты

Сначала отберите агентов, которые могут выполнить конкретный шаг в нужном режиме, с нужными инструментами и разрешениями. Затем выбирайте модель из каталога этого агента с учётом аккаунта и квоты. Для обязательного шага без подходящей пары покажите конкретное препятствие до запуска.

#### Evidence

- [Project fact] `loadAgents()` включает CLI, который найден локально и для которого включён проектный MCP-сервис MarkView. `generate()` передаёт планировщику список имён и ID моделей. — `MarkView/Models/Cockpit/CockpitSession.swift:142`
- [Project fact] При запуске Cockpit проверяет доступность назначенного агента и включение MCP, затем открывает терминал в проекте. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:54`
- [Open assumption] У конкретного пользователя доступны нужная подписка, квота, модель и инструменты шага. Найденный CLI и локальная настройка MCP сами по себе этого не подтверждают.

### Разрешение модели по умолчанию {#n106}

- tags: Default, утверждение

Для обратимого шага `Default` уместен, если конкретная модель не влияет на приёмку. Для ответственного шага покажите актуальный ID до утверждения и предложите пересмотреть назначение, если модель исчезла. Это важно для настроек, которые могут измениться между составлением плана и запуском.

#### Evidence

- [Project fact] Неизвестное имя агента делает ответ планировщика недействительным. Неизвестный или пустой `model` превращается в `nil`. — `MarkView/Models/Cockpit/CockpitPlanning.swift:75`
- [Project fact] Явную модель Cockpit берёт из утверждённого шага. При `nil` команда терминала использует текущую модель проекта для агента, если она задана, затем действует настройка CLI. — `MarkView/Models/Cockpit/CockpitSession.swift:279`
- [Project fact] Команда запуска формируется через `tool.modelArgs(model ?? chosenModel(for: profile))`. — `MarkView/Models/Workspace/AITerminalsController.swift:90`
- [AI inference] Показ эффективного выбора перед утверждением делает переход на Default заметным пользователю.

### Пара для чтения спецификации {#n107}

- tags: Planner, требования

Для ясной спецификации начните с Codex + `gpt-6.2-sol`, если пара доступна. Для противоречивых требований, сложной миграции или нескольких связанных компонентов используйте `gpt-6.2-astra` либо Claude Code + `opus`, если дополнительное время оправдано ценой ошибки. Модель планировщика выбирайте по сложности разбора спецификации, а исполнителей назначайте по работе каждого шага.

#### Evidence

- [Project fact] `Planner` имеет собственный выбор агента и модели с наследованием `Project's assistant`. Генерация плана передаёт эти параметры отдельному структурированному вызову. — `MarkView/Views/Cockpit/CockpitPlanScreen.swift:117`
- [Project fact] `generate()` отправляет запрос с `toolOverride`, `model` и `jsonSchema`. — `MarkView/Models/Cockpit/CockpitSession.swift:496`
- [External fact] OpenAI рекомендует GPT-6.2 Sol для сведения нескольких источников в план, а GPT-6.2 Astra для задач, требующих длительного рассуждения. — <https://learn.chatgpt.com/docs/models?surface=cli>
- [External fact] Anthropic рекомендует `opus` для сложных рассуждений. — <https://code.claude.com/docs/en/model-config>
- [AI inference] Чёткая спецификация допускает повседневную модель. Противоречия и дорогие ошибки оправдывают более глубокий разбор до утверждения.

### Codex для реализации по спецификации {#n108}

- tags: Codex, реализация

Предлагайте Codex + `gpt-6.2-sol` для обычной реализации с определёнными изменениями и проверками. Выбирайте `gpt-6.2-astra`, если нужно проследить дефект через несколько слоёв или оценить совместимость сложного изменения. Для извлечения требований по заданной схеме подойдёт `gpt-6-luna`. Sol расходует меньше кредитов на токен при стандартной скорости, чем Astra.

#### Evidence

- [Project fact] MarkView использует видимые позиции из локального каталога Codex, который поддерживает CLI, и добавляет Default. — `MarkView/Models/AI/Providers/CodexProvider.swift:34`
- [External fact] OpenAI позиционирует Sol как повседневную модель для кода, Astra как модель для сложной диагностики, а Luna как модель для ограниченных повторяемых задач. При Standard speed Sol стоит меньше кредитов на токен, чем Astra. — <https://learn.chatgpt.com/docs/models?surface=cli>
- [AI inference] Пути изменений и проверяемые критерии приёмки дают основание предложить Sol как первую пару для типового шага реализации.

### Claude Code для сложной диагностики {#n109}

- tags: Claude Code, диагностика

Предлагайте Claude Code + `opus` для неоднозначной диагностики, например проблемы между Swift и JavaScript, где нужно сопоставить несколько причин. При ясной реализации выбирайте `sonnet`, при короткой инвентаризации с заданным форматом подойдёт `haiku`. Алиасы удобны для рекомендаций, а при сравнении прогонов учитывайте, какая версия фактически за ними стояла.

#### Evidence

- [Project fact] Каталог Claude Code в MarkView включает `fable`, `opus`, `sonnet` и `haiku`. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:42`
- [External fact] Anthropic рекомендует `opus` для сложных рассуждений, `sonnet` для повседневного кодирования и `haiku` для простых задач. Версия модели за алиасом зависит от поставщика и обновляется со временем. — <https://code.claude.com/docs/en/model-config>
- [AI inference] Распределение по этим трём моделям оправдано сложностью шага. Преимущество Claude Code над другими агентами в диагностике MarkView локально не измерено.

### Copilot для задач GitHub {#n110}

- tags: Copilot, GitHub

Предлагайте Copilot + `claude-sonnet-5.5` для обычного шага, тесно связанного с GitHub, если аккаунту доступны нужная модель и проектный MCP. Для узкой сверки рассмотрите `claude-haiku-5.5`. Если организация ограничивает MCP, пригодность пары зависит от того, разрешён ли сервер, необходимый шагу.

#### Evidence

- [Project fact] Каталог Copilot состоит из Default и моделей из кэша ACP. Поставщик помечен как способный сообщать о блокировке MCP политикой. — `MarkView/Models/AI/Providers/CopilotProvider.swift:18`
- [External fact] GitHub указывает `claude-sonnet-5.5` как модель по умолчанию для общего кодирования, а `claude-haiku-5.5` как быструю модель для лёгких операций. — <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference>
- [External fact] Политики организации и предприятия могут ограничить список MCP-серверов, доступных Copilot CLI. — <https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/copilot-cli/administer-copilot-cli-for-your-enterprise>
- [AI inference] Работа с GitHub даёт основание предпочесть Copilot, если необходимые действия и доступ подтверждены для конкретного аккаунта.

### Antigravity для исполнения через Gemini {#n111}

- tags: Antigravity, каталог

Предлагайте Antigravity + Gemini 4 Hydrogen для ограниченного шага с понятной проверкой, например обновления документации или подготовки тестов для заданного поведения. Проверьте ID через `agy models`. Текущий список Cockpit содержит Argon и Flash, снятие которых объявлено на 30 ноября 2026 года. Для Hydrogen можно использовать `Default`, если проверенный ID задан как модель Antigravity в настройках проекта.

#### Evidence

- [Project fact] Встроенный список Antigravity содержит `gemini-4-argon-medium` и `gemini-3.8-flash-medium`. Hydrogen в нём отсутствует. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:18`
- [Project fact] Меню Cockpit предлагает Default и позиции каталога. В общем выборе модели можно сохранить введённый вручную ID. — `MarkView/Views/Cockpit/CockpitComponents.swift:118`
- [Project fact] `applyCustomModel()` сохраняет введённое имя как выбранную модель. — `MarkView/Views/AI/AIAssistantPickerView.swift:123`
- [External fact] Google описывает Hydrogen как модель для быстрых повседневных задач, рекомендует `agy models` для списка аккаунта и объявляет снятие Argon и Flash 3.8 на 30 ноября 2026 года. — <https://antigravity.google/docs/models?app=antigravity>

### Cline с настроенным провайдером {#n112}

- tags: Cline, ACP

Рассматривайте Cline + модель из каталога аккаунта, если в проекте уже настроен нужный провайдер и известна пригодность пары для такого шага. Здесь полезен выбор модели из существующей конфигурации. Рекомендация конкретного ID зависит от аккаунта, а меню опирается на результаты последней проверки ACP.

#### Evidence

- [Project fact] Cline зарегистрирован среди ассистентов MarkView. — `MarkView/Models/AI/Providers/AssistantProviderList.swift:5`
- [Project fact] Cline предлагает Default, заданный через `cline auth`, и сохранённые модели аккаунта из ACP. — `MarkView/Models/AI/Providers/ClineProvider.swift:18`
- [Open assumption] В рабочем аккаунте Cline настроены нужный провайдер и модель с достаточными возможностями для выбранного шага.

### Модель по цене ошибки {#n113}

- tags: приёмка, сложность

Для сверки списка файлов, кодов выхода и готовых артефактов достаточно быстрой модели с однозначным критерием. Если проверка требует выявить пропущенное требование, оценить совместимость или объяснить противоречивые результаты, назначьте модель уровня реализации либо глубже. Учитывайте объём контекста, стоимость и время вместе с последствиями ложного подтверждения.

#### Evidence

- [Project fact] Системный запрос Cockpit предлагает более быстрые модели для списков, проверок и финальной верификации, более сильные для реализации и диагностики. — `MarkView/Models/Cockpit/CockpitPlanning.swift:15`
- [AI inference] Название этапа «проверка» само по себе не определяет сложность. Сверка наблюдаемых фактов и оценка полноты реализации требуют разного уровня рассуждения.

### Обоснование выбора в карточке шага {#n114}

- tags: рекомендация, обоснование
- position: 366, 1083

Покажите для каждого назначения короткую связку «требование → нужный инструмент или уровень рассуждения → агент и модель». Рядом укажите условие замены, если оно существенно. Например, для проверки совместимости формата нужен анализ старых примеров данных, поэтому пара должна справляться с сопоставлением форматов и чтением тестовых файлов.

#### Evidence

- [Project fact] В `CockpitStep` хранятся агент, модель, задание и условие завершения. Отдельного поля для причины назначения в структуре нет. — `MarkView/Models/Cockpit/CockpitPlan.swift:161`
- [Project fact] Интерфейс указывает, что изменение шага, агента или модели меняет утверждаемое содержимое. — `MarkView/Views/Cockpit/CockpitPlanScreen.swift:264`
- [AI inference] Краткая причина позволит пользователю проверить назначение до запуска и понять, подходит ли замена при недоступности модели.

### Калибровка на задачах MarkView {#n115}

- tags: измерение, качество
- position: 375, 1003

Сравните пары на одинаковой спецификации и одинаковом исходном состоянии. Для планировщика измеряйте пропущенные требования и неподтверждённые возможности, для исполнителя учитывайте прохождение критериев с первого раза, время, повторы и расход, если он доступен. Пересматривайте рекомендацию по типу работы, когда накапливаются сопоставимые результаты.

#### Evidence

- [Project fact] Одноразовые вызовы `CLICompletion` записывают CLI, запрошенную модель, время, токены, стоимость при наличии и исход. — `MarkView/Models/AI/CLICompletion.swift:185`
- [Project fact] Cockpit сохраняет суммарное активное время агентов и число циклов исправления. — `MarkView/Models/Cockpit/CockpitRun.swift:39`
- [AI inference] Сравнение при одинаковых условиях покажет, окупается ли более сильная модель за счёт качества с первой попытки или сокращения повторов. Сравнительные прогоны в рамках исследования не проводились.

### Поисковые запросы ветки {#n116}

- tags: поиск, источники
- position: 359, 1153

Запросы, отправленные при проверке на 24 ноября 2026 года

- `Claude Code official model configuration opus sonnet haiku coding cost speed Anthropic`
- `OpenAI Codex CLI official recommended models coding fast mini model list`
- `GitHub Copilot official model comparison choosing AI model coding implementation fast tasks premium requests`
- `Google Antigravity official documentation CLI agy models Gemini Flash Argon model selection`
- `site:docs.github.com Copilot CLI supported AI models model comparison task OpenAI Claude GitHub`
- `site:antigravity.google docs models Gemini 4 Argon Hydrogen Antigravity CLI`
- `site:learn.chatgpt.com/docs/models Codex GPT-6.2 Astra Sol GPT-6.1 Terra`
- `GitHub Copilot CLI model supported change model Claude Sonnet 5.5 organization policy GitHub CLI cloud documentation`

### Время, повторы и остановка {#n22}

- tags: лимиты, отмена
- position: 1269, 7

Переиспользовать действующие лимиты времени и циклов исправлений Cockpit. При параллельности отдельно учитывать время по часам и суммарное время исполнителей. По истечении лимита отменять попытку, сохранять её состояние и перед повтором проверять, какие действия успели завершиться.

#### Evidence

- [Project fact] Cockpit отсчитывает оставшееся время работы шагов и отправляет `pause` при исчерпании лимита. — `MarkView/Models/Cockpit/CockpitExecution.swift:234`
- [Project fact] Счётчик циклов видит переходы через шлюз и отражённые в отчётах исправления. Прямые изменения без отчёта в него не попадают. — `MarkView/Models/Cockpit/CockpitStepMeter.swift:3`
- [Project fact] Temporal отключает автоматический повтор activity. При ошибке состояние становится `interrupted`, поскольку шаг уже мог внести изменения. — `tools/cockpit-temporal/workflow.go:237`

### Выбор возможностей по режиму {#n23}

- tags: адаптеры, совместимость
- position: 1273, 80

Для кнопки важен профиль запуска, а не только имя агента. Перед стартом выбирать доступные планирование, запись, делегирование и ревью по версии CLI, разрешениям и интерфейсу. При отсутствии расширенной функции сохранить возможность выполнить тот же этап обычным запросом или последовательно.

#### Evidence

- [Project fact] Ассистенты зарегистрированы в одном списке, а AIOperation выполняет и валидирует разовые запросы, различая тайм-аут и ошибку ответа. — `MarkView/Models/AI/AIOperation.swift:222`
- [Project fact] В Cockpit действуют ограничения инструментов MarkView и проверка состояния проекта до и после шага. — `MarkView/Models/Cockpit/CockpitPlanning.swift:30`
- [AI inference] Для исполнителя с записью нужны отдельный профиль прав и рабочая копия. Профили чтения подходят планировщику и независимым ревьюерам.

### Кнопка и передача задачи {#n28}

- tags: интерфейс, запуск
- position: 1269, 424

После выбора Definition of Done кнопка может использовать текущую передачу цели для короткой задачи или открывать предзаполненный Cockpit, когда нужны несколько этапов, отдельное ревью или лимит. Для согласованного прототипа можно использовать уже существующую передачу в стадию Build. Начало работы стоит фиксировать после успешного запуска выбранного сценария.

#### Evidence

- [Project fact] `startImplementation` отправляет задачу выбранному терминалу и отмечает `implementing` после успешной передачи. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:334`
- [Project fact] Передача из прототипа открывает созданную фичу на стадии Build с доступной кнопкой `Implement with AI`. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:171`
- [Project fact] Поручение включает Definition of Done и указывает использовать уже записанные решения и ответы. — `MarkView/Models/Lifecycle/HandoffPrompt.swift:8`
- [Open assumption] `Implement VDI` трактуется как пример сценарной кнопки. Подтверждённая точка входа в коде называется `Implement with AI`.

### Доказательства и состояние задачи {#n29}

- tags: проверка, доставка
- position: 1277, 170

Поручение каждого этапа содержит критерий завершения и ожидаемый артефакт. MarkView сверяет заявленный результат с тестами, результатом ревью, проверенным SHA, CI и доставкой по правилам проекта. Недоказанное состояние отображается как `unverified`, а явный блокер как `blocked`.

#### Evidence

- [Project fact] Cockpit различает `success`, `blocked` и `unverified` и требует доказательство для каждого заявленного критерия. — `MarkView/Models/Cockpit/CockpitPlan.swift:23`
- [Project fact] Проверка доставки сверяет merge, CI на нужном SHA и публикацию обязательного релиза. — `MarkView/Models/Lifecycle/IssueLifecycleEvidence.swift:199`
- [Project fact] Для изменений самого MarkView руководство требует PR, проверку, merge, Release-сборку и подписанный DMG с merged-коммита. — `CLAUDE.md:199`
- [AI inference] Успех этапа и завершение всей фичи стоит выводить из соответствующих проверок и артефактов.

### Create new project {#n103}

- position: 1243, 251

### Проверка источников {#n7}

- tags: методика
- position: 575, -979

Поисковые запросы и границы проверки доступности функций.

### Объём и проверка запуска {#n31}

- tags: источники, проверка

Исследованы четыре названных агента по исходникам MarkView и официальной документации. Живые запуски не выполнялись. Для каждого нового профиля остаётся проверить доступность на установленной версии, результат, поведение при отказе в разрешении, тайм-аут и остановку дочерних задач.

#### Evidence

- [Project fact] В реестре MarkView также есть Cline, который не входил в перечисление четырёх агентов для этого исследования. — `MarkView/Models/AI/Providers/AssistantProviderList.swift:5`
- [Open assumption] Документированные возможности доступны на локальных версиях CLI с активными тарифами и политиками.

### Запросы о Claude Code {#n32}

- tags: запросы

- `Claude Code official docs goal command subagents agent teams parallel code review headless SDK max turns budget`
- `site:code.claude.com/docs/en Claude Code goal subagents agent teams dynamic workflows code review CLI reference`
- `site:code.claude.com/docs/en Claude Code workflows /workflow scripts parallel phases goal headless review ultrareview`
- `site:code.claude.com/docs/en Claude Code dynamic workflows print mode plan mode on-demand reviews`

### Запросы о Codex {#n33}

- tags: запросы

- `OpenAI Codex official docs goal command multi agent parallel codex exec review app server`
- `site:developers.openai.com/codex OR site:learn.chatgpt.com/docs Codex goals CLI goal multi agents non-interactive code review`
- `Codex CLI goal /goal thread/goal/set token budget multi-agent app-server plan-mode review/start codex exec`
- `site:learn.chatgpt.com/docs Codex subagents max_threads max_depth goals app server changelog`

### Запросы о GitHub Copilot {#n34}

- tags: запросы

- `GitHub Copilot CLI official docs plan autopilot fleet subagents review programmatic mode`
- `site:docs.github.com Copilot CLI ACP goal fleet review hooks max autopilot continues`
- `site:docs.github.com copilot autopilot goal command --autopilot-goal ACP fleet session modes review`
- `site:docs.github.com Copilot CLI /fleet code review CLI --review programmatic GitHub Copilot SDK sessions`

### Запросы об Antigravity {#n35}

- tags: запросы

- `Google Antigravity official documentation CLI ACP agent manager parallel subagents goals code review`
- `site:antigravity.google/docs Antigravity headless structured output goal ACP code review workflow`
- `site:antigravity.google/docs agy acp /goal headless artifacts code review /review print-timeout`
- `site:antigravity.google/docs "/goal" "/review" Google Antigravity CLI goal code review`
