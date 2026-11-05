---
type: research-map
id: 2026-11-05-issues-management
title: Строгое управление жизненным циклом issues
question: Я хочу систематизировать процесс, как мы управляем нашими issues, то есть features, bugs и так далее. Мне нужно, чтобы состояние этих features менялось. Либо человек может менять состояние, либо AI может провести это изменение. Как оно проводит это изменение? У нас есть MCP сервер, который имеет функциональность практически полностью MarkView. По крайней мере управление issues должно выставляться через MarkView MCP. И AI должна всегда знать, когда мы открываем консоль или что-то делаем, а AI должна понимать, что такое issues, что их можно создавать, менять, как менять, менять статус, при каких условиях меняется статус. Это принципиально важно. Мне нужен весь флоу, как меняется статус, когда закрыть это issue, когда открыть это issue, когда поменять на имплементинг. Все это должно проходить автоматически. Я должен менять этот статус в зависимости от состояния, в котором мы находимся на данный момент, если мы работаем с issues. Я хочу, чтобы ты исследовал мне, как можно построить такую систему, строгую, с тем, чтобы менялось состояние в зависимости от текущей реальности.
created: 2026-11-05
status: complete
---

# Строгое управление жизненным циклом issues

## Question

Я хочу систематизировать процесс, как мы управляем нашими issues, то есть features, bugs и так далее. Мне нужно, чтобы состояние этих features менялось. Либо человек может менять состояние, либо AI может провести это изменение. Как оно проводит это изменение? У нас есть MCP сервер, который имеет функциональность практически полностью MarkView. По крайней мере управление issues должно выставляться через MarkView MCP. И AI должна всегда знать, когда мы открываем консоль или что-то делаем, а AI должна понимать, что такое issues, что их можно создавать, менять, как менять, менять статус, при каких условиях меняется статус. Это принципиально важно. Мне нужен весь флоу, как меняется статус, когда закрыть это issue, когда открыть это issue, когда поменять на имплементинг. Все это должно проходить автоматически. Я должен менять этот статус в зависимости от состояния, в котором мы находимся на данный момент, если мы работаем с issues. Я хочу, чтобы ты исследовал мне, как можно построить такую систему, строгую, с тем, чтобы менялось состояние в зависимости от текущей реальности.

## Map

- [Строгое управление жизненным циклом issues](#n1)
  - [Текущее устройство](#n2)
    - [Данные и состояния](#n7)
      - [Статусы feature](#n39)
        - [idea](#n40)
        - [exploring](#n41)
        - [draft](#n42)
        - [review](#n43)
        - [resolving](#n44)
        - [ready](#n45)
        - [implementing](#n46)
        - [implemented](#n47)
        - [verified](#n48)
        - [archived](#n49)
      - [Статусы bug](#n50)
        - [open](#n51)
        - [fixing](#n52)
        - [fixed](#n53)
        - [closed](#n54)
      - [Дополнительные значения в Issues](#n55)
        - [done](#n56)
        - [rejected и cancelled](#n57)
        - [in-progress](#n58)
        - [Неизвестный или отсутствующий статус](#n59)
    - [Доступные операции MCP](#n8)
      - [Чтение features](#n60)
      - [Чтение bugs](#n61)
      - [Создание записей](#n62)
      - [Добавление объектов feature](#n63)
      - [Исправление записей](#n64)
      - [Операции изменения статуса](#n65)
      - [Вопросы и ответы](#n66)
      - [Источники и заметки feature](#n67)
      - [Связи с GitHub issues](#n68)
      - [Справка, проект и прототипы](#n69)
      - [Операции обсуждений](#n70)
      - [Операции Deployments](#n71)
    - [Что уже запускает переходы](#n9)
      - [Успешное исследование feature](#n72)
      - [Завершение Explore и AI Review](#n73)
      - [Быстрый приём feature](#n74)
      - [Создание GitHub issues](#n75)
      - [Передача feature агенту](#n76)
      - [Передача bug на исправление](#n77)
      - [Проверка актуальности bug](#n78)
      - [Шаг готовности в MCP](#n79)
      - [Отслеживание изменений UI Studio](#n80)
      - [Перезапуск feature](#n81)
      - [Передача спецификации и прототипа](#n82)
      - [Исправления и отмена в UI Studio](#n83)
    - [Синхронизация с GitHub](#n10)
    - [Разрыв между журналом и статусом](#n11)
  - [Модель переходов](#n3)
    - [Создание и подготовка](#n12)
    - [Начало реальной работы](#n13)
    - [Завершение и закрытие](#n14)
    - [Повторное открытие и блокировка](#n15)
  - [Автоматизация и MCP](#n4)
    - [Единый механизм переходов](#n16)
      - [Команда перехода](#n84)
      - [Движок правил](#n85)
        - [Контракт вычисления](#n92)
        - [Выбор и приоритет правила](#n93)
        - [Предикаты и готовность](#n94)
          - [Точная семантика условий](#n100)
        - [Полномочия и подтверждения](#n95)
        - [Неизвестные и отсутствующие данные](#n96)
        - [План сопутствующих действий](#n97)
          - [Граница исполнения плана](#n101)
        - [Структура ответа движка](#n98)
        - [Версия и совместимость правил](#n99)
        - [Проверка самого движка](#n102)
      - [Адаптеры источников](#n86)
      - [Чтение и идентификация](#n87)
      - [Хранилище и конкурентная запись](#n88)
      - [Результат команды](#n89)
      - [Учёт команд и восстановление](#n90)
      - [Контроль внешних правок](#n91)
    - [События и свидетельства](#n17)
    - [Сверка и надёжность](#n18)
    - [Связь с GitHub issues](#n19)
  - [Осведомлённость AI](#n5)
    - [Контекст при запуске сессии](#n20)
    - [Привязка работы к issue](#n21)
    - [Обязанности агента](#n22)
    - [Видимость и ограничения](#n23)
  - [Внедрение и проверка](#n6)
    - [Согласовать правила переходов](#n24)
    - [Внедрять по этапам](#n25)
      - [Зафиксировать исходное поведение](#n28)
      - [Ввести наблюдение за предложениями](#n29)
      - [Вынести переходы в сервис](#n30)
        - [Граница сервиса](#n103)
        - [Результат для вызывающего кода](#n104)
        - [Исполнитель и сохранение](#n105)
          - [Конкурентная запись](#n106)
        - [Порядок исполнения](#n107)
          - [Фактический и вычисленный статус](#n108)
        - [Подтверждение журнала](#n109)
        - [Потоки и обновление UI](#n110)
        - [Проверка контракта сервиса](#n111)
      - [Подключить все точки записи](#n31)
        - [Меню и действия Issues](#n112)
        - [Команды MCP для статуса](#n113)
        - [Создание feature и bug](#n114)
        - [Explore, Review и готовность](#n115)
        - [Передача работы агенту](#n116)
        - [Прямая запись bug intake](#n117)
        - [Передача спецификации и прототипа](#n118)
        - [Записи UI Studio](#n119)
        - [Проверка актуальности bug](#n120)
        - [Перезапуск feature](#n121)
        - [Неявное принятие старых записей](#n122)
      - [Подключить источники событий](#n32)
      - [Добавить фоновую сверку](#n33)
      - [Поэтапно включить GitHub изменения](#n34)
        - [Отключение и восстановление](#n35)
      - [Установить условия перехода этапов](#n36)
        - [Проверки перед расширением](#n37)
      - [Разбить поставку на PR](#n38)
    - [Проверить критические сценарии](#n26)
    - [Контроль качества и исследования](#n27)

## Nodes

### Строгое управление жизненным циклом issues {#n1}

- tags: issues, MCP, workflow

Единый процесс должен связывать фактические события работы, проверяемые условия переходов и изменение issues через MarkView MCP, сохраняя возможность действий человека и AI.

#### Evidence

- [AI inference] Строгость требует единого источника состояния, явных переходов и проверяемых свидетельств.

### Текущее устройство {#n2}

- tags: репозиторий

Выяснить, как проект хранит issues и какие состояния и операции уже существуют.

#### Evidence

- [AI inference] Рекомендации следует строить на существующих моделях и операциях проекта.

### Данные и состояния {#n7}

- tags: Markdown, статусы

Features и bugs хранятся в Markdown и имеют разные словари статусов. Статус в списке Issues — представление этих данных, а не отдельная универсальная машина состояний.

#### Evidence

- [Project fact] Feature создаётся в docs/features/<slug>/overview.md, bug — в docs/bugs/BUG-nnn-….md. — `MarkView/Models/ProjectAgentTools.swift:61`
- [Project fact] Словарь feature: idea, exploring, draft, review, resolving, ready, implementing, implemented, verified, archived; bug: open, fixing, fixed, closed. — `MarkView/Models/FeatureVocabulary.swift:5`
- [Project fact] Для фильтра Issues feature считается закрытой при implemented, verified, done, archived, rejected или cancelled; bug — при closed или fixed. — `MarkView/Models/IssueListing.swift:34`

### Статусы feature {#n39}

- tags: feature

У feature десять основных статусов в словаре приложения. Названия отражают этапы работы, но сами по себе не доказывают выполнения обязательных проверок.

#### Evidence

- [Project fact] Словарь feature содержит десять значений; статусы сохраняются в нижнем регистре в front matter. — `MarkView/Models/FeatureVocabulary.swift:3`
- [AI inference] Название статуса само по себе не является свидетельством выполнения проверок.

### idea {#n40}

- tags: feature

Начальная идея feature: описание идеи ещё может отсутствовать. При создании с пустым текстом идеи приложение выбирает этот статус.

#### Evidence

- [Project fact] createFeature записывает idea, если текст идеи пуст; иначе — exploring. — `MarkView/Models/FeatureStore.swift:239`

### exploring {#n41}

- tags: feature

Идёт изучение идеи и уточнение требований. Руководство агента рекомендует сохранять этот статус, пока требования не полны.

#### Evidence

- [Project fact] Руководство предлагает оставлять exploring до завершения требований; приложение Explore задаёт вопросы о неизвестных аспектах. — `MarkView/Models/ProjectAgentTools.swift:210`

### draft {#n42}

- tags: feature

Черновик feature: требования собраны для дальнейшего рассмотрения. При включении существующих документов в структуру feature приложение также устанавливает draft.

#### Evidence

- [Project fact] Руководство рекомендует draft, когда требования полны. — `MarkView/Models/ProjectAgentTools.swift:215`
- [Project fact] adoptedOverview записывает draft для существующих документов feature. — `MarkView/Models/FeatureStore.swift:573`

### review {#n43}

- tags: feature

Спецификация находится на рассмотрении. При завершении Explore приложение утверждает ожидающие требования и переводит feature на review, если она ещё не прошла этот этап.

#### Evidence

- [Project fact] finishExplore утверждает требования и при условии !isPastExplore устанавливает review. — `MarkView/Models/FeatureStore.swift:481`
- [AI inference] Название review обозначает рассмотрение спецификации.

### resolving {#n44}

- tags: feature

Этап разрешения замечаний или вопросов после рассмотрения. Точный набор обязательных условий этого статуса в приведённом словаре не определён.

#### Evidence

- [Project fact] resolving находится между review и ready в описанном порядке состояний feature. — `MarkView/Models/ProjectAgentTools.swift:190`
- [AI inference] Название resolving предполагает разрешение замечаний или вопросов; само имя не задаёт конкретных критериев.

### ready {#n45}

- tags: feature

Спецификация обозначена как готовая к реализации. Наблюдатель жизненного цикла связывает переход в ready с событием готовности спецификации, но записывает такое событие и при других условиях.

#### Evidence

- [Project fact] Переход в ready или достижение readiness 100 % записывает событие spec ready; передача в реализацию тоже может его записать. — `MarkView/Models/FeatureStore.swift:672`

### implementing {#n46}

- tags: feature

Feature передана в реализацию. Сам статус не доказывает, что изменение кода уже началось: приложение может установить его при передаче работы.

#### Evidence

- [Project fact] markImplementing переводит разрешённые предшествующие статусы в implementing при передаче feature в реализацию. — `MarkView/Models/FeatureStore.swift:703`
- [AI inference] Передача работы не доказывает фактического изменения кода.

### implemented {#n47}

- tags: feature

Реализация отмечена завершённой. Наблюдатель записывает событие окончания реализации при переходе в этот статус; список Issues относит его к закрытым.

#### Evidence

- [Project fact] Переход в implemented порождает событие implementation finished. — `MarkView/Models/FeatureStore.swift:692`
- [Project fact] implemented входит в implementedFeature и closedFeature списка Issues. — `MarkView/Models/IssueListing.swift:34`

### verified {#n48}

- tags: feature

Feature отмечена проверенной после реализации. В списке Issues она считается закрытой; конкретный объём проверки из названия статуса не следует.

#### Evidence

- [Project fact] Руководство помещает verified после implemented, а список Issues включает его в закрытые состояния. — `MarkView/Models/ProjectAgentTools.swift:190`
- [Project fact] verified входит в implementedFeature и closedFeature. — `MarkView/Models/IssueListing.swift:34`
- [AI inference] Само значение verified не раскрывает, какие именно проверки выполнены.

### archived {#n49}

- tags: feature

Feature помещена в архив; список Issues считает её закрытой. Архивация не означает, что реализация обязательно завершена.

#### Evidence

- [Project fact] archived входит в словарь feature и в закрытые состояния списка Issues. — `MarkView/Models/IssueListing.swift:36`
- [Project fact] Инструменты не удаляют feature, но допускают её архивацию. — `MarkView/Models/ProjectAgentTools.swift:200`
- [AI inference] Сам факт архивации не подтверждает реализацию.

### Статусы bug {#n50}

- tags: bug

У bug четыре основных статуса в словаре приложения. Они хранятся в front matter отчёта и используются списком Issues.

#### Evidence

- [Project fact] Словарь bug содержит open, fixing, fixed и closed; статусы сохраняются в нижнем регистре в front matter. — `MarkView/Models/FeatureVocabulary.swift:3`

### open {#n51}

- tags: bug

Bug открыт и ещё не отмечен как исправленный или закрытый. Это значение по умолчанию для нового отчёта; отчёт без статуса также читается как open.

#### Evidence

- [Project fact] BugReportDraft создаётся со статусом open. — `MarkView/Models/BugReportWriter.swift:4`
- [Project fact] При чтении bug пустой статус заменяется на open. — `MarkView/Models/FeatureModels.swift:607`

### fixing {#n52}

- tags: bug

Исправление bug находится в работе. Например, при запуске исправления через корзину приложение отмечает выбранные отчёты этим статусом.

#### Evidence

- [Project fact] BugBasket устанавливает fixing для выбранных отчётов. — `MarkView/Models/BugBasket.swift:88`
- [Project fact] Список Issues относит fixing к состояниям работы в процессе. — `MarkView/Models/IssueListing.swift:38`

### fixed {#n53}

- tags: bug

Bug отмечен как исправленный; список Issues считает его закрытым. Инструкция для исправления через корзину предписывает ставить fixed после появления коммита исправления.

#### Evidence

- [Project fact] fixed входит в множество закрытых статусов bug в Issues. — `MarkView/Models/IssueListing.swift:37`
- [Project fact] Инструкция BugBasket требует обновить статус на fixed только после появления коммита исправления. — `MarkView/Models/BugBasket.swift:158`

### closed {#n54}

- tags: bug

Отчёт о bug закрыт. Это может означать не исправление, а, например, закрытие дубликата или отклонённого после проверки отчёта.

#### Evidence

- [Project fact] Руководство предписывает закрывать дубликат с заполненным duplicate_of. — `MarkView/Models/ProjectAgentTools.swift:240`
- [Project fact] BugValidity закрывает отчёт и добавляет причину в обсуждение. — `MarkView/Models/BugValidity.swift:335`

### Дополнительные значения в Issues {#n55}

- tags: issues, совместимость

Фильтр Issues распознаёт некоторые дополнительные значения вне основных словарей feature и bug. Это правила представления списка, а не дополнительные официальные статусы этих словарей.

#### Evidence

- [Project fact] IssueStatus отдельно определяет значения для закрытых и находящихся в работе записей. — `MarkView/Models/IssueListing.swift:25`
- [Project fact] Основные словари feature и bug перечислены отдельно. — `MarkView/Models/FeatureVocabulary.swift:5`

### done {#n56}

- tags: feature, issues

Для feature список Issues принимает done как обозначение выполненной и закрытой записи, в том числе записанной вручную. В основном словаре feature этого значения нет.

#### Evidence

- [Project fact] done допускается для записанных вручную feature и входит в implementedFeature. — `MarkView/Models/IssueListing.swift:33`
- [Project fact] done отсутствует в featureStatuses. — `MarkView/Models/FeatureVocabulary.swift:5`

### rejected и cancelled {#n57}

- tags: feature, issues

Для feature значения rejected, cancelled и вариант написания canceled считаются закрытыми в списке Issues. Они не входят в основной словарь статусов feature.

#### Evidence

- [Project fact] closedFeature включает rejected, cancelled и canceled. — `MarkView/Models/IssueListing.swift:35`
- [Project fact] Эти значения отсутствуют в featureStatuses. — `MarkView/Models/FeatureVocabulary.swift:5`

### in-progress {#n58}

- tags: issues

Список Issues распознаёт in-progress как признак работы в процессе. Пробелы и подчёркивания в статусе нормализуются в дефисы, поэтому соответствующие варианты написания обрабатываются одинаково.

#### Evidence

- [Project fact] IssueStatus нормализует регистр, пробелы и подчёркивания; in-progress включён в inProgress. — `MarkView/Models/IssueListing.swift:27`

### Неизвестный или отсутствующий статус {#n59}

- tags: issues

Для фильтра Issues любой статус вне соответствующего множества закрытых считается открытым, включая неизвестный или отсутствующий. Это поведение фильтра само по себе не исправляет значение в файле.

#### Evidence

- [Project fact] isClosed возвращает принадлежность нормализованного статуса множеству закрытых; комментарий относит отсутствующий и неизвестный статус к открытым. — `MarkView/Models/IssueListing.swift:41`
- [AI inference] Проверка принадлежности при отображении не является исправлением статуса в файле.

### Доступные операции MCP {#n8}

- tags: MCP
- position: 857, -388

Проектный MCP умеет читать и создавать features и bugs, менять их данные и статус, связывать с GitHub issues. У feature агент не может напрямую выставить implementing и последующие стадии.

#### Evidence

- [Project fact] Объявлены markview_list_features, markview_get_feature, markview_list_bugs, markview_get_bug, markview_create_feature, markview_create_bug, markview_set_status, markview_set_bug_status и markview_link_issue. — `MarkView/Models/ProjectAgentTools.swift:43`
- [Project fact] Агенту доступны статусы feature до ready и archived; стадии реализации исключены из markview_set_status. — `MarkView/Models/ProjectAgentTools.swift:389`
- [Project fact] markview_link_issue сохраняет связь, но не создаёт issue на GitHub. — `MarkView/Models/ProjectAgentTools.swift:131`

### Чтение features {#n60}

- tags: чтение, feature
- position: 896, -804

`markview_list_features` возвращает перечень с необязательным фильтром по статусу. `markview_get_feature` читает feature, отдельный объект или выбранный раздел; `full` включает текст всех объектов.

#### Evidence

- [Project fact] Описаны фильтр status, параметры id, full и section и состав возвращаемых сведений. — `MarkView/Models/ProjectAgentTools.swift:47`

### Чтение bugs {#n61}

- tags: чтение, bug
- position: 706, -756

`markview_list_bugs` перечисляет bugs с необязательным фильтром статуса; `markview_get_bug` по id возвращает полный отчёт.

#### Evidence

- [Project fact] Перечень включает severity, связи, duplicate_of, ready_to_fix и открытые вопросы расследования; get возвращает полный отчёт. — `MarkView/Models/ProjectAgentTools.swift:53`

### Создание записей {#n62}

- tags: создание
- position: 1096, -787

`markview_create_feature` создаёт feature по title и возвращает slug; `markview_create_bug` создаёт отчёт по title и summary. Дополнительные поля уточняют исходную идею или сведения о дефекте.

#### Evidence

- [Project fact] Схемы создания определяют обязательные и необязательные поля feature и bug. — `MarkView/Models/ProjectAgentTools.swift:61`
- [Project fact] Для bug обязательны title и summary; доступны severity, steps, expected, actual и environment. — `MarkView/Models/ProjectAgentTools.swift:86`

### Добавление объектов feature {#n63}

- tags: feature, создание
- position: 1222, -717

`markview_add_requirement`, `markview_add_decision` и `markview_add_question` добавляют требования, решения и вопросы. Для требования указываются проверяемое поведение и критерии приёмки; для вопроса доступны варианты и признак блокировки.

#### Evidence

- [Project fact] Схемы инструментов определяют поля требований, решений и вопросов. — `MarkView/Models/ProjectAgentTools.swift:67`

### Исправление записей {#n64}

- tags: редактирование
- position: 1246, -632

`markview_update_feature` меняет название, идею и понимание; `markview_update_object` исправляет объект feature, его разделы и связи. `markview_update_bug` меняет поля и разделы отчёта, включая `ready_to_fix`; статусы меняются отдельными операциями.

#### Evidence

- [Project fact] Операции обновления feature и её объектов принимают указанные поля; разделы объекта заменяются целиком. — `MarkView/Models/ProjectAgentTools.swift:97`
- [Project fact] Обновление bug поддерживает поля и разделы отчёта, но статус меняется через отдельный инструмент. — `MarkView/Models/ProjectAgentTools.swift:120`

### Операции изменения статуса {#n65}

- tags: статус
- position: 1221, -537

`markview_set_status` меняет статус feature или объекта по `id`; для `approved`, `accepted` и `rejected` требуется `by_user: true`. `markview_set_bug_status` меняет статус bug и может закрыть дубликат с `duplicate_of`.

#### Evidence

- [Project fact] Объявления описывают проверку статусов объектов, признак решения пользователя и закрытие дубликата. — `MarkView/Models/ProjectAgentTools.swift:90`

### Вопросы и ответы {#n66}

- tags: вопросы
- position: 1156, -451

`markview_open_questions` показывает открытые вопросы всех features или одной feature. `markview_answer_question` и `markview_answer_bug_question` записывают ответ человека; второй инструмент также поддерживает пропуск вопроса.

#### Evidence

- [Project fact] Ответ на вопрос feature записывается только с by_user: true, когда его дал человек. — `MarkView/Models/ProjectAgentTools.swift:110`
- [Project fact] Ответ или пропуск вопроса bug требует by_user; открытые вопросы features доступны отдельным инструментом. — `MarkView/Models/ProjectAgentTools.swift:127`

### Источники и заметки feature {#n67}

- tags: feature, контекст
- position: 1176, -368

`markview_add_source` добавляет к feature источник с происхождением и содержимым. `markview_add_discussion_note` дописывает реплику в журнал обсуждения feature.

#### Evidence

- [Project fact] Объявлены инструменты добавления источника и реплики в discussion.md. — `MarkView/Models/ProjectAgentTools.swift:114`

### Связи с GitHub issues {#n68}

- tags: github, связи
- position: 1144, -303

`markview_link_issue` принимает slug feature или id bug и массив номеров issues. Параметр `remove` удаляет связи; создание GitHub issue инструмент не выполняет.

#### Evidence

- [Project fact] Схема инструмента определяет target, issues и remove и прямо указывает, что на GitHub ничего не создаётся. — `MarkView/Models/ProjectAgentTools.swift:131`

### Справка, проект и прототипы {#n69}

- tags: чтение, контекст
- position: 1115, -255

`markview_guide` выдаёт справку по выбранной теме, `markview_project` — сведения об открытом проекте. `markview_list_prototypes` и `markview_get_prototype` читают список и содержимое прототипов.

#### Evidence

- [Project fact] Объявлены справка, сведения о проекте и операции чтения прототипов, в том числе отдельного файла прототипа. — `MarkView/Models/ProjectAgentTools.swift:43`

### Операции обсуждений {#n70}

- tags: обсуждения
- position: 879, -253

`markview_discussions` и `markview_get_discussion` читают обсуждения; `markview_create_discussion` создаёт обсуждение. `markview_discussion_item` добавляет, меняет, перемещает или удаляет решения, вопросы и отклонённые варианты.

#### Evidence

- [Project fact] Сервер markview включает четыре инструмента обсуждений и перечисленные действия над элементами. — `MarkView/Models/DiscussionAgentTools.swift:14`
- [Project fact] Инструменты обсуждений добавляются к списку инструментов проекта. — `MarkView/Models/ProjectAgentTools.swift:137`

### Операции Deployments {#n71}

- tags: deployments
- position: 650, -253

Сервер также объявляет `markview_deployments`, `markview_deployments_propose`, `markview_deployments_status`, `markview_deployments_run`, `markview_deployments_logs` и `markview_deployments_db`. Они показывают окружения и их состояние, предлагают окружение, запускают команды и читают логи или базу; действия, меняющие данные, требуют согласия человека в приложении.

#### Evidence

- [Project fact] Перечислены шесть инструментов Deployments и условия выполнения команд и запросов к базе. — `MarkView/Models/DeploymentAgentTools.swift:20`
- [Project fact] Инструменты Deployments добавляются к списку инструментов проекта. — `MarkView/Models/ProjectAgentTools.swift:137`

### Что уже запускает переходы {#n9}

- tags: implementation
- position: 450, -1235

Передача feature в реализацию уже может выставлять implementing; для bugs предусмотрен отдельный ручной или агентный переход. Существующие инструкции о полном автоматическом отслеживании требуют проверки по коду.

#### Evidence

- [Project fact] FeatureStore.markImplementing меняет подходящий предыдущий статус на implementing. — `MarkView/Models/FeatureStore.swift:703`
- [Project fact] Инструкции агенту утверждают, что MarkView записывает implementing, implemented и verified по git и GitHub. — `MarkView/Models/ProjectAgentTools.swift:288`

### Успешное исследование feature {#n72}

- tags: feature, AI

После успешного AI-исследования feature со статусом `idea` переводится в `exploring`.

#### Evidence

- [Project fact] После получения структурированного результата и применения discovery код меняет `idea` на `exploring`. — `MarkView/Models/FeatureAI.swift:528`

### Завершение Explore и AI Review {#n73}

- tags: feature, review

Выход из Explore утверждает ожидающие требования и переводит feature в `review`, если она ещё не прошла Explore. AI Review тоже переводит в `review` feature в состояниях `idea`, `exploring` или `draft`.

#### Evidence

- [Project fact] `finishExplore` утверждает требования и условно записывает `review`. — `MarkView/Models/FeatureStore.swift:489`
- [Project fact] После AI Review код устанавливает `review` для трёх ранних статусов. — `MarkView/Models/FeatureAI.swift:1132`

### Быстрый приём feature {#n74}

- tags: feature, intake

Успешное создание спецификации через quick feature intake устанавливает `ready` и обнуляет число оставшихся вопросов.

#### Evidence

- [Project fact] После получения структурированного ответа и создания feature quick intake записывает `status: ready` и `questions_left: 0`. — `MarkView/Models/FeatureIntake.swift:80`

### Создание GitHub issues {#n75}

- tags: feature, GitHub

После создания issues и сохранения плана вызывается `markImplementing`; при ошибке код сохраняет план и сообщает об ошибке без этого вызова.

#### Evidence

- [Project fact] Успешная ветка создания issues вызывает `markImplementing` после сохранения плана; обработчик ошибки этого не делает. — `MarkView/Models/FeatureAI.swift:1793`

### Передача feature агенту {#n76}

- tags: feature, агент

После успешной отправки задачи ассистенту приложение ищет связанную feature и вызывает `markImplementing`; подходящий предыдущий статус меняется на `implementing`.

#### Evidence

- [Project fact] `startImplementation` сначала отправляет задачу, затем определяет feature и вызывает `markImplementing`. — `MarkView/Models/WorkspaceManager.swift:4490`
- [Project fact] `markImplementing` проверяет предыдущий статус перед записью `implementing`. — `MarkView/Models/FeatureStore.swift:703`

### Передача bug на исправление {#n77}

- tags: bug, агент

При Fix with AI запись `fixing` выполняется перед отправкой задачи. Для пакетного исправления при неудачной отправке или слишком малом числе отмеченных bugs приложение пытается восстановить исходные статусы; восстановление тоже может не удаться.

#### Evidence

- [Project fact] `fixBugWithAI` записывает `fixing` до вызова `sendToAssistant`. — `MarkView/Models/WorkspaceManager.swift:4519`
- [Project fact] `BatchStart` отмечает bugs как `fixing` и при неудачном старте пытается вернуть прежние статусы, сообщая о невосстановленных записях. — `MarkView/Models/BugBasket.swift:68`

### Проверка актуальности bug {#n78}

- tags: bug, проверка

При сохранении результата проверки с выводом `alreadyFixed` bug закрывается: устанавливается `closed`, очищается `ready_to_fix` и добавляется объяснение в обсуждение.

#### Evidence

- [Project fact] `BugValidity.record` при `alreadyFixed` устанавливает `closed`, очищает `ready_to_fix` и добавляет запись с объяснением и ссылками на свидетельства. — `MarkView/Models/BugValidity.swift:334`

### Шаг готовности в MCP {#n79}

- tags: feature, MCP

Команда flow `ready` выставляет feature статус `ready`, когда Explore пройден, открытых вопросов и findings нет, а активные требования существуют.

#### Evidence

- [Project fact] Ветка `.ready` проверяет прохождение Explore, отсутствие открытых вопросов и findings и наличие активных требований перед записью статуса. — `MarkView/Models/ControlToolRunner+Flow.swift:337`

### Отслеживание изменений UI Studio {#n80}

- tags: feature, UI Studio

UI Studio записывает `implementing` при создании feature для первого отслеживаемого изменения и при экспорте пакета как feature.

#### Evidence

- [Project fact] `trackingFeature` создаёт feature при первом отслеживаемом изменении и устанавливает `implementing`. — `MarkView/Models/UIStudioSession+Tracking.swift:81`
- [Project fact] `StudioFeatureWriter.write` создаёт feature из пакета и записывает `implementing`. — `MarkView/Models/UIStudioSession.swift:3035`

### Перезапуск feature {#n81}

- tags: feature, сброс

Restart возвращает структурированную feature, ещё не дошедшую до реализации, в `idea` и очищает данные понимания; производные материалы отправляются в корзину.

#### Evidence

- [Project fact] `restartFeature` допускает структурированные feature до реализации, удаляет производные материалы через корзину и записывает `idea`. — `MarkView/Models/FeatureStore.swift:440`

### Передача спецификации и прототипа {#n82}

- tags: feature, ready

При `markReady` ранний или отсутствующий статус feature переводится в `ready`. Передача прототипа в код создаёт новую feature со статусом `ready`.

#### Evidence

- [Project fact] `SpecificationHandoff.markReady` устанавливает `ready` для перечисленных ранних и пустого статусов. — `MarkView/Models/SpecificationHandoff.swift:82`
- [Project fact] `PrototypeFeatureWriter.write` создаёт feature и записывает `ready`. — `MarkView/Models/PrototypeFeatureWriter.swift:25`

### Исправления и отмена в UI Studio {#n83}

- tags: bug, UI Studio

Проверенное применённое изменение, классифицированное как исправление, записывается новым bug со статусом `fixed`. При отмене изменения или переносе его учёта из bug в требование существующий bug закрывается.

#### Evidence

- [Project fact] `trackChange` записывает применённое исправление как bug после проверки изменения. — `MarkView/Models/UIStudioSession+Tracking.swift:15`
- [Project fact] Черновик bug для исправления UI Studio создаётся со статусом `fixed`. — `MarkView/Models/UIStudioTracking.swift:210`
- [Project fact] `trackUndo` и `switchTracking` отмечают соответствующий bug как `closed`. — `MarkView/Models/UIStudioSession+Tracking.swift:41`

### Синхронизация с GitHub {#n10}

- tags: GitHub, sync
- position: 30, -754

Существующий Sync запускается вручную и направлен из локальных документов в GitHub; он не открывает закрытые issues повторно. Автоматическое двустороннее соответствие пока не обеспечено.

#### Evidence

- [Project fact] Решение ограничивает Sync ручным запуском, исключает фоновую синхронизацию, reopening и чтение состояния GitHub обратно в документы. — `docs/features/sync-github-issues-with-feature-bug-status-from/decisions/DEC-006.md:27`
- [Project fact] Закрытый GitHub issue не открывается повторно; открытый закрывается только если среди связанных записей нет незавершённых. — `MarkView/Models/IssueSync.swift:251`

### Разрыв между журналом и статусом {#n11}

- tags: пробел, события
- position: 383, -394

Проверенный путь GitHub записывает события жизненного цикла, но сам по себе не меняет Markdown-статус feature. Поэтому инструкция агенту об автоматической записи implemented и verified шире подтверждённого поведения этого пути.

#### Evidence

- [Project fact] syncLifecycle вызывает recordCapture для событий GitHub; recordCapture добавляет запись в LifecycleLog. — `MarkView/Models/FeatureStore.swift:751`
- [Project fact] Открытие PR сопоставляется событию implementationFinished, а merge в default branch — событию mergedToMain. — `MarkView/Models/LifecycleCapture.swift:113`
- [Project fact] Кнопка в отчёте Sync отдельно и явно записывает feature status implemented или bug status fixed. — `MarkView/Views/IssueSyncViews.swift:176`
- [AI inference] Запись события implementationFinished нельзя считать доказательством изменения feature status; открытие PR также не доказывает завершение и проверку работы.

### Модель переходов {#n3}

- tags: состояния
- position: -129, -300

Определить состояния, события и условия, при которых разрешены переходы.

#### Evidence

- [AI inference] Описанные условия переходов делают жизненный цикл проверяемым.

### Создание и подготовка {#n12}

- tags: открытие
- number: 1

Создавать issue при подтверждённом запросе на отдельную работу; feature вести от idea/exploring через draft и review к ready, bug начинать с open. При неоднозначности сначала искать существующую запись и связывать дубликаты.

#### Evidence

- [Project fact] При создании feature статус по умолчанию зависит от наличия текста идеи; инструмент создания bug пишет отдельный отчёт. — `MarkView/Models/ProjectAgentTools.swift:61`
- [AI inference] Поиск существующих записей до создания уменьшает дубликаты и позволяет продолжать работу в существующем контексте.

### Начало реальной работы {#n13}

- tags: implementing, fixing
- number: 2

Переводить feature в implementing, а bug в fixing при успешном подтверждённом начале реализации: назначена конкретная работа и она действительно передана исполнителю. Открытие терминала, создание ветки или issue сами по себе не доказывают начало работы.

#### Evidence

- [Project fact] startImplementation сначала отправляет цель агенту, а затем вызывает markImplementing и записывает начало жизненного цикла. — `MarkView/Models/WorkspaceManager.swift:4490`
- [Project fact] fixBugWithAI выставляет fixing до отправки промпта, поэтому порядок отличается от feature. — `MarkView/Models/WorkspaceManager.swift:4520`
- [AI inference] Для строгого перехода нужен единый подтверждаемый сигнал начала; при неудачной отправке статус не должен ошибочно остаться активным.

### Завершение и закрытие {#n14}

- tags: завершение, проверка
- number: 3

Предлагаемое правило: после merge в целевую ветку и успешных обязательных проверок фиксировать implemented или fixed; verified — после проверки критериев приёмки на указанной ревизии. Закрывать связанный GitHub issue только когда завершены все связанные работы; отмену и дубликат фиксировать отдельной причиной.

#### Evidence

- [Project fact] По правилам репозитория app feature или bug проходит PR, проверки и merge; завершение app-изменений включает Release и DMG с merged commit. — `CLAUDE.md:45`
- [Project fact] Текущий Sync считает archived достаточным для закрытия GitHub issue как completed. — `MarkView/Models/IssueSync.swift:23`
- [AI inference] Отмена или архивирование не доказывают реализацию; причину закрытия следует отличать от completed. Для этого потребуется изменить существующее правило Sync.
- [Open assumption] Нужно согласовать, входят ли Release, подписанный DMG и публикация в условия implemented или verified для этого проекта.

### Повторное открытие и блокировка {#n15}

- tags: регресс, blocked
- number: 4

При воспроизводимом регрессе на целевой ревизии возвращать bug в open; для feature определять повторное открытие либо новую связанную запись по масштабу изменения. Остановку, конфликт или нехватку данных отражать отдельно от стадии, не выдавая их за завершение.

#### Evidence

- [Project fact] Словари feature и bug не содержат отдельного статуса blocked; существующий Sync не выполняет reopening. — `MarkView/Models/FeatureVocabulary.swift:5`
- [AI inference] Отдельный признак блокировки сохраняет информацию о стадии работы; повторное открытие должно сопровождаться доказательством и причиной.
- [Open assumption] Политику выбора между reopen существующей записи и созданием новой при регрессе необходимо согласовать.

### Автоматизация и MCP {#n4}

- tags: MCP, автоматизация
- position: 295, -20

Связать наблюдаемые события и команды с обновлением issues через существующий интерфейс.

#### Evidence

- [AI inference] Для автоматизации необходимы доступные операции и надёжные источники событий.

### Единый механизм переходов {#n16}

- tags: архитектура, MCP
- position: 643, 86

Создать общий сервис переходов для features и bugs: UI, MCP и автоматические наблюдатели передают типизированное событие с идентификатором issue, ожидаемым прежним состоянием, инициатором и ссылками на свидетельства. Сервис применяет отдельные таблицы допустимых переходов и проверяет полномочия и условия; при отказе возвращает причину и недостающие условия. Правила и достаточность свидетельств нужно согласовать до автоматического применения.

Например, событие передачи feature в работу может предложить переход в `implementing`, а подтверждённое завершение исправления — переход bug в `fixed`; закрытие после проверки следует рассматривать отдельно. Успешный ответ MCP должен означать, что запись действительно сохранена. Повтор события должен быть безопасен, а несовпадение ожидаемого статуса с текущим — приводить к перечитыванию и повторной оценке, а не перезаписи чужого изменения.

Сервис должен записывать результат и основание перехода с возможностью восстановления после частичного сбоя. Прямые изменения Markdown обойти он не сможет: их следует обнаруживать при чтении и сверять, показывая конфликт или предлагая подтверждение, если доказательств недостаточно. Это сохраняет редактируемость файлов, но означает, что строгая проверка возможна только для операций через сервис; текущий локальный журнал нельзя считать общей транзакционной историей.

#### Evidence

- [Project fact] FeatureStore.updateFeature и updateBug предоставляют пути изменения данных, а отдельный UI записывает статусы напрямую через эти методы. — `MarkView/Models/FeatureStore.swift:518`
- [AI inference] Проверки только в подсказке AI или только в MCP обходятся другими путями записи; единая серверная проверка делает правила общими.
- [Project fact] MCP проверяет принадлежность целевого статуса допустимому набору; для некоторых решений по объектам требует by_user, а для bug-дубликата проверяет существование исходного bug и закрывает дубликат. — `MarkView/Models/ProjectToolRunner.swift:402`
- [Project fact] updateFeature возвращает Void: ошибка записи сохраняется в lastError, тогда как обработчик MCP после вызова сообщает об успешной смене статуса; updateBug возвращает признак успеха. — `MarkView/Models/FeatureStore.swift:519`
- [Project fact] Наблюдатель сравнивает последовательные снимки features, включая изменения через редактор, git и AI terminal, и записывает отдельные события жизненного цикла; новые или переименованные записи он пропускает. — `MarkView/Models/FeatureStore.swift:672`
- [Project fact] LifecycleLog хранит дополняемый JSON-lines журнал локально в Application Support; запись в файл выполняется асинхронно, а ошибка сохранения сообщается отдельно. — `MarkView/Models/LifecycleLog.swift:3`
- [AI inference] Единая проверка ожидаемого состояния, повторов и результатов сохранения уменьшит риск потерянных изменений и ложного подтверждения, но потребует согласованного способа обработки конкурентных записей и частичных сбоев.
- [Open assumption] Состав допустимых переходов, полномочия инициаторов и свидетельства, достаточные для автоматического перехода или закрытия, ещё необходимо согласовать.

### Команда перехода {#n84}

- tags: контракт
- position: 700, -34

Выделить типизированную команду с видом issue, идентификатором, событием, ожидаемым статусом, инициатором и ссылками на свидетельства. Все источники переходов передают её через общий интерфейс.

#### Evidence

- [AI inference] Единый контракт позволяет применять одинаковые правила к запросам UI, MCP и наблюдателей и отличать намерение изменить статус от произвольного редактирования полей.

### Движок правил {#n85}

- tags: правила
- position: 956, 139

Отдельный компонент сопоставляет событие и текущий статус с таблицей для соответствующего типа issue, затем проверяет полномочия и необходимые условия. Он возвращает решение без записи файла, чтобы причины отказа были доступны каждому вызывающему интерфейсу.

#### Evidence

- [Project fact] MCP проверяет допустимость целевого статуса feature и bug, а для некоторых статусов объектов требует признак решения пользователя. — `MarkView/Models/ProjectToolRunner.swift:402`
- [AI inference] Проверка принадлежности значения словарю не задаёт допустимость конкретного перехода из текущего состояния; для неё нужна отдельная таблица переходов.
- [Open assumption] Таблицы переходов, полномочия и достаточные условия ещё должны быть согласованы.
- [Project fact] Противоречие текущей реализации: проверки и запись совмещены в вызывающих операциях. Например, шаг ready проверяет условия и сразу вызывает updateFeature; отдельного возвращаемого решения без записи в этом пути нет. — `MarkView/Models/ControlToolRunner+Flow.swift:337`
- [Project fact] Условия для ready различаются между интерфейсами: шаг ready требует завершения Explore, отсутствия открытых вопросов и findings и наличия активных требований, тогда как markview_set_status записывает разрешённый статус feature непосредственно, без этих проверок. — `MarkView/Models/ProjectToolRunner.swift:424`
- [Project fact] Существующий расчёт готовности проверяет также утверждение требований, наличие критериев приёмки, принятие решений и, при наличии плана, покрытие требований. Шаг ready не проверяет все эти условия напрямую. — `MarkView/Models/FeatureModels.swift:455`
- [Project fact] isPastExplore определяется исключением только idea, exploring и draft; поэтому любое другое значение статуса считается прошедшим Explore, в том числе неизвестное значение. — `MarkView/Models/FeatureModels.swift:280`
- [Project fact] Отклонение применённого решения может создать finding о противоречии в связанных активных требованиях. При отделении решения от записи движку понадобится передавать вызывающему коду сведения о таких необходимых сопутствующих действиях. — `MarkView/Models/FeatureStore.swift:502`
- [Project fact] updateFeature возвращает Void и сохраняет ошибку в lastError, если YAML нельзя безопасно переписать или запись не удалась; вызывающий setStatus при этом формирует сообщение об успешном изменении статуса. — `MarkView/Models/FeatureStore.swift:519`

### Контракт вычисления {#n92}

- tags: контракт, детерминизм

Движок получает снимок issue, событие, инициатора и свидетельства, затем возвращает решение и необходимые эффекты без записи. Один и тот же вход должен давать одинаковый результат; состояние файла при применении нужно проверить повторно.

#### Evidence

- [AI inference] Чистое вычисление отделяет правила от интерфейсов и позволяет заранее объяснить результат; проверка снимка при применении предотвращает использование устаревшего решения.
- [Project fact] Шаг ready сейчас совмещает проверку условий и вызов updateFeature. — `MarkView/Models/ControlToolRunner+Flow.swift:338`

### Выбор и приоритет правила {#n93}

- tags: правила, валидация

Ключ правила следует составлять из типа issue, проверенного текущего статуса и события; результатом может быть целевой статус или явно разрешённое отсутствие изменения. Неизвестные сочетания должны получать отдельный отказ, а конфликтующие правила обнаруживаться при проверке таблицы.

#### Evidence

- [Project fact] Для bug установка duplicate_of принудительно выбирает closed и предварительно проверяет, что исходный bug существует и не совпадает с текущим. — `MarkView/Models/ProjectToolRunner.swift:403`
- [AI inference] Явное разрешение совпадений и обнаружение конфликтов предотвращают зависимость решения от порядка перебора таблицы.
- [Open assumption] Набор событий, допустимость повторов и порядок разрешения специальных случаев ещё нужно согласовать.

### Предикаты и готовность {#n94}

- tags: условия, готовность

Каждое правило должно ссылаться на именованные проверяемые условия и возвращать все невыполненные условия с относящимися к ним объектами. Порог готовности для перехода следует определить явно: текущий процент усредняет условия и сам по себе не объясняет, какие из них обязательны.

#### Evidence

- [Project fact] readiness вычисляется как округлённое среднее долей выполненных условий; условия с нулевым total исключаются из среднего. — `MarkView/Models/FeatureModels.swift:481`
- [Project fact] Шаг ready проверяет отсутствие всех открытых вопросов и findings, а расчёт готовности выделяет блокирующие вопросы и findings высокой серьёзности, среди других условий. — `MarkView/Models/ControlToolRunner+Flow.swift:338`
- [Open assumption] Какие из этих условий являются обязательными для ready, ещё требуется согласовать.

### Точная семантика условий {#n100}

- tags: семантика, границы

Для каждого предиката нужно зафиксировать, какие состояния связанных объектов считаются закрытыми и что означает отсутствие данных. Тестовые примеры должны отличать завершение раунда вопросов от полного понимания feature.

#### Evidence

- [Project fact] Для question закрыты answered и deferred; для finding — resolved, accepted-risk и dismissed. — `MarkView/Models/FeatureModels.swift:137`
- [Project fact] Тест фиксирует случай, когда discoveryDone истинно после ответа на все вопросы, но условие Feature understood ещё не выполнено, поскольку ожидаются новые вопросы. — `tools/tests/FeatureDiscoveryTests.swift:47`
- [Open assumption] Допустимость deferred и принятых рисков для каждого перехода должна быть определена правилами.

### Полномочия и подтверждения {#n95}

- tags: полномочия

Правило должно отдельно проверять тип инициатора, разрешённое ему событие и наличие требуемого подтверждения человека. Флаг, переданный агентом, следует трактовать как заявленное подтверждение, а не как самостоятельно проверенное доказательство личности или согласия.

#### Evidence

- [Project fact] Для статусов объектов approved, accepted, rejected, answered и superseded требуется by_user; стадии реализации feature исключены из списка статусов, устанавливаемых агентом. — `MarkView/Models/ProjectAgentTools.swift:389`
- [Project fact] requirePerson проверяет значение by_user в аргументах вызова. — `MarkView/Models/ControlToolRunner+Flow.swift:112`
- [AI inference] Булево значение в аргументах не удостоверяет личность или содержание решения человека.
- [Open assumption] Источник доверенного подтверждения и роли инициаторов необходимо определить.

### Неизвестные и отсутствующие данные {#n96}

- tags: валидация, совместимость

До выбора перехода движок должен различать явно записанный статус, значение по умолчанию и неизвестное значение. Неизвестные статусы и недостаточные данные следует возвращать как отдельные причины отказа, пока правила их обработки не согласованы.

#### Evidence

- [Project fact] При пустом статусе feature использует idea или draft в зависимости от структуры, а bug — open; bug дополнительно хранит признак наличия статуса. — `MarkView/Models/FeatureModels.swift:265`
- [Project fact] isPastExplore исключает только idea, exploring и draft, поэтому и неизвестный непустой статус проходит эту проверку. — `MarkView/Models/FeatureModels.swift:280`
- [AI inference] Различение отсутствующего и неизвестного значения позволяет не принимать опечатку за пройденный этап и не терять сведения о старых записях.

### План сопутствующих действий {#n97}

- tags: эффекты, согласованность
- position: 1189, 219

Разрешённое решение должно перечислять изменения статусов и дополнительные действия с указанием затронутых объектов и оснований. Исполнитель должен подтверждать успешность всего предусмотренного набора либо возвращать частичный сбой для восстановления.

#### Evidence

- [Project fact] finishExplore утверждает ожидающие требования и затем переводит feature в review, если Explore ещё не завершён. — `MarkView/Models/FeatureStore.swift:480`
- [Project fact] rejectDecision меняет статус решения и при наличии применённого решения и связанных активных требований создаёт finding о противоречии. — `MarkView/Models/FeatureStore.swift:504`
- [AI inference] Явный план действий позволяет вызывающему коду увидеть состав изменений и не считать частичную запись полным успехом.

### Граница исполнения плана {#n101}

- tags: запись, ошибки

Перед исполнением следует проверить, что все затронутые файлы доступны для безопасной записи, а результаты отдельных операций возвращаются явно. Многофайловые изменения требуют отдельной стратегии восстановления: атомарная запись одного файла не делает весь набор атомарным.

#### Evidence

- [Project fact] updateMany пропускает объекты с неподходящим front matter и игнорирует ошибки отдельных записей через try?. — `MarkView/Models/FeatureStore.swift:469`
- [Project fact] Вспомогательный write использует атомарную запись текста отдельного файла. — `MarkView/Models/FeatureStore.swift:219`
- [AI inference] При нескольких файлах атомарность каждой записи отдельно не гарантирует атомарность всей операции.

### Структура ответа движка {#n98}

- tags: результат, диагностика

Ответу нужны машинный код результата, выбранное правило и его версия, исходный и целевой статусы, проверенные условия и список эффектов. Для отказа следует вернуть устойчивые коды причин и данные для объяснения; успешное вычисление не означает успешную запись.

#### Evidence

- [Project fact] setStatus после вызова updateFeature возвращает сообщение об успехе, тогда как updateFeature сообщает об ошибках через lastError и не возвращает признак записи. — `MarkView/Models/ProjectToolRunner.swift:432`
- [AI inference] Раздельные результаты вычисления и применения делают отказ проверяемым разными интерфейсами и исключают ложное подтверждение сохранения.

### Версия и совместимость правил {#n99}

- tags: версионирование, совместимость

Каждое решение стоит связывать с версией набора правил: при изменении условий можно понять, по каким правилам оно было рассчитано. Совместимость старых значений следует определять явно для каждого типа issue, сохраняя исходное значение для диагностики.

#### Evidence

- [Project fact] Issues нормализует пробелы, регистр и подчёркивания и признаёт дополнительные статусы feature, включая done, rejected и cancelled; словарь feature содержит другой набор значений. — `MarkView/Models/IssueListing.swift:28`
- [Project fact] Словарь feature и bug определён отдельно от правил отображения Issues. — `MarkView/Models/FeatureVocabulary.swift:4`
- [Open assumption] Сопоставление старых значений с состояниями движка и политика изменения версий правил ещё не согласованы.

### Проверка самого движка {#n102}

- tags: тестирование

Для каждой строки таблицы нужны примеры разрешения и отказа, а также проверки неизвестных статусов, прав и отсутствующих свидетельств. Полезны проверки детерминизма и отсутствия записи при вычислении, а также тесты того, что все интерфейсы получают одинаковое решение для одинакового входа.

#### Evidence

- [Project fact] В репозитории уже есть автономный Swift-набор для правил discovery и readiness, компилируемый вместе с моделями. — `tools/tests/feature-discovery-tests.sh:1`
- [AI inference] Табличные и сквозные проверки позволяют отдельно проверить полноту правил и одинаковое применение правил вызывающими интерфейсами.

### Адаптеры источников {#n86}

- tags: интеграция

UI, MCP и автоматические наблюдатели преобразуют свои действия в общий контракт и показывают возвращённый результат. Изменения статуса в общих операциях редактирования также должны проходить проверку сервиса.

#### Evidence

- [Project fact] Интерфейс bug вызывает updateBug с непосредственной установкой status, а MCP отдельно устанавливает статусы через FeatureStore. — `MarkView/Views/FeaturePanelView.swift:826`
- [Project fact] Наблюдатель сравнивает снимки feature и пропускает записи без предыдущего снимка, в том числе новые и переименованные. — `MarkView/Models/FeatureStore.swift:679`
- [AI inference] Единственный адаптер MCP не охватит UI и другие существующие пути записи.

### Чтение и идентификация {#n87}

- tags: состояние

Компонент разрешает идентификатор в файл issue и читает актуальные статус и версию содержимого перед проверкой. Неизвестные или отсутствующие значения следует возвращать как отдельный случай, не назначая им молча новое значение.

#### Evidence

- [Project fact] IssueFacts различает feature и bug, использует slug или ключ bug и сохраняет пустую строку, если статус отсутствует. — `MarkView/Models/IssueListing.swift:7`
- [Project fact] Фильтр нормализует написание статусов и считает отсутствующий или неизвестный статус открытым. — `MarkView/Models/IssueListing.swift:26`
- [AI inference] Правила переходов должны явно обрабатывать неизвестный статус, поскольку классификация для фильтра не доказывает допустимость перехода.

### Хранилище и конкурентная запись {#n88}

- tags: запись, конфликты

Компонент сохранения перечитывает файл, сохраняет остальные поля и сообщает точный результат записи. Проверка ожидаемого состояния и версии должна быть связана с записью протоколом координации; при расхождении команда оценивается заново.

#### Evidence

- [Project fact] FeatureStore атомарно записывает текст файла и отказывает в перезаписи front matter, который нельзя безопасно восстановить. — `MarkView/Models/FeatureStore.swift:219`
- [Project fact] updateFeature возвращает Void и сообщает об ошибке через lastError; updateBug возвращает Bool. — `MarkView/Models/FeatureStore.swift:519`
- [AI inference] Атомарная замена файла сама по себе не объединяет сравнение версии и запись в единую операцию и не защищает от внешних редакторов, не участвующих в координации.

### Результат команды {#n89}

- tags: контракт, ошибки

Сервис возвращает структурированный результат: сохранённый переход, отказ с недостающими условиями, конфликт состояния или ошибку сохранения. UI и MCP преобразуют его в понятный ответ; успех возможен только после подтверждения записи.

#### Evidence

- [Project fact] Обработчик MCP для bug проверяет результат updateBug, а обработчик статуса feature сообщает об успехе после вызова updateFeature без проверки результата записи. — `MarkView/Models/ProjectToolRunner.swift:402`
- [AI inference] Общий тип результата устранит неоднозначность между отказом правила, конфликтом и ошибкой записи и позволит вызывающему коду реагировать на каждый случай.

### Учёт команд и восстановление {#n90}

- tags: надёжность
- position: 690, 507

Компонент учёта хранит ключ события, решение и основание перехода, а также состояние выполнения, достаточное для безопасного повтора и восстановления после частичного сбоя. Протокол должен определять, как обнаружить расхождение между записью issue и записью результата.

#### Evidence

- [Project fact] LifecycleLog добавляет событие в память, затем асинхронно записывает его в локальный файл; ошибка записи появляется отдельно. — `MarkView/Models/LifecycleLog.swift:73`
- [AI inference] Существующий журнал не связывает транзакционно запись Markdown с фиксацией результата, поэтому одного наличия события в памяти недостаточно для подтверждения восстановимого перехода.
- [Open assumption] Место хранения ключей повторов и протокол восстановления после сбоя необходимо выбрать и согласовать.

### Контроль внешних правок {#n91}

- tags: сверка
- position: 924, 586

Компонент сверки обнаруживает изменение статуса вне сервиса, сравнивает его с последним известным состоянием и представляет конфликт или запрос подтверждения, если основание неизвестно. Он не может гарантировать предотвращение внешней записи.

#### Evidence

- [Project fact] FeatureStore периодически проверяет изменения файлов и перечитывает features и bugs; наблюдатель жизненного цикла анализирует снимки features. — `MarkView/Models/FeatureStore.swift:88`
- [Project fact] Наблюдатель пропускает новые и переименованные feature без предыдущего снимка. — `MarkView/Models/FeatureStore.swift:679`
- [AI inference] Для строгой обработки внешних изменений нужны отдельные правила сверки для обоих типов issue, включая отсутствие предыдущего снимка.

### События и свидетельства {#n17}

- tags: git, CI
- position: 542, 151

Связать каждую работу со стабильными ID feature или bug, веткой, PR и ревизией; принимать события начала, проверок, merge и верификации из соответствующих источников. Проверять актуальный head и обязательные проверки, а при нехватке связи или источника сохранять неопределённость.

#### Evidence

- [Project fact] Текущее отслеживание GitHub и git ограничено features с событием implementationStarted; предыдущая история не восстанавливается, список связанных номеров ограничен 40. — `MarkView/Models/FeatureStore.swift:740`
- [Project fact] Текущий локальный сбор связывает commit с feature по упоминанию папки или номера issue в сообщении. — `MarkView/Models/FeatureStore.swift:810`
- [AI inference] Упоминание в сообщении commit и открытие PR – недостаточные по отдельности свидетельства завершения всех требований.

### Сверка и надёжность {#n18}

- tags: reconciliation, надёжность
- position: 340, 152

Запускать сверку при старте проекта, после событий и периодически; поддержать повторную обработку, идемпотентность, сравнение версии и журнал причин. При недоступности GitHub или конфликте изменений сохранять последнее подтверждённое состояние, показывать расхождение и повторять попытку.

#### Evidence

- [Project fact] Сбор lifecycle GitHub запускается при опросе интеграции и не работает при её отключении; автоматические события дедуплицируются по стадии и примечанию. — `MarkView/Models/FeatureStore.swift:751`
- [AI inference] Фоновая сверка восполняет пропущенные события, а проверка версии защищает от перезаписи действий человека или другой сессии.

### Связь с GitHub issues {#n19}

- tags: GitHub, конфликты
- position: 148, 150

Явно определить источник истины для каждой операции и обеспечить двустороннюю сверку без циклов. Сначала определять конфликт, затем применять только разрешённые изменения; удалённое закрытие или reopening не должно незаметно менять локальные факты без проверки причины.

#### Evidence

- [Project fact] Существующая синхронизация односторонняя и не отражает закрытие GitHub issue обратно в документы. — `docs/features/sync-github-issues-with-feature-bug-status-from/decisions/DEC-003.md:33`
- [Open assumption] Не определено, имеет ли ручное изменение GitHub право автоматически открывать или закрывать соответствующую запись MarkView.

### Осведомлённость AI {#n5}

- tags: AI, контекст
- position: -334, 16

Обеспечить агенту актуальные правила и контекст работы с issues при запуске и в ходе сессии.

#### Evidence

- [AI inference] Инструкции и актуальное состояние должны быть доступны в момент принятия решения.

### Контекст при запуске сессии {#n20}

- tags: сессия, bootstrap

При запуске агента передавать краткие обязательные правила: как найти текущую запись, вызвать markview_guide, получить её состояние и сообщать о событиях работы. Если MCP недоступен, явно показывать это и использовать предусмотренный резервный путь; не считать молчаливое отсутствие инструментов успешным подключением.

#### Evidence

- [Project fact] MarkView регистрирует проектный MCP для поддерживаемых агентов и предусматривает Skill с командой --project-call для случаев, когда MCP недоступен. — `MarkView/Models/AgentBrowserRegistration.swift:31`
- [Project fact] markview_guide описывает features, bugs, поля, статусы и workflow. — `MarkView/Models/ProjectAgentTools.swift:44`
- [AI inference] Само наличие зарегистрированного сервера или Skill не гарантирует, что агент прочитает правила и применит их в каждой сессии.

### Привязка работы к issue {#n21}

- tags: контекст, привязка

В начале задачи агент ищет подходящую запись, читает её и явно связывает с ней текущую сессию; если подходящей нет, создаёт запись, когда работа этого требует. При смене задачи или восстановлении сессии контекст и фактический статус перечитываются.

#### Evidence

- [Project fact] Проектный MCP предоставляет списки и полное чтение features и bugs. — `MarkView/Models/ProjectAgentTools.swift:47`
- [AI inference] Явная привязка сессии к стабильному ID позволяет отличить работу над issue от простого просмотра проекта.

### Обязанности агента {#n22}

- tags: контракт, права

Агент сообщает через MCP о подтверждённом начале, остановке, результате проверок и завершении, прикладывая ссылки на проверяемые артефакты. Решение о допустимом статусе принимает общий сервис; правила проекта и решения человека сохраняют приоритет.

#### Evidence

- [Project fact] Существующий guide ставит инструкции проекта выше стандартного процесса и требует проверять критерии приёмки. — `MarkView/Models/ProjectAgentTools.swift:274`
- [Project fact] Для решений человека, включая утверждение требований, инструменты предусматривают by_user. — `MarkView/Models/ProjectAgentTools.swift:90`
- [AI inference] Сообщение агента является свидетельством события, но не заменяет проверку результатов GitHub, CI и ревизии.

### Видимость и ограничения {#n23}

- tags: интерфейс, покрытие

Показывать в терминале и Issues активный issue, подтверждённый статус, последнее основание и ошибки синхронизации. Для внешних терминалов, неподключённых клиентов и ручных изменений нужен отдельный механизм обнаружения или явная привязка: обещать автоматическое знание обо всём без неё нельзя.

#### Evidence

- [Project fact] Проектные инструменты привязаны к проекту окна, в котором работает агент; control-сервер регистрируется отдельно для управляющего агента. — `MarkView/Models/ProjectAgentTools.swift:3`
- [Project fact] Агенты внутри терминалов MarkView не получают управляющие инструменты запуска других агентов. — `MarkView/Models/ControlAgentTools.swift:9`
- [AI inference] Наблюдаемость ограничена подключёнными источниками и не распространяется автоматически на произвольную внешнюю сессию.

### Внедрение и проверка {#n6}

- tags: проверка
- position: -35, 339

Определить порядок внедрения, обработку ошибок и критерии доверия к состояниям.

#### Evidence

- [AI inference] Поэтапное внедрение помогает обнаружить расхождения между автоматикой и реальной работой.

### Согласовать правила переходов {#n24}

- tags: политика
- number: 1
- position: 245, 371

Зафиксировать таблицу для каждого типа: исходный и конечный статус, событие, проверка, актор, последствия и обратный переход. Отдельно определить значение implemented, fixed, verified, archived и GitHub closed, а также судьбу незавершённой или отменённой работы.

#### Evidence

- [Project fact] Feature и bug имеют разные словари, а отображение Issues и синхронизация GitHub используют собственные множества завершённых состояний. — `MarkView/Models/IssueListing.swift:34`
- [Open assumption] Порог завершения и полномочия человека и автоматических источников ещё не определены однозначно.

### Внедрять по этапам {#n25}

- tags: этапы
- number: 2
- layout: down
- position: -65, 543

Сначала добавить журнал и режим наблюдения, затем общий сервис переходов и подключение UI/MCP, после этого — обработчики git, PR и CI и фоновую сверку. Автоматическое закрытие и reopening включать после проверки расхождений на реальных сценариях.

#### Evidence

- [Project fact] В проекте уже есть журнал жизненного цикла и сбор некоторых событий git и GitHub, которые можно оценить как основу наблюдения. — `MarkView/Models/FeatureStore.swift:651`
- [AI inference] Режим наблюдения позволяет измерить ошибочные срабатывания до автоматического изменения статусов и GitHub issues.
- [Project fact] Уточнение к последовательности: сбор событий PR, review и CI уже выполняется при опросе GitHub, а история локального git проверяется примерно раз в минуту. Это сбор событий для журнала; сам по себе он не устанавливает строгие переходы статусов. — `MarkView/Models/FeatureStore.swift:759`
- [Project fact] Охват существующего наблюдения ограничен: git и GitHub отслеживаются только для feature с событием implementationStarted, начиная с его времени; число связанных issues ограничено 40. При первом чтении списка создаётся базовый снимок без восстановления пропущенных переходов. — `MarkView/Models/FeatureStore.swift:740`
- [Project fact] Уточнение к отложенному включению закрытия: уже существует запускаемая пользователем синхронизация, которая без предварительного просмотра закрывает открытый GitHub issue, если все связанные элементы завершены. Закрытые issues она не открывает повторно. — `docs/architecture/modules/feature-workflow.md:404`
- [Project fact] Существующий журнал допускает только добавление записей; повреждённые или нераспознаваемые строки при чтении пропускаются. Событие сначала появляется в памяти, а ошибка последующей записи на диск сообщается отдельно. — `MarkView/Models/LifecycleLog.swift:3`
- [Project fact] Для поэтапного внедрения есть отдельные тесты правил синхронизации: они проверяют, что закрытый issue остаётся закрытым, а также обработку ошибок доступа и предварительную проверку прав. — `tools/tests/IssueSyncTests.swift:100`
- [AI inference] Перед расширением автоматизации полезно отдельно учитывать текущую ручную синхронизацию: её реальные закрытия и будущие предлагаемые переходы в режиме наблюдения следует различать при анализе расхождений.

### Зафиксировать исходное поведение {#n28}

- tags: этап, baseline
- number: 1

До изменений составить матрицу существующих путей записи статуса, регистрации событий и ручной синхронизации. Зафиксировать результаты на контрольных проектах и отдельно пометить уже выполняемые реальные закрытия GitHub issues.

#### Evidence

- [Project fact] Существуют отдельный журнал событий и отдельный механизм синхронизации документированных статусов с GitHub issues. — `MarkView/Models/LifecycleLog.swift:3`
- [Project fact] Правила синхронизации реализованы отдельно от выполнения запуска. — `MarkView/Models/IssueSync.swift:3`
- [AI inference] Матрица точек записи и контрольный снимок нужны, чтобы отличать существующие эффекты от поведения новой автоматизации.

### Ввести наблюдение за предложениями {#n29}

- tags: этап, наблюдение
- number: 2

Добавить выключенный по умолчанию режим, который вычисляет предлагаемый переход, его причину и расхождение с фактическим состоянием без изменения статусов. Учитывать пропуски наблюдения, ошибки записи и идентификаторы источников; ручной Sync учитывать как отдельное реальное действие.

#### Evidence

- [Project fact] Наблюдатель сравнивает свежий список со снимком и пропускает новые или переименованные элементы без предыдущего снимка. — `MarkView/Models/FeatureStore.swift:679`
- [Project fact] Автоматическая дедупликация захвата сейчас сопоставляет стадию и текст note. — `MarkView/Models/FeatureStore.swift:750`
- [AI inference] Отдельные записи предложений и результатов дадут возможность оценить пропуски и ложные срабатывания до включения автоматических изменений.

### Вынести переходы в сервис {#n30}

- tags: этап, сервис
- number: 3
- position: -573, 657

Реализовать чистую проверку перехода и исполнитель с явными результатами: применён, запрещён, конфликт или ошибка записи. При записи перечитывать файл, сохранять защиту lossless YAML и проверять ожидаемый исходный статус; журналировать подтверждённый результат только после успешного сохранения.

#### Evidence

- [Project fact] FeatureStore перечитывает объект с диска и отказывается переписывать YAML, если представление не является lossless; отдельные методы обновляют feature и bug. — `MarkView/Models/FeatureStore.swift:311`
- [Project fact] Журнал добавляет событие в память до асинхронной записи на диск, ошибка которой сообщается позднее. — `MarkView/Models/LifecycleLog.swift:79`
- [AI inference] Проверка ожидаемого статуса и подтверждение сохранения снижают риск затереть параллельное изменение и ошибочно объявить переход успешным.

### Граница сервиса {#n103}

- tags: архитектура

Предлагается сервис переходов для feature и bug, который принимает запрос от UI, MCP или фонового процесса и возвращает типизированный результат. Доступ к файлам и обновление отображаемого состояния следует отделить от чистой проверки.

#### Evidence

- [Project fact] FeatureStore работает на MainActor и содержит отдельные операции записи feature и bug. — `MarkView/Models/FeatureStore.swift:7`
- [AI inference] Единая граница позволяет вызывающим сторонам использовать одинаковую семантику, не смешивая вычисление правил с файловым вводом-выводом.

### Результат для вызывающего кода {#n104}

- tags: контракт, ошибки

Возвращать отдельные случаи: применён, запрещён, конфликт и ошибка чтения или записи; включать идентификатор записи, исходный и целевой статусы и понятную причину. Успех должен означать завершённую запись, а не только отсутствие ошибки в общем состоянии.

#### Evidence

- [Project fact] updateFeature не возвращает результат и сообщает об ошибке через lastError; MCP setStatus после его вызова отвечает, что статус изменён. — `MarkView/Models/FeatureStore.swift:519`
- [Project fact] Для bug updateBug возвращает Bool, а MCP проверяет его перед ответом об успехе. — `MarkView/Models/ProjectToolRunner.swift:417`
- [AI inference] Типизированный результат устраняет неоднозначность общего lastError и позволяет клиентам корректно показывать конфликт или отказ.

### Исполнитель и сохранение {#n105}

- tags: хранилище

Исполнитель перечитывает актуальный документ, проверяет возможность безопасной перезаписи YAML и применяет изменение к этому содержимому. Отсутствующий или нечитаемый файл нужно отличать от разрешённого создания нового overview.

#### Evidence

- [Project fact] updateFeature при неудачном чтении использует adoptedOverview, тогда как updateBug возвращает ошибку чтения. — `MarkView/Models/FeatureStore.swift:519`
- [Project fact] FrontMatter помечает представление как небезопасное для записи, если парсер отбросил данные; join заново формирует front matter и тело. — `MarkView/Models/FrontMatter.swift:50`
- [AI inference] Для перехода существующей записи не следует незаметно заменять ошибку чтения созданием документа.

### Конкурентная запись {#n106}

- tags: конкуренция

Проверять ожидаемый статус по перечитанному документу; при несовпадении возвращать конфликт с актуальным статусом. Одна такая проверка и атомарная замена файла не исключают правку между чтением и записью: для строгой гарантии нужен согласованный механизм блокировки или условной записи, учитывающий внешних редакторов.

#### Evidence

- [Project fact] FeatureStore записывает текст с atomically: true после отдельного чтения и преобразования содержимого. — `MarkView/Models/FeatureStore.swift:219`
- [AI inference] Атомарная замена файла сама по себе не делает последовательность чтение – проверка – запись атомарной и не защищает от внешнего процесса, не участвующего в протоколе блокировки.

### Порядок исполнения {#n107}

- tags: исполнение

Сервис разрешает запись, читает актуальный файл, проверяет исходное состояние и правила, затем сохраняет изменение и возвращает результат. Обновление модели и публикация подтверждённого события следуют за успешным сохранением.

#### Evidence

- [Project fact] После записи FeatureStore перечитывает данные через reloadSync; изменение списка features запускает observeLifecycle. — `MarkView/Models/FeatureStore.swift:259`
- [AI inference] Явный порядок позволяет не объявлять переход выполненным до сохранения и не регистрировать его повторно через наблюдатель.

### Фактический и вычисленный статус {#n108}

- tags: совместимость

При сравнении ожидаемого состояния сервису нужно различать записанное значение и статус, который модель подставляет по умолчанию. Политику перехода для отсутствующего поля следует определить явно и применять одинаково при проверке и записи.

#### Evidence

- [Project fact] Feature.status подставляет idea для структурированной feature и draft для неструктурированной, если поле status пусто. — `MarkView/Models/FeatureModels.swift:265`
- [Open assumption] Согласовано ли считать подставленный статус фактическим исходным состоянием при переходе, пока не установлено.

### Подтверждение журнала {#n109}

- tags: журнал, надёжность

Результат сохранения документа и результат записи события следует представлять раздельно: переход может сохраниться, даже если журнал недоступен. Такая частичная ошибка должна быть видимой и пригодной для последующего восстановления; повтор операции не должен выдавать её за несостоявшуюся запись статуса.

#### Evidence

- [Project fact] LifecycleLog сначала добавляет событие в память и возвращает его, а запись в файл выполняет асинхронно; ошибка записи появляется позднее в lastError. — `MarkView/Models/LifecycleLog.swift:64`
- [AI inference] Два отдельных файла не дают общей транзакции: между сохранением статуса и записью журнала возможен сбой.

### Потоки и обновление UI {#n110}

- tags: потоки, UI

Файловое чтение и запись сервиса выполнять вне главного потока, а публикацию результата и обновление наблюдаемой модели возвращать на MainActor. При этом нужно сохранять защиту от устаревшей фоновой загрузки.

#### Evidence

- [Project fact] CLAUDE.md требует выполнять изменения состояния UI на MainActor, а файловую работу — вне главного потока. — `CLAUDE.md`
- [Project fact] FeatureStore отбрасывает фоновую загрузку, если после её начала изменилась generation; reloadSync увеличивает generation. — `MarkView/Models/FeatureStore.swift:121`

### Проверка контракта сервиса {#n111}

- tags: проверки

Проверить отдельно чистую оценку и исполнитель с временными файлами: успешный переход, отказ, несовпадение ожидаемого статуса, нечитаемый файл, небезопасный YAML и ошибку записи. Дополнительно проверить частичный сбой журнала и отсутствие ложного успеха в вызывающем коде.

#### Evidence

- [Project fact] В проекте нет XCTest target; CLAUDE.md предлагает автономные swiftc-проверки для чистых модулей. — `CLAUDE.md`
- [Project fact] Существующий lifecycle-tests.sh отдельно компилирует и запускает проверку модулей жизненного цикла. — `tools/tests/lifecycle-tests.sh:11`
- [AI inference] Внедряемые зависимости файловой записи и журнала позволяют воспроизводимо проверять ошибки без повреждения рабочих документов.

### Подключить все точки записи {#n31}

- tags: этап, интеграция
- number: 4
- position: 380, 760

Перевести на сервис операции UI, MCP и внутренние сценарии создания issues и работы AI. Возвращать вызывающей стороне фактический результат, включая отказ и ошибку; прямые правки Markdown выявлять при перечитывании и показывать как внешние изменения, поскольку запретить их сервис не может.

#### Evidence

- [Project fact] MCP отдельно обновляет статус feature и bug; ответ для feature сейчас формируется после вызова updateFeature без проверки результата записи. — `MarkView/Models/ProjectToolRunner.swift:424`
- [Project fact] UI Issues напрямую устанавливает статусы implemented и fixed, а панель feature также напрямую изменяет статус bug. — `MarkView/Views/IssueSyncViews.swift:180`
- [Project fact] Внутренний сценарий AI вызывает markImplementing после создания issues. — `MarkView/Models/FeatureAI.swift:1815`
- [AI inference] Внешний редактор может менять Markdown в обход приложения, поэтому строгая проверка доступна только для управляемых приложением операций.

### Меню и действия Issues {#n112}

- tags: UI, статус

Подключить меню статуса feature в навигаторе, меню bug в панели feature и действие завершения в Issues. Каждое действие должно передавать запрос сервису и показывать его фактический результат.

#### Evidence

- [Project fact] Навигатор и панель feature вызывают updateFeature и updateBug для выбранного статуса; Issues напрямую устанавливает implemented или fixed. — `MarkView/Views/FeatureNavigatorView.swift:599`
- [Project fact] Панель bug и действие Issues записывают статус напрямую. — `MarkView/Views/FeaturePanelView.swift:826`
- [Project fact] Действие Issues устанавливает implemented или fixed. — `MarkView/Views/IssueSyncViews.swift:180`
- [AI inference] Эти UI-вызовы нужно заменить вызовами сервиса с обработкой отказов и ошибок.

### Команды MCP для статуса {#n113}

- tags: MCP

Маршрутизировать ветви `setStatus` для feature и `setBugStatus` через сервис, сохранив проверку ссылки `duplicate_of` и разграничение статусов объектов feature. Ответ MCP должен отражать отказ или ошибку записи.

#### Evidence

- [Project fact] setBugStatus проверяет duplicate_of и результат updateBug; setStatus отдельно обрабатывает саму feature и её объекты, но после updateFeature сообщает об успехе без проверки записи. — `MarkView/Models/ProjectToolRunner.swift:403`
- [AI inference] При миграции важно не применять правила статуса issue к отдельным объектам feature.

### Создание feature и bug {#n114}

- tags: создание, MCP

Охватить начальный статус при создании, включая последующее переопределение через MCP и специальные сценарии intake и UI Studio. Создание и последующие изменения должны сообщать о частичном успехе, если запись создана, но следующий переход отклонён или не сохранён.

#### Evidence

- [Project fact] createFeature сразу записывает idea или exploring; MCP затем отдельно задаёт запрошенный статус и отвечает об успешном создании. — `MarkView/Models/FeatureStore.swift:226`
- [Project fact] MCP создаёт feature и затем вызывает updateFeature для записи запрошенного статуса. — `MarkView/Models/ProjectToolRunner.swift:274`
- [Project fact] Быстрый intake устанавливает ready, а UI Studio после создания устанавливает implementing. — `MarkView/Models/FeatureIntake.swift:82`
- [Project fact] UI Studio создаёт feature, затем устанавливает implementing. — `MarkView/Models/UIStudioSession+Tracking.swift:85`
- [Project fact] createBug передаёт draft в BugReportWriter; MCP создаёт bug со статусом open. — `MarkView/Models/ProjectToolRunner.swift:382`
- [AI inference] Двухшаговое создание требует явно различать успешное создание и неуспешный последующий переход.

### Explore, Review и готовность {#n115}

- tags: AI, MCP

Подключить переходы после исследования и AI Review, общее завершение Explore и команду готовности в Control MCP. Учесть, что завершение Explore также утверждает требования: вызывающему коду нужен результат обеих частей операции.

#### Evidence

- [Project fact] После успешного исследования FeatureAI переводит idea в exploring, а после review переводит ранние статусы в review. — `MarkView/Models/FeatureAI.swift:532`
- [Project fact] AI Review устанавливает review для exploring, draft и idea. — `MarkView/Models/FeatureAI.swift:1138`
- [Project fact] finishExplore сначала утверждает требования, затем может установить review; Control MCP использует его и отдельно устанавливает ready. — `MarkView/Models/FeatureStore.swift:491`
- [Project fact] Команда готовности Control MCP напрямую записывает ready. — `MarkView/Models/ControlToolRunner+Flow.swift:335`
- [AI inference] Результат составного действия должен показывать, какие изменения действительно выполнены.

### Передача работы агенту {#n116}

- tags: AI, handoff

Подключить передачу feature агенту, создание GitHub issues по плану, одиночное и пакетное исправление bugs. Сохранить явное сообщение о частичном результате, когда передача агенту и изменение статуса завершаются по-разному.

#### Evidence

- [Project fact] startImplementation отправляет запрос помощнику и затем вызывает markImplementing; fixBugWithAI сначала вызывает updateBug с fixing, не проверяя результат, затем отправляет запрос. — `MarkView/Models/WorkspaceManager.swift:4489`
- [Project fact] Пакетное исправление использует результат записи каждого bug, исключает неотмеченные записи и предусматривает отмену отметок при неудачном запуске. — `MarkView/Models/WorkspaceManager.swift:4528`
- [Project fact] После создания issues сценарий FeatureAI сохраняет план и вызывает markImplementing. — `MarkView/Models/FeatureAI.swift:1814`
- [AI inference] Сервисный отказ не должен маскировать факт уже выполненной внешней операции или отправленного задания.

### Прямая запись bug intake {#n117}

- tags: intake, bug

Перевести запись нового bug из intake на управляемый путь создания. При последующем добавлении номера GitHub issue не перезаписывать старую копию front matter поверх возможного нового статуса.

#### Evidence

- [Project fact] Bug intake сам формирует front matter со статусом open и записывает файл напрямую; после создания GitHub issue он повторно записывает ранее сформированный front matter с номером issue. — `MarkView/Models/FeatureIntake.swift:296`
- [AI inference] Повторная запись старого содержимого может затереть изменение статуса, произошедшее между двумя записями.

### Передача спецификации и прототипа {#n118}

- tags: handoff, прототип

Подключить `SpecificationHandoff.markReady` и `PrototypeFeatureWriter.write`. При замене прямой записи спецификации сохранить проверку изменения исходного файла и обработку неудачного создания ревизии.

#### Evidence

- [Project fact] SpecificationHandoff самостоятельно читает overview и устанавливает ready для ранних статусов. — `MarkView/Models/SpecificationHandoff.swift:80`
- [Project fact] Перед записью overview handoff повторно проверяет его содержимое; при ошибке удаляет только что созданную ревизию. — `MarkView/Models/SpecificationHandoff.swift:119`
- [Project fact] PrototypeFeatureWriter создаёт feature и затем устанавливает ready вместе с полями и содержимым overview. — `MarkView/Models/PrototypeFeatureWriter.swift:25`

### Записи UI Studio {#n119}

- tags: UI Studio

Подключить создание feature из пакета и отслеживание исправлений bug, включая последующие отметки и заметки. Статусы требований, которые Studio хранит как объекты feature, оставить в отдельном контуре правил.

#### Evidence

- [Project fact] StudioFeatureWriter создаёт feature из пакета и устанавливает implementing. — `MarkView/Models/UIStudioSession.swift:3043`
- [Project fact] UI Studio создаёт bug через createBug; функция mark отдельно обновляет объект feature или bug и добавляет заметку. — `MarkView/Models/UIStudioSession+Tracking.swift:165`
- [AI inference] При подключении сервиса надо сохранить связь между изменением статуса bug и сопровождающей заметкой.

### Проверка актуальности bug {#n120}

- tags: bug, проверка

Направить автоматическое закрытие после вердикта `alreadyFixed` через сервис вместе с записью основания. Сохранить различие между ошибкой закрытия и необязательной записью остальных результатов проверки.

#### Evidence

- [Project fact] BugValidity.record устанавливает closed и добавляет объяснение в обсуждение при alreadyFixed. — `MarkView/Models/BugValidity.swift:332`
- [Project fact] recordValidity сообщает об ошибке сохранения закрытия; для остальных вердиктов ошибка записи заметки не блокирует анализ. — `MarkView/Models/FeatureBugValidity.swift:44`

### Перезапуск feature {#n121}

- tags: перезапуск

Подключить `restartFeature`, который возвращает статус в idea и удаляет созданные материалы. Сервисный отказ следует учитывать до необратимых для сценария действий; частичный сбой перемещения файлов должен оставаться видимым.

#### Evidence

- [Project fact] restartFeature перемещает созданные материалы в Trash, затем устанавливает idea и очищает поля понимания; ошибка перемещения прекращает операцию. — `MarkView/Models/FeatureStore.swift:440`
- [AI inference] Проверка допустимости перехода до удаления материалов уменьшит риск частичного перезапуска при отказе сервиса.

### Неявное принятие старых записей {#n122}

- tags: совместимость

Проверить операции, которые создают отсутствующий статус как побочный эффект обычного редактирования. Для старых документов явно определить, является ли это созданием управляемого состояния и как его показывать пользователю.

#### Evidence

- [Project fact] При отсутствии overview updateFeature может построить adoptedOverview со статусом draft и записать его при обычном обновлении. — `MarkView/Models/FeatureStore.swift:519`
- [Project fact] Анализ bug устанавливает open, если поле status отсутствует. — `MarkView/Models/FeatureIntake.swift:506`
- [Open assumption] Правила ещё должны определить, считать ли добавление отсутствующего статуса переходом или первоначальным принятием записи.

### Подключить источники событий {#n32}

- tags: этап, события
- number: 5
- position: 684, 754

Адаптировать уже существующий сбор git, PR, review и CI к входу сервиса переходов, сохранив исходные идентификаторы и время. До расширения охвата явно обработать пределы выборки, поздние и повторные события, отсутствие данных и привязку событий к нужному issue.

#### Evidence

- [Project fact] Сбор GitHub использует связанные PR, ограничивает выборку связанных PR и контекстов проверок, а закрытый без merge PR не считается завершением. — `MarkView/Models/LifecycleCapture.swift:97`
- [Project fact] Локальный git связывает коммит с feature по упоминанию папки или номера issue после начала реализации. — `MarkView/Models/FeatureStore.swift:809`
- [AI inference] Упоминание в коммите и ограниченные выборки не доказывают полноту связи; сомнительные случаи следует оставлять на сверку, а не автоматически менять статус.

### Добавить фоновую сверку {#n33}

- tags: этап, сверка
- number: 6
- position: 940, 744

После подключения источников построить сверку локальных файлов, журнала и GitHub: выявлять пропуски, устаревшие данные и противоречия, повторять временно неудачные чтения и показывать нерешённые случаи. До разрешения конфликта не применять неоднозначный переход.

#### Evidence

- [Project fact] Журнал хранится локально на одном Mac и совместно используется окнами; автоматические события проекта записывает один выбранный FeatureStore. — `MarkView/Models/LifecycleLog.swift:3`
- [Project fact] При сборе GitHub ошибки отдельных запросов сейчас подавляются через try?, поэтому отсутствие события не доказывает отсутствие действия. — `MarkView/Models/FeatureStore.swift:770`
- [AI inference] Сверка должна отличать недоступный источник от подтверждённого отсутствия события и сохранять расхождения для последующего разбора.

### Поэтапно включить GitHub изменения {#n34}

- tags: этап, GitHub
- number: 7
- position: 1193, 748

Сначала сравнивать предлагаемые закрытия и reopening с реальными результатами ручного Sync. Затем отдельно включать автоматическое закрытие и reopening для ограниченного набора проектов: перед записью заново проверять состояние, связи и права, фиксировать результат и предусмотреть отключение автоматизации.

#### Evidence

- [Project fact] Ручной Sync закрывает открытый issue, когда все связанные элементы завершены, и никогда не открывает закрытый повторно. — `MarkView/Models/IssueSync.swift:241`
- [Project fact] Клиент уже умеет закрывать и открывать issue, а ручной Sync перед запуском проверяет доступ. — `MarkView/Models/GitHubClient.swift:909`
- [Open assumption] Критерии допустимой доли расхождений, состав пилотных проектов и правила reopening ещё нужно согласовать до включения записи в GitHub.

### Отключение и восстановление {#n35}

- tags: эксплуатация

Переключатель должен останавливать новые автоматические действия, а незавершённые операции оставлять видимыми для сверки. Для ошибочного закрытия или reopening предусмотреть явное исправление с указанием причины и повторной проверкой текущего состояния.

#### Evidence

- [Project fact] Закрытие проекта очищает отчёт ручного Sync, но уже выполняющийся запуск продолжает работу на GitHub. — `MarkView/Models/IssueSyncRun.swift:37`
- [AI inference] Отключение не отменяет уже отправленный сетевой запрос; результат такой операции нужно дочитать и показать пользователю.

### Установить условия перехода этапов {#n36}

- tags: этап, критерии
- number: 8
- position: 1462, 749

Для каждого этапа заранее определить владельца решения, набор контрольных сценариев и критерии продвижения: покрытие точек записи, полноту наблюдения, число необъяснённых расхождений и успешность восстановления после ошибок. При провале критерия оставить действующий режим и устранить причину.

#### Evidence

- [Project fact] Проект использует отдельные swiftc-проверки для чистых модулей и требует ручной проверки поведения, которое не покрывает компиляция. — `CLAUDE.md:115`
- [Open assumption] Численные пороги качества и продолжительность наблюдения в репозитории для этой инициативы не установлены; их необходимо согласовать.

### Проверки перед расширением {#n37}

- tags: тестирование

Добавить проверки таблицы переходов, конфликтующих записей, повторной доставки, отказов диска и сети, нескольких окон и несовпадений GitHub. Отдельно проверить совместимость существующего ручного Sync и пройти сквозные сценарии на тестовом репозитории.

#### Evidence

- [Project fact] Существующая самостоятельная проверка Sync компилирует правила и тестовый main без XCTest target. — `tools/tests/issue-sync-tests.sh:1`
- [Project fact] Текущий запуск Sync допускает только один запуск на проект в процессе приложения и обрабатывает ошибки отдельных issues по отдельности. — `MarkView/Models/IssueSyncRun.swift:15`
- [AI inference] Проверки на повтор и частичный отказ необходимы до разрешения фоновых изменений, поскольку запрос мог выполниться, даже если его результат не был получен.

### Разбить поставку на PR {#n38}

- tags: этап, поставка
- number: 9
- position: 1724, 741

Разделить реализацию на небольшие проверяемые PR по этапам, сохраняя совместимость данных и выключенные переключатели незавершённой автоматизации. Для каждого app PR выполнить сборку и требуемые проверки, после merge выпустить Release и подписанный DMG по правилам проекта.

#### Evidence

- [Project fact] Изменения приложения выполняются в отдельных ветках через PR с обновлением версии; после проверок PR сливается в main. — `CLAUDE.md:63`
- [Project fact] Для каждого изменения приложения после merge требуются локальная Release-сборка и подписанный, нотариально заверенный DMG из merged origin/main. — `CLAUDE.md:121`
- [AI inference] Небольшие PR с независимыми переключателями упрощают проверку и остановку развёртывания на конкретном этапе.

### Проверить критические сценарии {#n26}

- tags: тесты, сбои
- number: 3
- position: -291, 459

Проверить начало и отмену работы, провал отправки агенту, создание draft PR, новые коммиты после зелёного CI, merge, откат, регрессию, дубликаты, несколько записей на одном GitHub issue и одновременные изменения. Проверять также повтор событий, недоступность MCP или GitHub и восстановление после перезапуска.

#### Evidence

- [Project fact] В пакетном исправлении bugs предусмотрен откат статусов, если промпт не удалось отправить. — `MarkView/Models/WorkspaceManager.swift:4527`
- [AI inference] Эти сценарии проверяют, что статус отражает подтверждённое состояние даже при сбоях и повторной доставке событий.

### Контроль качества и исследования {#n27}

- tags: аудит, метрики
- number: 4
- position: -302, 305

Измерять долю записей с подтверждённой связью с работой, задержку обновления, число конфликтов и ошибочных переходов; показывать историю с актором, причиной и ссылками на доказательства. Веб-поиск не выполнялся: для предложенной архитектуры использованы прочитанные файлы проекта и явно отмеченные выводы.

#### Evidence

- [Project fact] Lifecycle log записывает события с источником, актором и примечанием; текущие GitHub-события связываются с PR или commit через примечание. — `MarkView/Models/FeatureStore.swift:751`
- [AI inference] Полный журнал решений о переходах и метрики расхождений позволят проверять доверие к автоматизации.
