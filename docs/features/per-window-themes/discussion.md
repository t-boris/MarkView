# Discussion — Per-Window Themes

### Boris Tsekinovsky · 2026-11-08

Что-то я совсем не вижу, где ты мне предложил бы разные темы, и что это значит, каждая тема. Я не очень понял, почему ты мне это не рассказываешь. Это, наверное, самое сложное. То есть, предложи тему, что меняется, шрифты, цвета, что еще, какие темы, какие шрифты могут быть, какие цвета могут быть, ну и так далее.

### AI · 2026-11-08

Вы правы: я перечислил названия, но не объяснил, как темы будут выглядеть. Ниже — **мои предложения для обсуждения**, а не уже выбранный дизайн. Цвета предварительные: их нужно проверить на реальных окнах и по контрастности.

| Тема | Характер | Фон редактора / панелей | Текст и акцент | Подсветка кода |
|---|---|---|---|---|
| **Darcula-inspired** | Тёплая тёмно-серая, напоминает среду IntelliJ | `#2B2B2B` / `#323232` | Светло-серый `#E0E0E0`, оранжевый `#E6A15C` | Приглушённые оранжевый, зелёный и голубой |
| **Midnight** | Глубокая сине-чёрная, спокойная | `#151C2B` / `#1D2738` | Холодный белый `#E5EBF5`, голубой `#79B8FF` | Голубой, бирюзовый и сиреневый |
| **Graphite** | Нейтральная тёмная, сдержанная | `#202124` / `#2A2C30` | Светло-серый `#E8EAED`, фиолетовый `#B39DDB` | Мягкие фиолетовый, зелёный и янтарный |
| **Paper** | Тёплая светлая, похожая на бумагу | `#FFFCF5` / `#F2EDE3` | Тёмный `#292724`, синий `#315E9B` | Сдержанные синий, зелёный и бордовый |

Тема меняет не только фон: панели, вкладки, кнопки, границы, ссылки, активный элемент, выделение текста, фокус, подсветку синтаксиса и палитру терминала. Акцент — это цвет ссылок, активных элементов и индикаторов; его можно переопределить для отдельного окна и вернуть к цвету темы. Ошибки и предупреждения сохраняют собственные различимые цвета. Я бы также сделал аккуратнее отступы, границы и состояния наведения во всех темах: это даст ощущение более законченного интерфейса, а не просто смены краски.

Для шрифтов предлагаю **системный San Francisco** для интерфейса и обычного текста, а для исходного Markdown и терминала — **SF Mono** с системным моноширинным запасным вариантом. Для блоков кода в предпросмотре — тот же моноширинный шрифт. Размер интерфейса и размер документа остаются отдельными настройками. Альтернатива — дать темам разные шрифты или добавить выбор шрифта: это выразительнее, но увеличивает объём настройки и может менять переносы текста. Предлагаю пока сохранить единое семейство шрифтов, а выбор добавить только если он вам нужен.

Какие из четырёх направлений вам нравятся? И важный выбор для спецификации: **оставляем одинаковые шрифты во всех темах или хотите выбирать шрифт отдельно для каждого окна?** Если палитры в целом подходят, следующим шагом можно уточнить, как они должны выглядеть на примере одного окна.

Пока решение записывать рано: названия, палитры и подход к шрифтам ещё не подтверждены вами.

### AI updated the requirements · 2026-11-08

DEC-001 written into the overview.

### Agent · 2026-11-08

Implementation notes (2026-11-08, 5.41.0), recorded so the specification matches the code.

- Base tokens are exactly DEC-003's: editor, panel, text and accent of Darcula (#2B2B2B, #323232, #E0E0E0, #E6A15C), Midnight (#151C2B, #1D2738, #E5EBF5, #79B8FF), Graphite (#202124, #2A2C30, #E8EAED, #B39DDB) and Paper (#FFFCF5, #F2EDE3, #292724, #315E9B). No base shade moved. The contrast step DEC-003 allows was needed only for derived colours: Paper's semantic green (#287030) and orange (#A05000) are darker than the shared semantic colours because the shared ones were below 4.5:1 on Paper's panel; an accent used as text or icon is lightened or darkened until it reaches 4.5:1 on the editor and panel backgrounds, while badge fills keep the raw accent with a readable label colour.
- Classic Dark and Classic Light (DEC-004) keep every colour of the pre-theme look value for value, checked against a fixture captured from the pre-theme pages (Tests/Fixtures/themes/classic-computed.json). One consequence of DEC-003's single font family: the monospaced font of source and code in Classic is now the system stack (SF Mono, then the system monospaced fallback) instead of Menlo, so it matches every other theme.
- System follows macOS and resolves to Classic Dark or Classic Light. Before this change every window was forced dark whatever the saved setting; now a Mac in light mode shows Classic Light under System, which is what the assumption "System follows macOS" asks for.
- A selection is the background mixed with the accent (38% on dark appearances, 24% on light ones), so selections follow the accent while staying legible; Classic without an accent override keeps its original selection colour.
- The mechanism (DEC-006: one palette per window in the SwiftUI environment, NSWindow.appearance per window, web tokens in one shared file) was chosen by the implementer and is still proposed; it needs the owner's acceptance.
- Not themed on purpose: documents' own content (an HTML file previewed as HTML, images and their transparency checkerboard, the web pages of the in-app browser, the prototype and UI Studio previews of other people's designs), the fixed semantic colours of status dots and category colours of diagrams, and Recursive Insight's sandboxed page, which follows only dark or light.

### Agent · 2026-11-08

Delivery and evidence (2026-11-08): merged as PR #313 (main 64d3d4c), version 5.41.0; all ten PR checks passed on the final commit 4bec170.

Automated evidence per acceptance criterion (no window is shown by any of these):
- AC-1 picker, System and four presets, Paper light and the rest dark: theme-model-tests (choices, light/dark, System resolves to Classic Dark/Light), window-theme-tests (NSWindow.appearance per theme, picker renders in every theme). The Theme… command (Shift-Cmd-T) and the header button set the window's showsPicker; that wiring is verified by reading the code, not by driving the menu.
- AC-2 immediate update of interface, editor, preview, discussion and terminal: window-theme-tests (rendered pixels follow a theme change at once), theme-web-tests (every appearance on the real pages, a change is a restyle with no reload).
- AC-3 accent override, reset, independence of windows: window-theme-tests (an accent in one window does not change another), theme-web-tests (override and reset, two pages with two themes at once).
- AC-4 restore and new-window start: window-session-tests (theme and accents survive a new process; an older session opens), window-theme-tests (a new window takes the last change with every accent; restoring is not remembered as a change).
- AC-5 upgrade and fallback: theme-model-tests (legacy light, dark, system and absent become Classic; unreadable or wrong-typed settings fall back to Classic Dark).
- AC-6 legibility and kept state: contrast of every text pair at least 4.5:1 in theme-model-tests and on rendered pages in theme-web-tests; open documents, scroll position and unsaved input survive twelve theme changes (theme-web-tests).
What was not done, because the owner excluded it from this goal: no check in the installed application, no manual walk-through. The acceptance criteria are therefore left unticked for the owner's acceptance (implemented, not verified).

Records: the sentence in plan I-3 that the palettes and font approach are unconfirmed is superseded by DEC-003. DEC-006 (the mechanism) is still proposed and needs the owner's decision. Existing failures on pristine origin/main, unrelated to this change: prototype-runtime-tests (2), code-architecture-tests (2), terminal-link-tests (1).
