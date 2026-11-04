# Discussion — Исследование через mind map

### Boris Tsekinovsky · 2026-11-04

Кроме прочего, мне нужно иметь несколько существующих уже лейаутов для Майн Мэпа, чтобы я мог сделать лейаут либо на весь Майн Мэп, вернее, не на Майн Мэп, а на любой бренч. То есть я любой из бренчей могу сделать один из, там, не знаю, семи разных лейаутов.

### Answer to Q-001 · 2026-11-04

Что должно произойти с существующими Markdown-исследованиями?

A. Новые исследования создавать как карты; существующие Markdown-отчёты оставить доступными как сейчас.

### Answer to Q-002 · 2026-11-04

Насколько полно первая версия должна воспроизводить функции прототипа?

A. Включить показанные в прототипе основные действия с картой и свойствами узла, дополнив их настоящим AI-исследованием.

### Answer to Q-003 · 2026-11-04

Что должен означать перенос узла?

A. Разрешить и визуально перемещать узел, и переносить его в другую ветвь.

### Answer to Q-004 · 2026-11-04

Какую проверяемость должен сохранять research в карте?

A. Сохранить для карты источники, различие фактов и выводов AI и историю веб-запросов.

### AI · 2026-11-04

Зафиксировал: у каждого бренча можно выбрать один из нескольких готовых лейаутов. Семь пока воспринимаю как ориентир, а не точное количество.

Что должно происходить, если внутри бренча уже настроен другой лейаут, а пользователь применяет новый к родительскому бренчу?

- **A. Сохранить вложенные лейауты:** новый лейаут располагает дочерние ветви, но не перестраивает их содержимое. Это сохраняет настройки, хотя результат может быть менее единообразным.
- **B. Перестроить всю подветку:** новый лейаут применяется ко всем вложенным узлам. Результат единообразен, но прежние настройки теряются.
- **C. Спрашивать при применении:** пользователь выбирает каждый раз; это гибче, но добавляет шаг.

Я рекомендую **A**: она сохраняет уже сделанную пользователем настройку.

### AI updated the requirements · 2026-11-04

DEC-001, DEC-002 written into REQ-003, the overview.

### AI updated the requirements · 2026-11-04

DEC-003 written into REQ-001, REQ-002, REQ-003, REQ-004, the overview.

### AI updated the requirements · 2026-11-04

DEC-004 written into REQ-001, REQ-002.

### AI updated the requirements · 2026-11-04

DEC-005 written into REQ-003.

### AI · 2026-11-04

Implementation started. Checked before building: Q-001…Q-004 (answered), DEC-001…DEC-005 (accepted), F-001…F-003 (resolved, DEC-003/004/005), the Layout answer in this discussion, REQ-001…REQ-005 (approved). SRC-002 (markview-v10.zip) was unpacked and compared file by file with docs/prototypes/markview/site: index.html, styles.css, data.js, seed.js, app.js and both screens are byte-identical, so the repository prototype v10 is the archive's prototype and the earlier note that the ZIP could not be matched no longer applies. Left open by the specification and settled for the implementation as proposed decisions: the Markdown representation and edits outside the map (DEC-006), the seven layouts (DEC-007), research depth, stop criteria, failure and continuation (DEC-008), the map view inside the editor tab and the bridge protocol (DEC-009). Two non-blocking questions where the prototype SPEC says "not defined": Q-007 (line colour follows node colour; built as A) and Q-008 (remove a single logical connection; built as A).
