---
type: research
id: 2026-09-28-a-hocu-ctoby-ty-podumal-ocen-horoso-nad
title: Я хочу, чтобы ты подумал очень хорошо над тем, как поменять принципиально весь дизайн…
question: Я хочу, чтобы ты подумал очень хорошо над тем, как поменять принципиально весь дизайн, весь UI, скажем так, этой аппликации. Я хочу, чтобы эта аппликация была привлекательна и чтобы ею пользовались люди, многие люди. Поэтому мне нужно сделать ее как можно более привлекательной и удобной. Я хочу, чтобы ты прошелся по аппликации и сделал глубокий ресерч насчет того, какие UI изменения надо бы сделать в аппликации, чтобы она стала популярной среди людей.
created: 2026-09-28
status: complete
web_queries:
  - Apple Human Interface Guidelines macOS navigation sidebars toolbars windows accessibility color contrast ...
  - site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search accessibility color ...
  - site:developer.apple.com/documentation/appkit nswindow representedURL titlebar document icon window tabbing ...
  - Obsidian official help quick switcher command palette workspaces ...
  - site:support.apple.com/guide/mac-help Mission Control view open windows thumbnails app windows ...
  - site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search navigation content design ...
  - https://developer.apple.com/design/human-interface-guidelines/toolbars
targets: [docs/features/feature-2/overview.md]
---

# Я хочу, чтобы ты подумал очень хорошо над тем, как поменять принципиально весь дизайн…

## Question

Я хочу, чтобы ты подумал очень хорошо над тем, как поменять принципиально весь дизайн, весь UI, скажем так, этой аппликации. Я хочу, чтобы эта аппликация была привлекательна и чтобы ею пользовались люди, многие люди. Поэтому мне нужно сделать ее как можно более привлекательной и удобной. Я хочу, чтобы ты прошелся по аппликации и сделал глубокий ресерч насчет того, какие UI изменения надо бы сделать в аппликации, чтобы она стала популярной среди людей.

Target documents: `docs/features/feature-2/overview.md`

## Summary

MarkView уже предлагает сильный сценарий для работы с кодом и документацией, но интерфейс показывает слишком много возможностей одновременно. Я рекомендую перестроить окно вокруг трёх понятных задач — **читать и писать, понимать проект, вести работу** — и сделать поиск, первый запуск и работу с AI проще. Цветовая идентификация проектов хорошо дополнит этот дизайн, если останется видимой вместе с названием проекта. Рост популярности нужно проверять на пользователях: по одному только коду его предсказать нельзя.

## Findings

- [Project fact] README позиционирует MarkView как среду для изучения проекта через X-Ray, редактирования документов и работы с AI-терминалами. Это содержательная основа продукта, но описание охватывает много разных задач и предполагает знакомство с инструментами разработчика. `README.md:5`, `README.md:23`, `README.md:85`
- [Project fact] Окно состоит из левой панели, центрального редактора и правой панели. Слева переключаются `Files` и `Issues`; справа — `Contents`, `Search`, `Git`, `Terminal`, `Feature`. Терминал размещён внутри правой панели, хотя его собственный экран рассчитан примерно на 340 пунктов ширины. `MarkView/Views/ContentView.swift:95`, `MarkView/Views/FeatureNavigatorView.swift:28`, `MarkView/Views/TOCView.swift:9`, `MarkView/Views/ModuleExplorerView.swift:34`
- [AI inference] Такая компоновка заставляет чтение документа, поиск, работу с Git и AI делить одно и то же узкое пространство. Самое перспективное изменение — пересмотреть распределение задач по окну, а не только оформить существующие вкладки по-новому.
- [Project fact] Сейчас поиск устроен тремя разными способами: фильтр файлов действует в текущей папке, полнотекстовый поиск находится в правой панели и запускается по Enter, а поиск в документе живёт внутри редактора. Единого быстрого перехода к файлу или команде в просмотренном коде нет. `MarkView/Views/FileTreeView.swift:61`, `MarkView/Views/TOCView.swift:120`, `MarkView/Resources/Editor/index.html:1322`
- [Project fact] Редактор Markdown показывает постоянно видимую строку с форматированием, вставкой объектов, переводом, сохранением и переключением в Source; отдельная панель появляется при выделении текста. Интерфейс использует `contenteditable` и скрытое поле с Markdown. Рабочая версия редактора находится в `MarkView/Resources/Editor/`; `EditorWeb/` пока не подключён к приложению. `MarkView/Resources/Editor/index.html:1333`, `MarkView/Resources/Editor/index.html:1365`, `MarkView/Resources/Editor/index.html:1463`, `CLAUDE.md:9`
- [Project fact] Многие элементы панелей используют базовый текст 9–11 пунктов, а вкладки документов имеют высоту 24 пункта. При этом в приложении уже есть отдельное масштабирование интерфейсного текста от 80% до 200% — полезная основа для проверки новой типографики. Эти размеры сами по себе не доказывают проблему доступности; её нужно проверить на экранах и с пользователями. `MarkView/Views/TabBarView.swift:39`, `MarkView/Views/FeaturePanelView.swift:136`, `MarkView/Models/AppFontScale.swift:7`
- [Project fact] Первый экран предлагает открыть файл, папку или создать проект, а после открытия папки — X-Ray либо файл. Пошаговый сценарий создания проекта уже существует, но простой пример того, зачем открывать X-Ray и что делать дальше, на стартовом экране не показан. `MarkView/Views/ContentView.swift:351`, `MarkView/Views/NewProjectSheet.swift:23`
- [Project fact] Задача `feature-2` посвящена различению окон нескольких проектов. Уже приняты автоматическое назначение цвета с возможностью замены, цветная иконка проекта, показ цвета в окне и при переключении окон; ответ на `Q-005` выбирает изменение цвета нажатием на иконку. При этом раздел `Scope` обзорного документа всё ещё называет некоторые из этих решений открытыми. `docs/features/feature-2/overview.md:39`, `docs/features/feature-2/overview.md:47`, `docs/features/feature-2/decisions/DEC-002.md:25`, `docs/features/feature-2/decisions/DEC-003.md:25`, `docs/features/feature-2/decisions/DEC-004.md:25`, `docs/features/feature-2/questions/Q-005.md:52`
- [Project fact] Сейчас заголовок окна содержит название приложения, версию и имя папки; `representedURL` связывает окно с папкой и даёт ему системную иконку документа. Отдельного цветового элемента в просмотренном коде окна пока нет. `MarkView/Models/WindowTitle.swift:3`, `MarkView/Views/ContentView.swift:257`, `MarkView/Views/ContentView.swift:291`
- [External fact] Apple рекомендует давать окнам короткие содержательные названия и не занимать заголовок именем приложения; для macOS также важны настраиваемые окна, меню и клавиатурные команды. Для MarkView это аргумент в пользу заголовка, где первым читается **проект**, а версия остаётся в About. [Toolbars — Apple](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Designing for macOS — Apple](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [External fact] `NSWindow.representedURL` управляет иконкой файла в заголовке; Apple описывает возможность заменить изображение этой иконки. Mission Control показывает окна для выбора, но найденная документация не подтверждает, что небольшая иконка заголовка будет различима на его миниатюрах. Поэтому требование `feature-2` о переключении окон нуждается в прототипе и проверке на поддерживаемых macOS. [representedURL — Apple](https://developer.apple.com/documentation/appkit/nswindow/representedurl), [Mission Control — Apple](https://support.apple.com/en-mn/guide/mac-help/mh35798/mac)
- [External fact] Apple советует не передавать смысл одним цветом и использовать системные цвета с учётом светлого, тёмного и повышенно контрастного режимов. Для проекта цвет стоит сочетать с текстовым названием и различимой формой либо буквенным знаком; цветные статусы задач требуют такой же проверки. [Color — Apple](https://developer.apple.com/design/human-interface-guidelines/color), [Differentiate Without Color Alone — Apple](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria)
- [External fact] В рекомендациях Apple поиск важных материалов должен занимать заметное место и иметь ясную область действия. Obsidian предоставляет быстрый переход к заметке с клавиатуры; Typora показывает другой удачный принцип — сохранять внимание на документе; VS Code позволяет перестраивать рабочие панели. Это примеры отдельных решений, а не доказательство, что их интерфейсы следует копировать целиком. [Searching — Apple](https://developer.apple.com/design/human-interface-guidelines/searching), [Quick switcher — Obsidian](https://obsidian.md/help/plugins/quick-switcher), [Typora](https://typora.io/), [Custom Layout — VS Code](https://code.visualstudio.com/docs/configure/custom-layout)
- [External fact] Исследования NN/g поддерживают постепенное раскрытие редких команд в сложных приложениях. Привлекательный вид улучшает первое впечатление, но может скрывать затруднения в сценариях; для оценки нужны наблюдения за выполнением задач, включая успешность, время и ошибки. [Progressive Disclosure — NN/g](https://www.nngroup.com/articles/progressive-disclosure/), [Aesthetic-Usability Effect — NN/g](https://www.nngroup.com/articles/aesthetic-usability-effect/), [Usability Metrics — NN/g](https://www.nngroup.com/articles/usability-metrics/)
- [Project fact] Для AI-функций README указывает необходимость установленного и настроенного Claude Code либо Codex; часть возможностей зависит от `git`, `gh` или ключа Whisper. Кроме того, редактор загружает D3, Dagre и Turndown из CDN, хотя руководство проекта требует локальной поставки библиотек. Это влияет на удобство первого запуска и работу без сети. `README.md:159`, `MarkView/Resources/Editor/index.html:1547`, `CLAUDE.md:24`
- [Project fact] README сообщает, что DMG подписан, но ещё не нотариализован, поэтому первый запуск требует действия через Privacy & Security. Для новых пользователей это часть первого опыта продукта наряду с интерфейсом. `README.md:151`
- [Open assumption] Живое окно приложения я не смог осмотреть: автоматическая проверка отклонила доступ инструмента управления интерфейсом к MarkView с сообщением «Computer Use was not approved to use MarkView» и не дала более подробной причины. Оценки плотности, контраста и поведения Mission Control основаны на коде и требуют визуальной проверки.
- [Open assumption] Неизвестно, какая группа должна стать первой широкой аудиторией: разработчики, технические авторы или люди, ведущие проект через спецификации. Также нет результатов пользовательских тестов, подтверждающих, какие сценарии приводят к регулярному использованию MarkView.
- [AI inference] Отправленные поисковые запросы: `Apple Human Interface Guidelines macOS navigation sidebars toolbars windows accessibility color contrast`; `Nielsen Norman Group progressive disclosure complex applications usability`; `Obsidian help workspaces tabs properties command palette official`; `Apple Human Interface Guidelines onboarding empty states macOS`; `site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search accessibility color`; `site:developer.apple.com/design/human-interface-guidelines color accessibility differentiate without color macOS`; `site:developer.apple.com/design/human-interface-guidelines windows macOS document title toolbar`; `site:developer.apple.com/design/human-interface-guidelines empty states onboarding`; `site:developer.apple.com/documentation/appkit nswindow representedURL titlebar document icon window tabbing`; `site:support.apple.com mac switch windows same app app switcher mission control`; `site:nngroup.com/articles usability testing 5 users task success measurement`; `site:obsidian.md/help quick switcher search graph view canvas official`; `site:typora.io WYSIWYG markdown editor focus mode official`; `Obsidian official help quick switcher command palette workspaces`; `Typora official features focus mode live preview markdown editor`; `Visual Studio Code official documentation workbench command palette side bar layout`; `site:support.apple.com/guide/mac-help Mission Control view open windows thumbnails app windows`; `site:developer.apple.com/documentation/appkit Mission Control window thumbnail custom icon NSWindow`; `site:developer.apple.com/design/human-interface-guidelines search fields macOS search`; `site:nngroup.com/articles aesthetic usability effect trust interface`. *(labelled as inference: no source URL cited)*

## Recommendations

1. **Определить первый сценарий и аудиторию.** Я бы начал с человека, который открыл незнакомый проект и хочет быстро понять его структуру, найти нужный файл и продолжить работу. Сделать кликабельный прототип этого пути и отдельно проверить сценарий автора документации. До выбора аудитории не закреплять окончательно структуру всего приложения.

2. **Пересобрать рабочее окно вокруг задач.** Предлагаемая структура: *Документы* для чтения и письма, *Карта проекта* для X-Ray, *Работа* для задач и Git. Слева — навигация внутри текущей задачи, в центре — основной материал, справа — контекст выбранного файла или объекта. Терминалу дать раскрываемую область достаточной ширины либо отдельную вкладку окна. `SwiftUI` и `AppKit` стоит сохранить; прототипом сравнить нынешний `HSplitView` с более гибкой компоновкой.

3. **Сделать один быстрый вход к содержимому.** Добавить поиск по именам файлов, тексту и командам с клавиатуры, показывать область поиска и недавние результаты. Локальные фильтры оставить там, где они нужны. На стартовом экране показать недавние проекты и короткий путь «Открыть проект → увидеть карту → открыть файл», с возможностью сразу работать без AI.

4. **Успокоить редактор и обновить визуальную систему.** Оставить постоянно видимыми несколько частых действий и ясный переключатель режима; остальные команды поместить в контекстное меню и меню вставки. Задать общие токены для SwiftUI и HTML-редактора: системные цвета, типографику, интервалы, состояния фокуса и ошибок. Проверить макеты при 100% и 200% масштабе интерфейса, в светлом, тёмном и повышенно контрастном режимах. `WKWebView` пока сохранить; отдельно исследовать надёжность `contenteditable` и преобразования Markdown, а внешние скрипты поставить локально до расширения редактора.

5. **Сделать AI понятным по ходу действия.** Для каждой операции явно показывать, что будет прочитано, какой инструмент запускается, где появится результат и как остановить работу. Частые действия оставить доступными быстро, специальные — раскрывать по запросу. Сохранить локальные CLI как сильную сторону продукта и сделать отсутствие настроенного AI понятным состоянием интерфейса.

6. **Завершить `feature-2` как часть общей идентичности проекта.** Сохранить название проекта текстом и существующее поведение системной иконки папки; испытать отдельную нажимаемую цветную иконку рядом с названием. Дать автоматический цвет с выбором пользователем и проверить различимость без цвета. На macOS 13+ отдельно протестировать несколько окон в Mission Control: если иконка на миниатюре слишком мала, подобрать дополнительный заметный знак внутри окна, не меняя цвета документов или вкладок.

7. **Проверять редизайн по задачам, затем улучшить первый запуск.** Провести небольшие качественные тесты с пользователями каждой выбранной группы: открыть проект, найти файл, понять компонент через X-Ray, изменить документ, выполнить AI-действие и вернуться к нужному окну. Исправлять обнаруженные препятствия между раундами; для заявлений об улучшении доли успешных действий потребуется отдельная количественная проверка. После проверки интерфейса убрать также барьер установки, описанный в README: нотариализовать выпуск.

## Sources

Project files:

- `docs/features/feature-2/overview.md`
- `README.md`
- `MarkView/Views/ContentView.swift`
- `MarkView/Views/FeatureNavigatorView.swift`
- `MarkView/Views/TOCView.swift`
- `MarkView/Views/ModuleExplorerView.swift`
- `MarkView/Views/FileTreeView.swift`
- `MarkView/Resources/Editor/index.html`
- `CLAUDE.md`
- `MarkView/Views/TabBarView.swift`
- `MarkView/Views/FeaturePanelView.swift`
- `MarkView/Models/AppFontScale.swift`
- `MarkView/Views/NewProjectSheet.swift`
- `docs/features/feature-2/decisions/DEC-002.md`
- `docs/features/feature-2/decisions/DEC-003.md`
- `docs/features/feature-2/decisions/DEC-004.md`
- `docs/features/feature-2/questions/Q-005.md`
- `MarkView/Models/WindowTitle.swift`

Web pages:

- <https://developer.apple.com/design/human-interface-guidelines/toolbars>
- <https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/>
- <https://developer.apple.com/documentation/appkit/nswindow/representedurl>
- <https://support.apple.com/en-mn/guide/mac-help/mh35798/mac>
- <https://developer.apple.com/design/human-interface-guidelines/color>
- <https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria>
- <https://developer.apple.com/design/human-interface-guidelines/searching>
- <https://obsidian.md/help/plugins/quick-switcher>
- <https://typora.io/>
- <https://code.visualstudio.com/docs/configure/custom-layout>
- <https://www.nngroup.com/articles/progressive-disclosure/>
- <https://www.nngroup.com/articles/aesthetic-usability-effect/>
- <https://www.nngroup.com/articles/usability-metrics/>

Web searches:

- "Apple Human Interface Guidelines macOS navigation sidebars toolbars windows accessibility color contrast ..."
- "site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search accessibility color ..."
- "site:developer.apple.com/documentation/appkit nswindow representedURL titlebar document icon window tabbing ..."
- "Obsidian official help quick switcher command palette workspaces ..."
- "site:support.apple.com/guide/mac-help Mission Control view open windows thumbnails app windows ..."

---

## Follow-up 1: Ты совершенно не рассказал какой должен быть UI - почини, мне нужно гораздо больше информации, желательно визуальной (2026-09-28)

Да, предыдущий ответ описывал направления, но почти не показывал интерфейс. Я предлагаю конкретный облик MarkView: **спокойное рабочее окно с тремя разделами — «Файлы», «Карта», «Работа»**. В центре всегда находится то, ради чего открыт раздел: документ, схема проекта или задача. Поиск доступен из любой точки, а детали и AI появляются рядом с текущим материалом. Ниже — макеты целевого UI, а не снимки работающего приложения.

### Findings

- [Project fact] Сейчас `ContentView` собирает левую панель, редактор и правую панель в `HSplitView`; справа переключаются `Contents`, `Search`, `Git`, `Terminal`, `Feature`. В коде уже появились нажимаемая цветная иконка проекта и полоса высотой 3 пункта под toolbar. Значит, редизайн должен включить их как существующую идентификацию окна. `MarkView/Views/ContentView.swift:98`, `MarkView/Views/TOCView.swift:9`, `MarkView/Views/ProjectColorViews.swift:9`, `MarkView/Views/ProjectColorViews.swift:69`
- [Project fact] Постоянная панель редактора содержит форматирование, вставку, AI-действия, сохранение и переключение в `Source`; при выделении текста появляется ещё одна панель. X-Ray тоже размещает виды, фильтры и действия в одной строке. Это конкретные места, где новому дизайну нужна более ясная иерархия элементов. `MarkView/Resources/Editor/index.html:1333`, `MarkView/Resources/Editor/index.html:1395`, `MarkView/Resources/Editor/index.html:1463`
- [External fact] Apple рекомендует оставлять в toolbar частые действия и поиск, не переполнять его, а боковую панель делать скрываемой при нехватке места. Для macOS Apple указывает 13 пунктов как рекомендуемый базовый размер интерфейсного текста и советует проверять увеличение до 200%. Эти правила поддерживают предложенные ниже размеры и поведение узкого окна. [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [AI inference] **Визуальный характер:** MarkView должен ощущаться как место для чтения и осмысления проекта, а не как набор служебных панелей. В светлой теме — мягкий нейтральный фон окна, чистая поверхность документа, тёмный текст и один постоянный цвет для действий. В тёмной — такие же отношения яркости без сплошного чёрного поля. Цвет конкретного проекта остаётся у его названия и в полосе окна; он не окрашивает кнопки, вкладки и документ. Отправные размеры для макета: toolbar 48–52 пункта, боковая панель 250–280, инспектор 270–300, строки списка 32–36; интерфейсный текст 13–14, текст документа 16, заголовок документа 26–28 пунктов. Это проектные значения, контраст и масштабирование нужно проверить.
- [AI inference] **Основное окно и документ.** Верхняя строка отвечает за проект и действия всего окна. Три раздела меняют содержимое левой панели и центра. Правая колонка показывает только сведения об открытом объекте.
  ```text
  ┌─ ● проект ▾ ──────────── ⌕ Найти файл, текст, действие… ⌘K ── + ─ AI ┐
  │══════════════════════════ цвет проекта ═════════════════════════════│
  ├─────────────────────┬────────────────────────────────┬───────────────┤
  │ Файлы  Карта  Работа│ README.md   architecture.md    │ В документе   │
  │─────────────────────│────────────────────────────────│───────────────│
  │ Файлы проекта       │ docs / architecture / README   │ Обзор         │
  │ ⌕ Фильтр этой папки │                                │ Установка     │
  │                     │ Название документа             │ Использование │
  │ ▾ docs              │ Подзаголовок и основной текст… │ Ограничения   │
  │   README.md         │                                │               │
  │   architecture.md   │ Широкие поля для чтения.       │ Связанные     │
  │ ▸ MarkView          │ Строка текста не растягивается │ документы     │
  │                     │ на всю ширину окна.            │               │
  │                     │                                │               │
  │                     │ Стиль ▾   Вставить ▾  Source   │               │
  ├─────────────────────┴────────────────────────────────┴───────────────┤
  │ Сохранено · файл локальный                 Задачи AI: 0    Терминал ▴ │
  └──────────────────────────────────────────────────────────────────────┘
  ```
  Текст документа получает ширину около 700–760 пунктов даже на большом мониторе. В постоянно видимой строке остаются стиль, вставка и `Source`; точное форматирование появляется у выделения. Кнопка фокуса скрывает обе боковые колонки, сохраняя их состояние. Открытые вкладки и положение в документе сохраняются при переходе в «Карту» или «Работу».
- [AI inference] **Карта проекта — главный визуальный экран X-Ray.** Вместо плотной полосы фильтров у карты есть один явный выбор вида, поиск компонента и кнопка «Фильтры». Выбранный узел открывает читаемую карточку справа; «Открыть файлы» связывает карту с редактором.
  ```text
  ┌─────────────────────┬────────────────────────────────┬───────────────┐
  │ Карта проекта       │ Карта  Структура  Развёртывание │ Компонент     │
  │                     │ Документы                      │               │
  │ ⌕ Найти компонент   │────────────────────────────────│ Название      │
  │ Все компоненты      │ ⌕ Поиск на карте   Фильтры ▾  │ Что делает    │
  │ Изменённые          │                                │ Зависит от    │
  │ Без документации    │       [API] ─── [Сервис]       │ Используется  │
  │                     │          ╲       ╱            │ Файлы (6)    │
  │                     │          [Хранилище]           │               │
  │                     │                                │ Открыть файлы │
  │                     │ Масштаб −  100%  +  По размеру │ Спросить AI  │
  │─────────────────────│────────────────────────────────│               │
  │ Сканирование: готово│ Легенда: тип узла + подпись   │               │
  └─────────────────────┴────────────────────────────────┴───────────────┘
  ```
  «Структура» и «Документы» должны быть полезны сразу после локального сканирования; AI-анализ обогащает карту по явному действию. Цветовые наложения показывают состояние только вместе с подписью или значком. Так пользователь видит проект до выбора модели AI.
- [AI inference] **«Работа» даёт задачам полноценный экран.** Нынешние этапы `Explore`, `Review`, `Resolve`, `Build` уже существуют в узкой панели `FeaturePanelView`; в новом UI они становятся последовательностью в основной области. Git и GitHub — соседние разделы «Работы», а терминал открывается снизу с достаточной высотой либо разворачивается во вкладку. `MarkView/Views/FeaturePanelView.swift:5`, `MarkView/Views/FeaturePanelView.swift:136`, `MarkView/Views/GitView.swift:22`, `MarkView/Views/ModuleExplorerView.swift:34`
  ```text
  ┌─────────────────────┬────────────────────────────────┬───────────────┐
  │ Работа              │ Цветовая идентификация проектов│ Контекст      │
  │ Задачи  Git  GitHub  │ Идея → Проверка → Решения → Код │               │
  │─────────────────────│────────────────────────────────│ Связанные     │
  │ ⌕ Найти задачу      │ Статус: в работе               │ документы     │
  │ Функции             │                                │               │
  │  ● Идентификация    │ Что уже решено                 │ Проверки      │
  │  ○ Быстрый поиск    │ • Цвет назначается автоматически│  3 из 4      │
  │ Ошибки              │ • Пользователь меняет цвет    │               │
  │  ! Терминал         │                                │ AI-действия   │
  │                     │ Открытые вопросы               │ с результатом │
  │ + Новая задача      │ Следующий шаг: проверить окна  │ здесь         │
  ├─────────────────────┴────────────────────────────────┴───────────────┤
  │ Терминал ▴  Сессия 1 · Codex · работа продолжается          Развернуть│
  └──────────────────────────────────────────────────────────────────────┘
  ```
  У каждой задачи нужны видимые «что известно», «что требуется решить» и «следующий шаг». Статус показывается словом, а цвет лишь помогает считывать его быстрее.
- [AI inference] **Стартовый экран** должен демонстрировать продукт за несколько секунд. Вместо пустого центра с набором равнозначных кнопок — одно главное действие, недавние проекты и короткое объяснение результата:
  ```text
  ┌──────────────────────────────────────────────────────────────────────┐
  │                       Понять проект. Продолжить работу.              │
  │                                                                      │
  │              [ Открыть папку ]   Открыть файл   Создать проект       │
  │                                                                      │
  │  Недавние проекты                  После открытия папки              │
  │  ● atlas               вчера       1. Увидеть структуру              │
  │  ● documentation       понедельник 2. Найти нужный файл             │
  │                                    3. Записать решение или задачу    │
  │                                                                      │
  │  Незавершённый черновик проекта                           Продолжить │
  └──────────────────────────────────────────────────────────────────────┘
  ```
  Существующий мастер создания проекта уже сохраняет черновик и показывает его на стартовом экране; здесь меняются подача и приоритеты действий. `MarkView/Views/NewProjectSheet.swift:5`, `MarkView/Views/ContentView.swift:399`
- [AI inference] **Поиск и AI — два компактных слоя поверх текущей работы.** Поиск открывается по `⌘K` и сразу показывает область каждого результата; `⌘F` остаётся поиском внутри документа. Перед AI-действием пользователь видит конкретный охват и место результата.
  ```text
  ╭─ ⌕  Где сохраняется цвет проекта? ──────────────── Все области ▾ ─╮
  │ Файлы          ProjectColor.swift            Models / …             │
  │ Содержимое     «Цвет связан с проектом…»      overview.md           │
  │ Команды        Открыть карту проекта          ⌘4                    │
  ╰─────────────────────────────────────────────────────────────────────╯
  ╭─ Объяснить выбранный компонент ─────────────────────────────────────╮
  │ Прочитает: компонент и связанные файлы              Посмотреть (6) │
  │ Исполнитель: выбранный AI                            Изменить ▾     │
  │ Результат: ответ в карточке компонента                              │
  │                                                Отмена   Запустить    │
  ╰─────────────────────────────────────────────────────────────────────╯
  ```
  Во время выполнения эта карточка показывает шаг, прошедшее время и «Остановить». Если действие меняет файлы, результат сначала показывается как изменения для просмотра. Поиск остаётся доступным и без настроенного AI.
- [AI inference] **Правило для размеров окна:** при ширине около 1200 пунктов инспектор закрывается первым и открывается кнопкой; при ширине около 900 левая панель становится выдвижной; текст и основные действия остаются видимыми. При масштабе интерфейса 200% панели переходят в эти состояния раньше. Для MarkView это особенно важно, потому что приложение уже поддерживает масштаб интерфейсного текста 80–200%. `MarkView/Models/AppFontScale.swift:7`
- [Open assumption] Макеты показывают предлагаемое состояние, а не измеренные экраны текущей сборки. Фактическую читаемость, поведение узких окон и различимость проектной полосы в Mission Control нужно проверить на работающем приложении; код и документы этого не подтверждают.
- [AI inference] Для этой дополнительной проверки отправлены ровно два веб-запроса: `site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search navigation content design`; `site:developer.apple.com/design/human-interface-guidelines macOS accessibility color contrast layout text size`.

### Recommendations

1. Сделать кликабельный прототип **этих пяти состояний**: старт, документ, карта, задача и поиск с AI-карточкой. Показать каждый при ширине 1440 и 1000 пунктов, в светлой и тёмной теме.

2. Утвердить одну визуальную систему для SwiftUI и встроенного редактора: поверхности, текст, интервалы, состояния кнопок и фокуса. Сохранить существующие цветную иконку и полосу проекта; проверить их вместе с названием окна.

3. Начать переработку с каркаса окна и поиска, затем перенести X-Ray и задачи в основную область, после этого упростить редактор и AI-действия. Критерий для каждого экрана: пользователь без подсказки понимает, где он находится, что можно сделать сейчас и где появится результат.

### Sources

Project files:

- `MarkView/Views/ContentView.swift`
- `MarkView/Views/TOCView.swift`
- `MarkView/Views/ProjectColorViews.swift`
- `MarkView/Resources/Editor/index.html`
- `README.md`
- `MarkView/Views/FeaturePanelView.swift`
- `MarkView/Views/GitView.swift`
- `MarkView/Views/ModuleExplorerView.swift`
- `MarkView/Views/NewProjectSheet.swift`
- `MarkView/Models/AppFontScale.swift`

Web pages:

- <https://developer.apple.com/design/human-interface-guidelines/toolbars>
- <https://developer.apple.com/design/human-interface-guidelines/sidebars>
- <https://developer.apple.com/design/human-interface-guidelines/accessibility>

Web searches:

- "site:developer.apple.com/design/human-interface-guidelines macOS sidebars toolbars search navigation content design ..."
- "https://developer.apple.com/design/human-interface-guidelines/toolbars"
