---
type: research-map
id: 2026-11-12-na-dannyj-moment-a-podderzivau-v-kacestve-agenta
title: Доступные альтернативы агентам программирования
question: На данный момент я поддерживаю в качестве агента Cloud, Codex, Antigravity, Copilot и CLion. Скажи мне, есть ли еще какие-то агенты, особенно, может быть, я знаю DeepSeek, там есть вот эти с программированием какие-то агенты. Поищи, пожалуйста, и покажи мне все возможные варианты, которые мне бы стоило бы еще подключить параллельно с этим. Дороговато просто сейчас.
created: 2026-11-12
status: complete
web_queries:
  - open source coding agents CLI deepseek API aider cline roo code pricing ...
  - site:api-docs.deepseek.com quick start models pricing api ...
  - site:docs.cline.bot deepseek provider setup ...
  - site:docs.roocode.com providers deepseek roo code ...
  - https://api-docs.deepseek.com/quick_start/pricing
  - https://docs.continue.dev/cli/quickstart
  - site:docs.openhands.dev CLI OpenHands software agent ...
  - https://api-docs.deepseek.com/guides/codex
  - Qwen coding models API Qwen3 Coder documentation context ...
  - site:platform.minimax.io docs models coding tool calls MiniMax API ...
  - site:platform.moonshot.ai/docs Kimi K2 coding agent tool use
---

# Доступные альтернативы агентам программирования

## Question

На данный момент я поддерживаю в качестве агента Cloud, Codex, Antigravity, Copilot и CLion. Скажи мне, есть ли еще какие-то агенты, особенно, может быть, я знаю DeepSeek, там есть вот эти с программированием какие-то агенты. Поищи, пожалуйста, и покажи мне все возможные варианты, которые мне бы стоило бы еще подключить параллельно с этим. Дороговато просто сейчас.

## Map

- [Доступные альтернативы агентам программирования](#n1)
  - [Совместимость с MarkView](#n2)
    - [Что уже встроено](#n6)
    - [Интеграция зависит от режима](#n7)
    - [Учёт лимитов](#n8)
  - [Дополнительные готовые агенты](#n3)
    - [OpenCode](#n9)
    - [Qwen Code](#n10)
    - [Aider](#n11)
      - [Ещё один CLI: Reasonix](#n18)
    - [Continue, Kilo и Cursor](#n12)
    - [Устаревшие рекомендации](#n13)
  - [DeepSeek и другие модели](#n4)
    - [DeepSeek внутри существующего агента](#n14)
      - [DeepSeek в Codex](#n17)
    - [Другие семейства моделей](#n15)
      - [Qwen для программирования](#n24)
      - [GLM через Z.AI](#n25)
      - [Модели через OpenRouter](#n26)
      - [Модели MiniMax](#n27)
      - [Kimi от Moonshot AI](#n28)
    - [Локальные модели](#n16)
  - [Расходы и выбор](#n5)
    - [Цена DeepSeek API](#n19)
    - [Бесплатные и фиксированные варианты](#n20)
    - [Практический порядок проверки](#n21)
    - [Границы исследования](#n22)
    - [Поисковые запросы](#n23)

## Nodes

### Доступные альтернативы агентам программирования {#n1}

- tags: агенты, стоимость

Исследую дополнительные агенты и модели, их совместимость с проектом и способы снизить расходы; отдельно рассмотрю DeepSeek.

### Совместимость с MarkView {#n2}

- tags: интеграция

Проверю, как проект обнаруживает и подключает агентов и какие варианты уже поддерживает.

### Что уже встроено {#n6}

- tags: Cline, поддержка

В исходном коде перечислены Claude, Codex, Cline, Copilot и Antigravity. Cline уже присутствует: сначала стоит проверить его как путь к другим моделям.

#### Evidence

- [Project fact] Перечисление CLITool содержит claude, codex, cline, copilot и antigravity. — `MarkView/Models/AIAssistants.swift:13`

### Интеграция зависит от режима {#n7}

- tags: CLI, ACP

Наличие CLI или поддержки ACP у внешнего инструмента само по себе не означает, что он появится в селекторе MarkView. Для полноценной интеграции потребуется отдельная проверка и, вероятно, доработка.

#### Evidence

- [Project fact] ACPAssistant отдельно запускает и настраивает поддерживаемые CLI. — `MarkView/Models/ACPAssistant.swift:3`
- [AI inference] Поддержка стороннего CLI в приложении требует проверки его протокола, запуска и отображения в интерфейсе.

### Учёт лимитов {#n8}

- tags: лимиты

Встроенный учёт использования сейчас ориентирован на Claude и Codex; для новых агентов отображение расходов придётся оценивать отдельно.

#### Evidence

- [Project fact] UsageAgent перечисляет только claude и codex. — `MarkView/Models/AgentUsage.swift:10`

### Дополнительные готовые агенты {#n3}

- tags: инструменты

Сравню доступные терминальные и графические инструменты для программирования.

### OpenCode {#n9}

- tags: CLI, много моделей
- number: 1

Приоритетный кандидат для подключения: терминальный агент с переключением провайдеров и моделей; можно попробовать DeepSeek. Документация также описывает вход через ChatGPT Plus или Pro с расходованием существующего лимита.

#### Evidence

- [External fact] OpenCode описывает выбор провайдера через /connect, модели через /models и вход через ChatGPT Plus или Pro. — <https://opencode.ai/docs/providers/>
- [AI inference] Гибкость провайдеров делает OpenCode полезным первым кандидатом для сравнения в проекте.

### Qwen Code {#n10}

- tags: CLI, JetBrains
- number: 2

Терминальный агент с вариантами подключения Qwen, DeepSeek и других поставщиков; документация также перечисляет интеграцию с JetBrains. Проверяйте актуальный способ авторизации и тариф: бесплатный доступ нельзя предполагать заранее.

#### Evidence

- [External fact] Документация перечисляет подписку Qwen, API с оплатой по использованию, сторонних поставщиков включая DeepSeek и документацию по JetBrains. — <https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/>

### Aider {#n11}

- tags: CLI, DeepSeek
- number: 3

Терминальный инструмент для совместного редактирования кода с прямым подключением DeepSeek и других моделей; подходит для сравнения стоимости на небольших задачах.

#### Evidence

- [External fact] Aider документирует прямое подключение DeepSeek через API и выбор модели в командной строке. — <https://aider.chat/docs/llms/deepseek.html>

### Ещё один CLI: Reasonix {#n18}

- tags: CLI, DeepSeek

Reasonix — дополнительный терминальный агент, для которого DeepSeek публикует инструкцию подключения своего API. Его можно рассмотреть после основных кандидатов; совместимость с MarkView не проверялась.

#### Evidence

- [External fact] DeepSeek описывает Reasonix как терминального coding agent с настройкой DeepSeek API. — <https://api-docs.deepseek.com/quick_start/agent_integrations/reasonix/>
- [Open assumption] Интеграция Reasonix в MarkView потребует отдельной оценки.

### Continue, Kilo и Cursor {#n12}

- tags: IDE, CLI
- number: 4

Continue предлагает CLI и расширение JetBrains; Kilo — CLI и расширения JetBrains и VS Code. Cursor — отдельный редактор с ограниченным бесплатным уровнем: его стоит оценивать, если нужен ещё один интерфейс, а не только дешёвая модель.

#### Evidence

- [External fact] Continue имеет CLI и расширения для VS Code и JetBrains. — <https://docs.continue.dev/>
- [External fact] Kilo перечисляет расширения VS Code и JetBrains и CLI. — <https://kilo.ai/docs>
- [External fact] Cursor предлагает бесплатный уровень с ограниченным числом запросов агента. — <https://cursor.com/pricing>

### Устаревшие рекомендации {#n13}

- tags: закрыто, Google
- number: 5

Roo Code Extension закрыт, а прежний потребительский вход Google в Gemini CLI прекращён. Их не стоит считать новыми независимыми бесплатными квотами; Antigravity у вас уже есть.

#### Evidence

- [External fact] Документация Roo Code сообщает о закрытии расширения 15 мая и указывает на общественный форк ZooCode. — <https://roocodeinc.github.io/Roo-Code/>
- [External fact] С 18 июня 2026 года потребительские аккаунты Gemini Code Assist больше не обслуживают запросы Gemini CLI через Login with Google. — <https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals>

### DeepSeek и другие модели {#n4}

- tags: модели

Разделю модели и приложения-агенты и проверю варианты их совместного использования.

### DeepSeek внутри существующего агента {#n14}

- tags: DeepSeek, Cline

DeepSeek — поставщик моделей и API, который можно использовать через агентскую оболочку. Наиболее короткий путь для проверки в MarkView — изучить настройку DeepSeek в уже поддерживаемом Cline; отдельную работу этой конфигурации через ACP ещё нужно проверить.

#### Evidence

- [External fact] Cline описывает выбор провайдера DeepSeek, ввод API-ключа и выбор модели. — <https://docs.cline.bot/provider-config/deepseek>
- [Project fact] Cline включён в CLITool и работает через ACPAssistant. — `MarkView/Models/AIAssistants.swift:16`
- [Open assumption] Настройка провайдера в установленном Cline будет доступна при запуске MarkView через ACP; это не проверялось.

### DeepSeek в Codex {#n17}

- tags: Codex, API

DeepSeek также публикует инструкцию по подключению своих моделей к уже установленному Codex. Это ещё один способ попробовать модель без добавления нового агента; изменение общей конфигурации Codex может повлиять на другие его клиенты.

#### Evidence

- [External fact] Инструкция DeepSeek описывает настройку провайдера для Codex CLI, настольного приложения и расширения IDE через общую конфигурацию; также описано переключение между группами истории при смене способа входа. — <https://api-docs.deepseek.com/quick_start/agent_integrations/codex/>

### Другие семейства моделей {#n15}

- tags: Qwen, MiniMax, GLM

Для сравнения с DeepSeek можно исследовать Qwen, MiniMax, GLM через Z.AI и модели через OpenRouter. Это варианты провайдеров для агента, а не обязательно отдельные самостоятельные агенты.

#### Evidence

- [External fact] Qwen Code перечисляет сторонних провайдеров DeepSeek, MiniMax, Z.AI, Kimi и OpenRouter. — <https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/>
- [External fact] Cline перечисляет провайдеров Alibaba Qwen, MiniMax, Z AI и OpenRouter. — <https://docs.cline.bot/provider-config/deepseek>

### Qwen для программирования {#n24}

- tags: Qwen, API

Qwen-Coder поддерживает генерацию кода и вызов инструментов через API. Alibaba рекомендует также рассмотреть актуальные модели общего назначения; конкретную модель и её доступность стоит проверять у провайдера.

#### Evidence

- [External fact] Документация Alibaba описывает генерацию кода и вызов инструментов и рекомендует рассмотреть новейшую модель общего назначения. — <https://www.alibabacloud.com/help/en/model-studio/qwen-coder>

### GLM через Z.AI {#n25}

- tags: GLM, Z.AI

GLM доступен через Coding Plan или обычный API с предоплаченным балансом. У этих способов разные адреса OpenAI-совместимого API; доступные модели зависят от прав аккаунта.

#### Evidence

- [External fact] Документация ZCode различает адреса Coding Plan и обычного API Z.AI и указывает, что доступность моделей зависит от аккаунта. — <https://zcode.z.ai/en/docs/configuration>

### Модели через OpenRouter {#n26}

- tags: OpenRouter, маршрутизация

OpenRouter — посредник для доступа к моделям и выбора обслуживающего провайдера, а не отдельное семейство моделей. Маршрутизация учитывает цену, скорость и доступность; для сравнения важно зафиксировать модель и настройки маршрута.

#### Evidence

- [External fact] OpenRouter выбирает провайдера для модели с учётом эффективной цены, пропускной способности, задержки и ограничений. — <https://github.com/OpenRouterTeam/docs/blob/main/guides/routing/provider-selection.mdx>
- [AI inference] Фиксация модели и маршрута делает сравнение результатов более сопоставимым.

### Модели MiniMax {#n27}

- tags: MiniMax, API

MiniMax предлагает семейство языковых моделей, включая M3 и M3.1 Flash, и отдельную API-платформу. Перед подключением нужно проверить доступность модели и настройки выбранного агента.

#### Evidence

- [External fact] Сайт MiniMax перечисляет M3 и M3.1 Flash и ссылается на API Platform. — <https://www.minimax.io/m-plan>
- [Open assumption] Выбранный агент и учётная запись поддерживают нужную модель MiniMax; это необходимо проверить.
- [AI inference] Поисковые запросы: MiniMax coding model API tool use documentation; site:platform.minimax.io docs models coding tool calls MiniMax API

### Kimi от Moonshot AI {#n28}

- tags: Kimi, API
- position: 801, 345

Kimi можно подключать к существующим агентам программирования. В руководстве производителя перечислены, например, Cline и OpenCode; перед настройкой следует проверить актуальные идентификаторы моделей и инструкции агента.

#### Evidence

- [External fact] Kimi Open Platform перечисляет инструменты, использующие Kimi K2, и ссылки на инструкции по подключению. — <https://platform.kimi.ai/blog/posts/coding_with_kimi_agents_setup>
- [AI inference] Поисковые запросы: site:platform.moonshot.ai docs kimi coding agent tool calls; site:platform.moonshot.ai/docs Kimi K2 coding agent tool use

### Локальные модели {#n16}

- tags: Ollama, локально

Aider и OpenCode документируют работу с локальными моделями через Ollama. Это путь без оплаты облачного API за каждый запрос, но практическая скорость и качество зависят от модели и возможностей Mac.

#### Evidence

- [External fact] OpenCode документирует подключение Ollama среди провайдеров. — <https://opencode.ai/docs/providers/>
- [AI inference] Локальный запуск не требует оплаты облачного API за запросы, но использует ресурсы собственного компьютера.
- [Open assumption] Объём памяти и производительность Mac достаточны для выбранной модели; характеристики компьютера не исследовались.

### Расходы и выбор {#n5}

- tags: цены

Сопоставлю бесплатные уровни, оплату API и практические ограничения.

### Цена DeepSeek API {#n19}

- tags: API, токены

На 12 ноября 2026 года `deepseek-flash` стоит за миллион токенов при отсутствии попадания во входной кэш $0.15 вне пика или $0.30 в пик; выход — $0.60 или $1.20 соответственно. Например, миллион входных и 200 тысяч выходных токенов без кэша обойдутся примерно в $0.27–0.54; агент может расходовать их за много последовательных вызовов.

#### Evidence

- [External fact] DeepSeek публикует отдельные тарифы для входа, выхода, попаданий в кэш и пикового времени. — <https://api-docs.deepseek.com/quick_start/pricing/>
- [AI inference] Пример рассчитан как 1 × входной тариф плюс 0.2 × выходной тариф; дополнительные платные функции в него не входят.

### Бесплатные и фиксированные варианты {#n20}

- tags: бесплатно, подписка

В Cline можно искать модели с отметкой FREE, использовать локальные модели или проверить ClinePass за $9.99 в месяц с квотой. Доступность бесплатных моделей и лимиты надо проверить перед выбором.

#### Evidence

- [External fact] Cline описывает бесплатные модели, локальный запуск и ClinePass за $9.99 в месяц с лимитом использования. — <https://docs.cline.bot/core-workflows/task-management>

### Практический порядок проверки {#n21}

- tags: рекомендация, сравнение

Сначала проверить Cline с DeepSeek или бесплатной моделью, затем сравнить OpenCode и Qwen Code на нескольких одинаковых задачах. Записывать стоимость, число исправлений и время до принятого результата; после этого решать, какую существующую подписку можно сократить.

#### Evidence

- [AI inference] Сравнение стоимости завершённой задачи полезнее сравнения только цены за токен: качество, повторы и расход контекста различаются.
- [Open assumption] Текущие подписки, реальные расходы и распределение задач пользователя неизвестны, поэтому конкретную подписку для отмены определить нельзя.

### Границы исследования {#n22}

- tags: метод

Это приоритетный обзор проверенных вариантов, а не исчерпывающий каталог всех существующих агентов. Цены и лимиты могут измениться; реальные установки, платёжные аккаунты и работу новых конфигураций в MarkView я не проверял.

#### Evidence

- [AI inference] Экосистема агентов и поставщиков меняется, поэтому список нельзя считать полным и бессрочным.

### Поисковые запросы {#n23}

- tags: поиск

Все отправленные запросы: `open source coding agents CLI deepseek API aider cline roo code pricing`; `Gemini CLI Qwen Code OpenCode coding agent pricing free official`; `DeepSeek API pricing coding agent official`; `GitHub Copilot Claude Code Codex alternatives coding agents pricing 2026`; `site:api-docs.deepseek.com quick start models pricing api`; `site:docs.cline.bot deepseek provider cline`; `site:opencode.ai docs providers pricing open source CLI`; `site:developers.google.com gemini cli pricing free`; `site:qwenlm.github.io qwen code free tier pricing`; `site:aider.chat docs deepseek aider`; `site:docs.all-hands.dev openhands cli agent pricing`; `site:block.github.io goose docs deepseek provider`; `site:docs.cline.bot deepseek provider setup`; `site:opencode.ai docs deepseek provider open source`; `site:docs.all-hands.dev openhands cli local llm agent`; `site:cursor.com pricing agent plans`; `site:docs.roocode.com providers deepseek roo code`; `site:docs.kilocode.ai deepseek provider cli`; `site:docs.continue.dev cli open source agent models`; `site:docs.z.ai coding plan pricing GLM coding agent`; `site:docs.openhands.dev CLI OpenHands software agent`; `site:block.github.io goose open source agent documentation`; `site:docs.cline.bot cline free models`; `site:api-docs.deepseek.com integrations codex agent`.
