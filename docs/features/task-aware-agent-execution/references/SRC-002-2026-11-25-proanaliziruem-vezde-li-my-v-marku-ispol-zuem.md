---
type: research-map
id: 2026-11-25-proanaliziruem-vezde-li-my-v-marku-ispol-zuem
title: Агентные возможности MarkView
question: Проанализируем, везде ли мы в MarkU используем полностью весь функционал агентов. Клода, кодекса, антигравити и так далее. То есть все вот эти вещи с параллелегизмом, все вот это, все дела. Я не вижу, например, что когда мы кликаем на fix bug, к примеру, это один из вариантов, он выбирает, как правильно это запустить. Я не вижу, что когда мы, например, делаем какой-нибудь research, он делает какой-нибудь... Короче, любые вещи, которые мы запускаем в агенте, мы должны использовать на 100% все возможности этого агента. Я хочу, чтобы ты мне исследовал, что агенты могут, и что у нас уже имплементировано в каждой из частей MarkView.
created: 2026-11-25
status: incomplete
web_queries:
  - Claude Code official docs subagents agent teams worktrees hooks headless CLI Anthropic ...
  - site:docs.cline.bot Cline CLI subagents worktrees parallel act plan headless ACP ...
  - Cline official documentation CLI parallel subagents agent teams worktrees ACP Cline CLI
  - "'Agent Client Protocol'"
  - "'streaming events'"
  - "'thread/start'"
  - Anthropic how we built our multi-agent research system parallel research token usage ...
  - "'90.2%'"
  - Anthropic building effective agents parallelization evaluator optimizer orchestrator workers official ...
  - https://www.anthropic.com/research/building-effective-agents
  - "'15×'"
incomplete: cancelled after 6:54
---

# Агентные возможности MarkView

## Question

Проанализируем, везде ли мы в MarkU используем полностью весь функционал агентов. Клода, кодекса, антигравити и так далее. То есть все вот эти вещи с параллелегизмом, все вот это, все дела. Я не вижу, например, что когда мы кликаем на fix bug, к примеру, это один из вариантов, он выбирает, как правильно это запустить. Я не вижу, что когда мы, например, делаем какой-нибудь research, он делает какой-нибудь... Короче, любые вещи, которые мы запускаем в агенте, мы должны использовать на 100% все возможности этого агента. Я хочу, чтобы ты мне исследовал, что агенты могут, и что у нас уже имплементировано в каждой из частей MarkView.

## Map

- [Агентные возможности MarkView](#n1)
  - [Параллельная работа](#n2)
    - [Параллелизм аудита и диаграмм](#n8)
    - [Лимиты и частичные сбои](#n9)
  - [Глубина и доказательства Research](#n3)
    - [Доступ к вебу и журнал запросов](#n10)
    - [Запросы этого исследования](#n11)
  - [Ревью и модельные судьи](#n4)
    - [Независимость и полномочия проверяющего](#n12)
    - [Проверки формата и точечные повторы](#n13)
  - [Карта сценариев вызова](#n5)
    - [Код, архитектура и операции](#n14)
    - [Документы и исследования](#n15)
    - [Требования, баги и обсуждения](#n16)
    - [Прототипы, UI Studio и QA](#n17)
    - [Передачи в терминал и Cockpit](#n18)
  - [Выбор провайдера и профиля](#n6)
    - [Маршрутизация и исполнение делегатов](#n19)
  - [Замеры качества и затрат](#n7)
    - [Порядок проверок перед усложнением](#n20)

## Nodes

### Агентные возможности MarkView {#n1}

- tags: агенты, оркестрация

MarkView использует возможности агентов по-разному в разных сценариях. 
Выяви все вызовы агентов и проверь на сколько оптимально мы делаем эти вызовы. Порой нужен паралелизм, глубокое исследование, ревью, судьи и так далее

#### Evidence

- [Project fact] Для Build существуют выбор режима и подготовка управляемого запуска, а Fix with AI отправляет терминальный запрос. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:340`
- [Project fact] Research запускает AIOperation.ask один раз на вызов JobHandle.run. — `MarkView/Models/Research/ResearchJobs.swift:315`
- [Project fact] Cockpit включает делегирование по одобренному плану и профилю агента. — `MarkView/Models/Cockpit/CockpitSession.swift:418`
- [Project fact] У приложения есть два основных пути запуска. Фоновые операции идут через `AIOperation` → `CLICompletion`, который выбирает одноразовый CLI или ACP. Интерактивные запросы идут через `sendToAssistant`: приоритет у явно переданного терминала, затем у показанного, затем у терминала выбранного провайдера, затем у любого открытого терминала ассистента. Новый терминал открывается при отсутствии подходящего. — `MarkView/Models/Workspace/AITerminalsController.swift:388`
- [Project fact] Помимо Build и Fix with AI, терминальный путь обслуживает разрешение конфликтов, исправление корзины замечаний, исправление в PR, запуск работы по GitHub Issue и исправление упавшего CI. Отдельно Deployments может передать в терминал анализ окружения или вопрос с логом, а его встроенный советник использует фоновый вызов. — `MarkView/Models/Workspace/FeatureFlowCoordinator.swift:390`
- [Project fact] Агенты могут запускать другой терминал через `markview_agent_start`, в том числе с возобновлением сеанса. Набор инструментов также позволяет отправить запрос, прочитать экран другого агента и дождаться результата. Это отдельный путь межагентной работы через терминалы MarkView. — `MarkView/Models/AgentTools/ControlToolRunner+Agents.swift:68`
- [Project fact] Remote Work поднимает отдельный терминал ассистента на домашнем компьютере и при наличии сохранённого сеанса может его возобновить. Для удалённого Codex профиль явно отключает `features.multi_agent`. Эта настройка относится к Remote Work. — `MarkView/Models/AI/Providers/CodexProvider.swift:346`
- [Project fact] `Deep Research…` открывает тот же ввод New Research. Создание и продолжение карты, развитие ветки, расширение описания, исправление и исследование узла используют общий запуск карты. Он потоково применяет ответы агента, а действия над узлом отклоняются, пока с тем же файлом работает другое задание. Раздачи веток отдельным агентам в этом пути нет. — `MarkView/Models/Research/ResearchMapJobs.swift:167`
- [Project fact] `JobHandle.run` не выставляет `effort`, поэтому глубина рассуждения остаётся на настройках провайдера. Кроме того, один вызов `AIOperation.ask` не гарантирует один ход модели: ACP может запросить до десяти продолжений оборванного ответа в том же сеансе. — `MarkView/Models/AI/ACPAssistant.swift:145`
- [Project fact] Research отключает веб по настройке репозитория и для ACP, но при остальных провайдерах возвращает `allowed: true` без проверки `provider.canSearchWeb`. В частности, `AntigravityProvider.launch` не использует `allowWeb`. Поэтому разрешение в Research не подтверждает, что веб-поиск действительно доступен этому запуску. — `MarkView/Models/Research/ResearchJobs.swift:205`
- [Project fact] Проверка источников Research проверяет существование пути для `Project fact` и наличие URL для `External fact`. Она не проверяет, подтверждает ли файл или страница конкретное утверждение. При отсутствии требуемой ссылки вывод переводится в `AI inference`. — `MarkView/Models/Research/ResearchDocument.swift:151`

### Параллельная работа {#n2}

- tags: параллелизм, Insight, Cockpit

Insight уже делит генерацию на независимые секции, ограничивает число одновременных вызовов и локализует сбои. В Cockpit шаги идут по порядку, поэтому выигрыш стоит искать в независимых проверках и исследованиях; шаги с общими артефактами требуют явных зависимостей.

#### Evidence

- [Project fact] Insight запускает отдельный insight-section на секцию через ограниченную группу задач. Ошибка отдельной секции не отменяет соседние вызовы. — `MarkView/Models/Insight/InsightSession.swift:985`
- [Project fact] Temporal исполняет отдельные активности Cockpit по порядку. Политика MaximumAttempts: 1 исключает автоматический повтор активности, которая могла изменить состояние. — `tools/cockpit-temporal/workflow.go:140`
- [AI inference] Первый кандидат на параллелизм в Cockpit – независимые задачи чтения, чьи результаты можно собрать перед переходом к следующему шагу.

### Параллелизм аудита и диаграмм {#n8}

- tags: аудит, диаграммы

Наиболее прямой кандидат для замера — документы Codebase Audit. Каждый автор получает общий план и задание на свой документ. Ограниченная очередь может сократить ожидание, если объединение файлов и сборка индекса сохранят один порядок.

#### Evidence

- [Project fact] Документы Codebase Audit пишутся в последовательном цикле, внутри которого ожидается и необязательная диаграмма. — `MarkView/Models/Workspace/WorkspaceManager+AIToolRuns.swift:225`
- [Project fact] Диаграммы отчёта Research Map генерируются последовательно, а сбой отдельной диаграммы позволяет продолжить. — `MarkView/Models/Research/ResearchMapOutputJobs.swift:130`
- [Project fact] X-Ray уже ставит картирование деплоя рядом с именованием компонентов, а Prototype ограничивает одновременную генерацию экранов. — `MarkView/Models/Architecture/ArchitectureStore.swift:377`
- [AI inference] Сравнить очередь из двух–трёх вызовов с последовательной на одинаковых планах и проверить время до первого результата, целостность ссылок и лимиты провайдера.

### Лимиты и частичные сбои {#n9}

- tags: квоты, повторы, Insight

Для очередей полезны общий лимит на провайдера и повтор отдельной части. Insight уже поддерживает повтор секции, но итоговое состояние готовности выставляется даже при нуле успешных секций. Это конкретный изъян сигнала о завершении.

#### Evidence

- [Project fact] В Insight лимит составляет пять одновременных секций на одну группу. — `MarkView/Models/Insight/InsightSession.swift:131`
- [Project fact] Отдельную секцию можно заново запросить через insight-section-retry. — `MarkView/Models/Insight/InsightSession.swift:244`
- [Project fact] После группы Insight вычисляет readyCount, но без проверки на ноль присваивает node.status = .ready и allSectionsReady = true для текущего узла. — `MarkView/Models/Insight/InsightSession.swift:1044`
- [Project fact] Именование кластеров X-Ray добавляет все подготовленные пакеты в группу сразу; аннотирование книги в том же классе использует ограниченную очередь. — `MarkView/Models/Architecture/ArchitectureStore.swift:758`
- [AI inference] Сначала стоит уточнить статус полного сбоя и измерить пики одновременных вызовов, затем выбрать ограничения для нескольких задач, использующих одну квоту.

### Глубина и доказательства Research {#n3}

- tags: Research, источники

Для короткого вопроса достаточно текущего потокового запуска. Для широкой темы стоит испытать разбиение на независимые ветки, сбор доказательств в отдельных вызовах и общий синтез с проверкой спорных утверждений. Текущая проверка карты подтверждает наличие файла или URL в ссылке, поэтому для ключевых фактов нужен отдельный проход по содержимому источников.

#### Evidence

- [Project fact] При сохранении карта передаёт находки в checkedFinding, понижая метку до AI inference при несоответствии требованиям к ссылке. — `MarkView/Models/Research/ResearchMapDocument.swift:540`
- [Project fact] Research отключает веб-поиск по настройке проекта и для ACP; CLI-запуск получает разрешение через allowWeb и записывает наблюдаемые запросы. — `MarkView/Models/Research/ResearchJobs.swift:205`
- [External fact] Anthropic описывает исследовательскую систему с ведущим агентом, независимыми направлениями поиска и итоговым синтезом. — <https://www.anthropic.com/research/multi-agent-research-system>
- [AI inference] Результаты веток следует собирать отдельно и применять к карте одним сборщиком, чтобы сохранить ссылки между узлами и совместить это с потоковым выводом.

### Доступ к вебу и журнал запросов {#n10}

- tags: веб-поиск, провайдеры

Research и Project Operations по-разному определяют доступность веб-поиска. Antigravity показывает конкретное расхождение между этими проверками. При испытании глубокого режима стоит проверить, какие запросы реально отправляются и как сохраняются прочитанные источники.

#### Evidence

- [Project fact] Research разрешает веб-поиск, если проект его не отключил и провайдер не использует ACP. — `MarkView/Models/Research/ResearchJobs.swift:205`
- [Project fact] Project Operations запускает веб-раунд лишь для оставшихся неизвестных и при canSearchWeb у провайдера. — `MarkView/Models/ProjectOps/ProjectOperationDiscoveryService.swift:71`
- [Project fact] Фоновый запуск Antigravity не использует request.allowWeb при построении аргументов. — `MarkView/Models/AI/Providers/AntigravityProvider.swift:64`
- [Project fact] Research записывает замеченные события webSearch, а запросы, помеченные CLI как отклонённые, исключает из итогового списка. — `MarkView/Models/Research/ResearchJobs.swift:326`
- [Open assumption] Поведение фактически установленного Antigravity при включении и отключении веба требует проверки. По аргументам запуска нельзя установить, отправляется ли запрос.

### Запросы этого исследования {#n11}

- tags: методика, веб-поиск

Отправлены три веб-запроса. Их точный текст указан в находках.

#### Evidence

- [External fact] Запрос `Anthropic building effective agents parallelization evaluator optimizer orchestrator workers official`. Открыто руководство Anthropic с описанием шаблонов оркестрации. — <https://www.anthropic.com/research/building-effective-agents>
- [External fact] Запрос `LLM as a judge position bias verbosity bias MT Bench Zheng paper`. Открыта статья авторов MT-Bench. — <https://arxiv.org/abs/2306.05685>
- [External fact] Запрос `OpenAI a practical guide to building agents evaluation single agent multi agent official`. Открыто руководство OpenAI. — <https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/>

### Ревью и модельные судьи {#n4}

- tags: ревью, QA, Cockpit

Managed Cockpit уже связывает независимое ревью и перепроверку замечаний с конкретной ревизией. В X-Ray и QA модель оценивает diff или экран и выдаёт замечания. Вторую оценку стоит испытать на спорных или существенных выводах, сверяя её с исходным артефактом и результатами воспроизводимых проверок.

#### Evidence

- [Project fact] Cockpit относит review, tests, reverify, checks и final к проверочным шагам. Открытые замечания и исправления без проверки на доставляемой ревизии блокируют публикацию. — `MarkView/Models/Cockpit/CockpitManagedRun.swift:85`
- [Project fact] X-Ray запрашивает структурированные вердикты по diff одним вызовом. QA отдельно вызывает qa-review со снимком, наблюдениями и доказательствами шага. — `MarkView/Models/Architecture/ChangeReviewStore.swift:689`
- [Project fact] QA дедуплицирует экраны по сигнатуре и ограничивает число вызовов ревью; модель получает снимок и сведения о пройденном шаге. — `MarkView/Models/QA/QARunModel.swift:514`
- [External fact] В экспериментах MT-Bench перестановка ответов могла изменить вердикт модели-судьи; авторы также наблюдали влияние многословия и предпочтение собственной модели. — <https://arxiv.org/abs/2306.05685>

### Независимость и полномочия проверяющего {#n12}

- tags: Cockpit, критерии

Для ревью Cockpit предпочитает другого провайдера, когда он доступен. Проверочные шаги защищены аудитом изменений, а решения Supervisor остаются советом. Для второго судьи полезны критерий, ссылка на доказательство и вариант «недостаточно данных», особенно при расхождении с первой оценкой.

#### Evidence

- [Project fact] При составлении плана выбирается первый доступный reviewer, отличный от implementer. Если такого нет, используется тот же агент-провайдер. — `MarkView/Models/Cockpit/CockpitSession.swift:670`
- [Project fact] Проверочным шагам запрещены изменения исходников и коммиты. Агенту сообщается, что MarkView сравнивает состояние проекта до и после шага. — `MarkView/Models/Cockpit/CockpitSession.swift:994`
- [Project fact] Ответ Supervisor носит рекомендательный характер. Допустимые действия определяют политика инструментов и аудит шага. — `MarkView/Models/Cockpit/CockpitSupervisor.swift:3`
- [Project fact] QA использует выбранного ассистента и для решений по ходу прогона, и для оценки экранов. — `MarkView/Models/QA/QARunModel.swift:234`
- [AI inference] При попарной оценке стоит менять порядок вариантов в контрольной выборке и отдавать существенные расхождения на ручную проверку.

### Проверки формата и точечные повторы {#n13}

- tags: валидация, повторы

MarkView уже применяет проверки структуры и ограниченные повторы там, где ошибку можно назвать точно. Этот подход подходит диаграммам, переводам и сценариям QA. В X-Ray отдельно стоит проверить, как интерфейс обозначает последний ответ, отклонённый валидатором.

#### Evidence

- [Project fact] DiagramAI проверяет структуру и ограничивает исправление двумя запросами после первого ответа. — `MarkView/Models/AI/DiagramAI.swift:356`
- [Project fact] Research Map сначала проверяет черновик отчёта, а при переводе повторно запрашивает узлы с конкретными проблемами. — `MarkView/Models/Research/ResearchMapOutputJobs.swift:237`
- [Project fact] QA Generator по умолчанию делает до трёх попыток и возвращает сценарий со списком оставшихся замечаний. — `MarkView/Models/QA/QAGenerator.swift:22`
- [Project fact] X-Ray сохраняет последнего разобранного кандидата перед проверкой и при AIOperationError возвращает его вызывающему коду. — `MarkView/Models/Architecture/ArchitectureStore.swift:619`
- [AI inference] Непринятый ответ имеет смысл показывать как частичный там, где вызывающий код использует его для продолжения анализа.

### Карта сценариев вызова {#n5}

- tags: инвентаризация, вызовы

Фоновые вызовы распределены между анализом проекта, работой с документами и задачами, дизайном и QA. В одном сценарии может быть несколько обращений к модели: например, Prototype отдельно планирует работу и генерирует части интерфейса. В дочерних узлах вызовы сгруппированы по пользовательским сценариям.

#### Evidence

- [Project fact] Для Codebase Audit отдельный вызов составляет план документов, затем приложение запрашивает текст каждого документа и нужные диаграммы. — `MarkView/Models/Workspace/WorkspaceManager+AIToolRuns.swift:207`
- [Project fact] Prototype вызывает модель для плана, а затем отдельно для оболочки, стилей и данных. — `MarkView/Models/Prototype/PrototypeAI.swift:369`
- [Project fact] В QA различаются вызовы обсуждения сценария, генерации, сводки, решений по шагам и ревью экранов. — `MarkView/Models/QA/QAModel.swift:363`

### Код, архитектура и операции {#n14}

- tags: X-Ray, Code, Project Ops

К этой группе относятся построение моделей кода и архитектуры, именование и аннотирование, поиск и объяснение фрагментов, ревью изменений и обнаружение проектных операций. Запросы подсистемы X-Ray уже используют кэш и low effort; поиск операций добавляет веб-раунд по оставшимся пробелам.

#### Evidence

- [Project fact] X-Ray локально выделяет структуру, затем запрашивает названия кластеров, подсистемы, картирование деплоя и аннотации книги. — `MarkView/Models/Architecture/ArchitectureStore.swift:352`
- [Project fact] В Code есть запросы архитектуры кода, диаграмм последовательности, объяснений связей и узлов. — `MarkView/Models/Architecture/ArchitectureStore.swift:825`
- [Project fact] Координатор направляет действия объяснения файла и символа, вопросов по коду и оценки важности в соответствующие подсистемы. — `MarkView/Models/Architecture/CodeAndXRayCoordinator.swift:275`
- [Project fact] X-Ray запускает understand-scope, understand и xray-search отдельными вызовами. — `MarkView/Models/Architecture/XRayFilterStore.swift:332`
- [Project fact] ChangeReviewStore запрашивает объяснение файлов PR, ответы на вопросы, общее ревью и пояснения замечаний. — `MarkView/Models/Architecture/ChangeReviewStore.swift:368`
- [Project fact] Project Operations выполняет локальный запрос, после чего при необходимости и поддержке провайдера запускает веб-раунд. — `MarkView/Models/ProjectOps/ProjectOperationDiscoveryService.swift:63`

### Документы и исследования {#n15}

- tags: документы, Research, Insight

Здесь сосредоточены Research и Insight, генерация и редактирование диаграмм, Code Structure Map, Critic, Codebase Audit, перевод Markdown и операции экспорта книги. Форматные проверки, частичные результаты и повтор отдельных частей дают основу для оптимизации длинных операций.

#### Evidence

- [Project fact] Research запускает follow-up и правку выбранного раздела по комментарию. Перед записью правки проверяется, что исходный раздел сохранился. — `MarkView/Models/Research/ResearchJobs.swift:91`
- [Project fact] Research Map отдельно запрашивает рисунок узла, формирует отчёт и переводит карту пакетами с сохранением исходного текста невалидных узлов. — `MarkView/Models/Research/ResearchMapOutputJobs.swift:16`
- [Project fact] GraphRAG использует модель для классификации и каркаса, далее Insight запрашивает разделы отдельно. — `MarkView/Models/Insight/GraphRAG.swift:186`
- [Project fact] Оконные AI-инструменты вызывают генератор для создания и редактирования диаграмм и отдельно запускают Code Structure Map, Critic и Codebase Audit. — `MarkView/Models/Workspace/WorkspaceManager+AIToolRuns.swift:17`
- [Project fact] Перевод Markdown вызывает модель по фрагментам, пропускает защищённые блоки и повторяет фрагмент при расхождении структуры. — `MarkView/Models/Workspace/DocumentTranslator.swift:117`
- [Project fact] Экспорт PDF книги отдельно запрашивает перевод и сокращение фрагментов. Титульное название и подписи также имеют отдельные вызовы. — `MarkView/Models/Book/BookPDFAssistant.swift:33`
- [Project fact] Объяснение и перевод выделения идут через selection-action. — `MarkView/Models/Architecture/CodeAndXRayCoordinator.swift:116`

### Требования, баги и обсуждения {#n16}

- tags: Lifecycle, требования, Discussions

Lifecycle вызывает агента при заведении фич и багов, проработке требований и решений, исследовании, ревью и декомпозиции. Короткие действия обычно укладываются в один вызов, а пакетные ответы позволяют собрать связанные изменения за один раунд.

#### Evidence

- [Project fact] FeatureIntake вызывает модель для быстрого и полного создания фичи, заведения бага, обсуждения и анализа бага. — `MarkView/Models/Lifecycle/FeatureIntake.swift:84`
- [Project fact] FeatureAI запрашивает исследование идеи, обработку ответов, консолидацию требований, дополнительные варианты, сравнение и исследование темы. — `MarkView/Models/Lifecycle/FeatureAI.swift:518`
- [Project fact] FeatureAI также вызывает модель для ревью, критериев приёмки, разбора замечаний, проверки устаревших решений и обновления требований и обзора. — `MarkView/Models/Lifecycle/FeatureAI.swift:1095`
- [Project fact] Действия над выделением, чат о фиче и декомпозиция используют отдельные метки фоновых вызовов. — `MarkView/Models/Lifecycle/FeatureAI.swift:1626`
- [Project fact] AI-поиск похожих багов в корзину вызывает FeatureAssistant.structured с отдельной схемой ответа. — `MarkView/Models/Lifecycle/BugBatch.swift:118`
- [Project fact] Discussions запускает потоковый discussion для очередного вопроса с контекстом проекта. — `MarkView/Models/Discussion/DiscussionsHost.swift:51`

### Прототипы, UI Studio и QA {#n17}

- tags: Prototype, UI Studio, QA

Prototype разделяет план, основу, экраны, компоненты, правки и спецификацию для передачи. UI Studio использует отдельных помощников для подготовки симуляции, данных, экранов, правок и проверки. В QA генерация сценария, выбор действий и визуальное ревью имеют разную частоту и требования к контексту.

#### Evidence

- [Project fact] После prototype:plan Prototype запускает отдельные вызовы для основы, экранов и компонентов, а для правок и передачи спецификации использует prototype:revise и prototype:spec. — `MarkView/Models/Prototype/PrototypeAI.swift:369`
- [Project fact] UI Studio вызывает ui-studio:prepare для неизвестных запросов. Построение карты окружения и пополнение данных также идут через фоновые вызовы. — `MarkView/Models/UIStudio/UIStudioAgents.swift:18`
- [Project fact] Экран и его контекст подготавливаются отдельным структурированным вызовом ui-studio:screen. — `MarkView/Models/UIStudio/UIStudioSession+Screens.swift:130`
- [Project fact] Правка интерфейса, исправление данных и проверка окружения имеют отдельные операции ui-studio:edit, ui-studio:fix-data и ui-studio:review. — `MarkView/Models/UIStudio/UIStudioChangeFlow.swift:96`
- [Project fact] QA обсуждает, суммирует и генерирует сценарии. В исполнении qa-step выбирает одно действие за ход, а qa-review отдельно оценивает отобранные экраны. — `MarkView/Models/QA/QARunAssistant.swift:4`
- [AI inference] Для частых вызовов qa-step и UI Studio полезно измерять стоимость успешного действия. Обзор целого сценария можно оценивать отдельно от задержки каждого хода.

### Передачи в терминал и Cockpit {#n18}

- tags: терминал, Cockpit, GitHub

К уже найденным терминальным передачам добавляются Prototype Handoff и подготовка текста задач из ревью PR. У Cockpit свои вызовы для планирования и Supervisor, плюс терминальный исполнитель шага и запуск QA. GitHub также умеет отдельно объяснять упавший прогон в интерфейсе.

#### Evidence

- [Project fact] Prototype Handoff открывает терминал выбранного агента и отправляет отредактированный brief. — `MarkView/Views/Prototype/PrototypeHandoffDraftView.swift:186`
- [Project fact] Действие с задачами из PR-ревью передаёт текст через sendToAssistant с submit: false. — `MarkView/Models/Architecture/CodeAndXRayCoordinator.swift:559`
- [Project fact] Первичный план и его уточнение используют cockpit-plan, а для Managed Cockpit этапы доставки добавляет приложение. — `MarkView/Models/Cockpit/CockpitSession.swift:652`
- [Project fact] На вопросы исполнителя Cockpit отвечает отдельный фоновый вызов cockpit-supervisor с выбранным провайдером и моделью. — `MarkView/Models/Cockpit/CockpitSession.swift:299`
- [Project fact] Исполнитель шага получает запрос в терминале. Для привязанного сценария есть отдельный путь через CockpitQAAttempt. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:163`
- [Project fact] Объяснение сбоя GitHub Actions запускается через github-explain-failure и выводится потоком. — `MarkView/Models/Git/GitHubStore.swift:561`

### Выбор провайдера и профиля {#n6}

- tags: CLI, ACP, провайдеры

Терминальный профиль, фоновый режим и встроенное делегирование дают разные возможности даже у одного провайдера. Выбор для сложного сценария стоит привязывать к необходимым действиям и проверять на фактически установленной версии CLI.

#### Evidence

- [Project fact] Реестр включает Claude, Codex, Cline, Copilot и Antigravity. Cockpit для одобренного шага берёт способ делегирования из профиля агента. — `MarkView/Models/Cockpit/CockpitSession.swift:408`
- [Project fact] Фоновый Claude ограничивает список инструментов чтением, поиском по проекту и веб-инструментами при разрешении. Подагент в этом списке отсутствует. — `MarkView/Models/AI/Providers/ClaudeProvider.swift:174`
- [Project fact] Фоновый Codex запускается с read-only и --ephemeral, а завершённый agent_message передаётся в onDelta целиком. — `MarkView/Models/AI/Providers/CodexProvider.swift:237`
- [Open assumption] Доступность нативного делегирования и модельных режимов в установленных CLI зависит от реального профиля запуска и требует отдельного прогона.

### Маршрутизация и исполнение делегатов {#n19}

- tags: маршрутизация, делегирование

У терминальной передачи есть fallback на уже открытый терминал другого провайдера. Когда выбранный исполнитель важен для воспроизводимости, его нужно закрепить так, как это делает Prototype Handoff. Нативные подагенты Cockpit и терминалы, запущенные через MCP, требуют разных способов отслеживания.

#### Evidence

- [Project fact] sendToAssistant берёт явный терминал или показанный AI-терминал, затем открытый терминал выбранного провайдера или любой открытый AI-терминал. Новый терминал открывается, когда подходящей сессии нет. — `MarkView/Models/Workspace/AITerminalsController.swift:395`
- [Project fact] Prototype Handoff передаёт в sendToAssistant явно выбранный терминал. — `MarkView/Views/Prototype/PrototypeHandoffDraftView.swift:186`
- [Project fact] Cockpit просит завершить или остановить подагентов до сдачи шага и сверяет оставшиеся процессы терминала. — `MarkView/Models/Cockpit/CockpitAgentAttempt.swift:137`
- [Project fact] MCP-передача адресуется терминалу, проверяет его занятость и возвращает идентификатор для ожидания и чтения. — `MarkView/Models/AgentTools/ControlToolRunner+Agents.swift:142`

### Замеры качества и затрат {#n7}

- tags: метрики, качество, затраты

Журнал фоновых вызовов даёт основу для замеров задержки, токенов и стоимости. Для сравнения схем нужна ещё оценка принятия результата: успешное завершение CLI фиксируется раньше проверки ответа. Сравнивать один вызов, параллельные ветки и дополнительное ревью стоит на одних и тех же задачах.

#### Evidence

- [Project fact] AICallLog хранит метку, провайдера, модель, effort, длительность, токены, доступную стоимость и исход CLI без текста запроса или ответа. — `MarkView/Models/AI/AICallLog.swift:6`
- [Project fact] CLICompletion пишет ok при получении результата. AIOperation разбирает и проверяет его после возврата runner. — `MarkView/Models/AI/AIOperation.swift:279`
- [AI inference] Для эксперимента нужны сквозная длительность, число вызовов и повторов, доля принятых результатов, подтверждённые находки и ложные срабатывания.
- [Open assumption] В разборе не было живых замеров качества, стоимости и задержки; статический аудит выявляет кандидатов на оптимизацию.

### Порядок проверок перед усложнением {#n20}

- tags: приоритеты, эксперимент

Начать с измерения текущих вызовов и исправления сигналов о частичном результате. Затем сравнить последовательный и ограниченно параллельный Codebase Audit. После этого испытать глубокий Research и дополнительного судью на отдельных наборах широких вопросов и спорных находок.

#### Evidence

- [Project fact] Project Operations уже применяет дополнительный вызов только после локального раунда, если остались неизвестные и есть поддержка веба. — `MarkView/Models/ProjectOps/ProjectOperationDiscoveryService.swift:71`
- [Project fact] Supervisor запоминает ответы на повторные вопросы и ограничивает число новых вопросов в одном шаге. — `MarkView/Models/Cockpit/CockpitSupervisor.swift:125`
- [AI inference] Для Research сравнивать полноту и долю выводов, подтверждённых источниками. Для ревью сравнивать найденные дефекты и ложные срабатывания. Для параллелизма сравнивать время и долю полностью собранных результатов при одинаковом входе.
