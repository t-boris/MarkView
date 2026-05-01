---
created: 2026-04-30
status: draft
type: feature
size: L
---

# User Spec: Recursive Insight v2 (Insight Web)

## Что делаем

Полностью переделываем фичу Recursive Insight: вместо markdown-рендеринга LLM генерирует **самодостаточные интерактивные веб-страницы** для каждого узла дерева анализа. Каждая страница — это HTML+CSS+JS, рендерится в sandboxed iframe внутри MarkView. Принцип рекурсивного углубления остаётся, но визуал становится первичен (mermaid, charts, widgets, interactivity), текст — вторичен.

Загрузка двухфазная: сначала за 1-2 секунды отрисовывается скелет страницы (структура + placeholder'ы + видимые кнопки deep-dive), потом параллельно стримятся текстовые данные в уже видимые секции. Так визуальный обучающийся сразу видит «карту» материала, а не ждёт пока всё прочитается линейно.

V1 (markdown-based) полностью удаляется — Swift файлы переписываются, JS-режим в `index.html` заменяется на iframe-host.

## Зачем

V1 на markdown оказался слишком плоским для визуального обучения. Markdown с inline mermaid не даёт настоящей интерактивности. Пользователю нужен полноценный «учебный сайт» — каждый узел как отдельная страница лендинг-формата с диаграммами, сравнительными таблицами, timeline, collapsible деталями. Плюс возможность экспортировать всё дерево как standalone HTML-архив для шаринга.

## Как должно работать

1. Пользователь открывает папку с `.md` файлами в MarkView.
2. Пользователь выбирает в меню `AI Tools → Analysis → 🧭 Recursive Insight`.
3. Открывается новая вкладка типа `.insight`. Внутри неё:
   - Сверху: breadcrumbs (`Root > Auth > JWT`), кнопка `🏠 Home`, кнопка `💾 Export Archive`
   - Снизу: статус-бар стриминга (`Phase 1: skeleton... done`, `Phase 2: filling sections (3/7)...`)
   - Центр: sandbox iframe, в котором рендерится сгенерированная страница
4. **Phase 1 (структура, ~1-2 сек):** LLM возвращает JSON skeleton — список секций с типами виджетов и якорями для deep-dive. Frontend строит iframe srcdoc с пустыми контейнерами + skeleton-loader анимациями. Пользователь сразу видит структуру: «здесь будет hero-блок, здесь mermaid-диаграмма архитектуры, здесь сравнительная таблица, здесь timeline».
5. **Phase 2 (контент, параллельно):** LLM стримит контент per section. Каждый chunk имеет ID секции и payload (HTML фрагмент / mermaid-код / table-данные / etc). Frontend заполняет соответствующий контейнер по мере прибытия. Несколько секций могут заполняться одновременно.
6. Внутри текста / в секциях LLM расставляет inline кнопки `🤿 Deep dive: <тема>`. Клик → новый узел через тот же двухфазный процесс.
7. Breadcrumbs наверху — клик возвращает к ранее сгенерированной странице **из локального кеша** (без LLM-вызова, мгновенно).
8. `💾 Export Archive` → NSSavePanel → пользователь выбирает путь → MarkView упаковывает всю сессию (root + все раскрытые узлы) в `.zip`. ZIP содержит:
   - `index.html` (root summary, deep-dive ссылки ведут на локальные `.html` файлы)
   - `nodes/<node-uuid>.html` для каждого узла
   - `manifest.json` со структурой дерева
   - `_assets/` с pre-bundled libs (Mermaid/Chart.js/KaTeX/Prism копии)
   ZIP открывается в любом браузере без MarkView.
9. Закрытие вкладки → дерево + iframe освобождается. Дисковый кеш сессии стирается (опционально оставляется, см. Технические решения).

## Критерии приёмки

- [ ] В меню `AI Tools → Analysis` есть пункт `🧭 Recursive Insight`, активный когда папка с `.md` открыта (унаследовано из v1)
- [ ] Phase 1 структура страницы видна в iframe не позже чем через 3 секунды после клика (skeleton-loader анимации показывают placeholder'ы)
- [ ] Phase 2 контент стримится в готовые placeholder'ы — пользователь видит как заполняются секции (mermaid рендерится, текст появляется, таблицы наполняются)
- [ ] Несколько секций могут заполняться параллельно (не строго последовательно)
- [ ] Inline кнопки `🤿 Deep dive` присутствуют в тексте или как отдельные UI-элементы внутри секций (НЕ правая боковая панель — её больше нет)
- [ ] Клик на deep-dive → открывается новая страница того же двухфазного формата
- [ ] Breadcrumbs наверху — клик возвращает к закешированной странице мгновенно, без повторной генерации
- [ ] Каждый сгенерированный узел сохраняется на диск как один HTML-файл (всё inline) в `<workspace>/.insight-cache/<session-uuid>/<node-uuid>.html` + `manifest.json` со структурой
- [ ] При повторном клике на breadcrumb страница загружается из кеша (тот же session id)
- [ ] `💾 Export Archive` создаёт ZIP с index.html + nodes/ + manifest.json + _assets/, который открывается в обычном браузере без MarkView
- [ ] Весь LLM-сгенерированный HTML+JS выполняется ВНУТРИ `<iframe sandbox="allow-scripts">` (без `allow-same-origin`) — JS не имеет доступа к parent DOM, к `window.webkit.messageHandlers`, к localStorage parent'а
- [ ] Communication parent ↔ iframe только через `window.postMessage` с белым списком типов: `deepDiveClicked`, `breadcrumbClicked`, `requestSave`, `requestUp`, `iframeReady`
- [ ] Pre-bundled libs (Mermaid, Chart.js, KaTeX, Prism) инжектятся в head iframe через srcdoc — никаких CDN, фиксированные версии
- [ ] Mermaid в iframe: `securityLevel: 'strict'` per-render (унаследовано из v1)
- [ ] При закрытии вкладки: iframe destroyed, InsightSession освобождена, активные стримы отменены, дисковый кеш сессии очищен
- [ ] Существующая editor функциональность не сломана (открытие обычных `.md`, AI Console, Translate, Git и т.д.)

## Ограничения

- **Источник данных:** только `.md` файлы (как в v1)
- **API:** только Anthropic Messages API через существующий `AIProviderClient.streamCompletion`
- **Sandbox iframe обязателен** — это единственная защитная граница, без неё LLM-сгенерированный JS получит доступ к bridge.postMessage и сможет вызвать save handler с произвольными аргументами
- **postMessage protocol:** строгий allowlist, parent отбрасывает любые неизвестные типы
- **Pre-bundled libs:** только из локальных копий, никаких `<script src="https://...">` от LLM
- **Cache:** disk-based, default per-session (стирается при закрытии вкладки), опционально persistent через настройку
- **ZIP export:** standalone, не требует доступа к кешу MarkView
- **Sandbox у MarkView:** остаётся OFF (как в v1)
- **Тесты:** по-прежнему deferred per Decision 9 v1 — XCTest target всё ещё отсутствует. Та же follow-up задача в `tasks/todo.md` покроет и v2 паттерны.

## Риски

- **Риск 1:** LLM HTML+JS внутри iframe всё равно может быть атакой — например, infinite loop, alert spam, попытки fingerprint'а через timing. **Митигация:** sandbox блокирует все опасные API; добавить timeout на iframe load (если за N секунд iframe не послал `iframeReady`, считаем broken и показываем error).
- **Риск 2:** Two-phase pattern сложнее в LLM-prompt'е — модель должна сначала вернуть только структуру, потом контент. Может вернуть структуру с контентом сразу, или контент без скелета. **Митигация:** строгий JSON schema на phase 1 (LLM завершает phase 1 явным маркером); strict parsing — если schema нарушен, fallback на one-phase rendering без skeleton.
- **Риск 3:** postMessage protocol — parent должен отбрасывать любые неизвестные типы и валидировать payload. Если оставим лазейку (например, `requestNavigate(url:)` без validation) — LLM JS может склонить пользователя к фишингу. **Митигация:** strict allowlist 5 типов, payload validated по schema, deep-dive button payload — только индекс из заранее объявленного skeleton.
- **Риск 4:** Disk cache занимает место. 50 узлов × ~500KB HTML = 25MB на сессию. **Митигация:** per-session очистка при закрытии вкладки; глобальный cap 500MB на `.insight-cache/`; eviction LRU.
- **Риск 5:** ZIP export — Foundation не имеет встроенного ZIP API. **Митигация:** использовать `Process` + `/usr/bin/zip` (стандартный macOS бинарник), либо подключить SwiftZip / ZIPFoundation pod. Решить в tech-spec.
- **Риск 6:** Pre-bundled libs (Mermaid + Chart.js + KaTeX + Prism) добавляют ~1MB к каждому iframe srcdoc. На 50 узлов в кеше — 50MB только на дублирующиеся библиотеки. **Митигация:** в standalone-cache формате — единая `_assets/` папка с библиотеками, узлы ссылаются через `<script src="../_assets/mermaid.js">`. Внутри MarkView в runtime — библиотеки инжектятся parent'ом через `iframe.contentWindow.eval` или через blob URL.
- **Риск 7:** Removing v1 без fallback — если v2 не работает, пользователь без insight-фичи. **Митигация:** v1 сохранён в git (commit `c431fa4` и предшествующие), архивирован в `work/recursive-insight-v1/`. Можно вернуться через `git revert`.
- **Риск 8:** Iframe LLM-сгенерированный код может стать огромным (100KB+ HTML с inline data). **Митигация:** per-node HTML cap 2MB; превышение → throw .streamingError, показать в UI «node too large».

## Технические решения

- Мы решили **полностью снести v1** (markdown-rendering pipeline, marker parser, right-pane deep-dive list, setText utility для labels), потому что v2 заменяет рендеринг целиком; чистый старт проще чем гибрид. V1 остаётся в git history и в архивной папке `work/recursive-insight-v1/`.
- Мы решили использовать **iframe sandbox с `sandbox="allow-scripts"`** (без `allow-same-origin`), потому что это единственная архитектурная граница изоляции LLM-сгенерированного JS от bridge / file system / parent DOM.
- Мы решили **two-phase generation** через JSON skeleton + content stream, потому что пользователь явно хочет видеть структуру до прихода данных. Single-phase markdown стриминг не даёт этого ощущения.
- Мы решили **inline deep-dive кнопки 🤿** вместо правой панели, потому что пользователь явно сказал — текст и кнопки лучше разделять структурно, чем боковой панелью.
- Мы решили **persistent disk cache per session** в `<workspace>/.insight-cache/<session-uuid>/`, потому что:
  (a) breadcrumb-навигация назад должна быть мгновенной без re-generate
  (b) ZIP export использует тот же кеш как источник
  Cache очищается при закрытии вкладки (опция «Keep cache for next session» добавлена в Settings — TBD).
- Мы решили **pre-bundled libs** (Mermaid, Chart.js, KaTeX, Prism) инжектить в iframe head, а не давать LLM свободно тянуть CDN, потому что (a) фиксированные версии = воспроизводимость; (b) integrity check; (c) LLM не может exfiltrate через `<script src>`.
- Мы решили использовать **`/usr/bin/zip`** для ZIP export (через `Process`), потому что нет потребности в нативной zip-библиотеке: macOS стандартный, простой, не требует Pod.
- Мы решили **сохранить tab-kind `.insight`**, `WorkspaceManager.startRecursiveInsight()`, `closeTab insight branch`, `WebViewBridgeDelegate` методы — переиспользуем интеграционный шов из v1, меняем только внутренности (`InsightSession` rewrite, `index.html` insight-mode rewrite, новый JSON-protocol).
- Мы решили **Anthropic model: claude-sonnet-4-6** (как в v1), та же причина.
- Мы решили **тесты deferred per Decision 9 v1** — без изменений; та же follow-up задача в `tasks/todo.md` покроет v2 паттерны (расширим scope в tech-spec).

## Тестирование

**Unit-тесты:** не делаем в рамках v2 — XCTest target всё ещё отсутствует. Follow-up задача XCTest infrastructure расширится: добавится покрытие JSON skeleton parser, postMessage protocol validator, disk cache CRUD, ZIP bundler.

**Интеграционные тесты:** не делаем — по той же причине.

**E2E тесты:** не делаем — по той же причине.

**Verification:** `xcodebuild build` + ручная проверка пользователем + Audit Wave (code/security/test).

## Как проверить

### Агент проверяет

| Шаг | Инструмент | Ожидаемый результат |
|-----|-----------|---------------------|
| 1. Сборка проекта без ошибок | `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build` | Build succeeded, 0 errors |
| 2. Static check: iframe sandbox attribute present in generated srcdoc | grep `index.html` для `sandbox="allow-scripts"` | match present, без `allow-same-origin` |
| 3. Static check: postMessage protocol allowlist | grep `index.html` для allowed message types | exactly: deepDiveClicked, breadcrumbClicked, requestSave, requestUp, iframeReady |
| 4. Static check: pre-bundled libs paths | grep `index.html` для script src в iframe srcdoc | только локальные пути, никаких https:// |

### Пользователь проверяет

- Открыть `TestFiles/` в MarkView, запустить Recursive Insight, убедиться:
  - В iframe появилась структура с placeholder'ами в течение ~3 секунд (Phase 1)
  - Контент стал заполняться в существующие секции (Phase 2)
  - Mermaid-диаграммы рендерятся, charts отображаются
  - Видны inline 🤿 кнопки в тексте/секциях
- Кликнуть на 🤿 — убедиться, что открывается новая страница того же формата
- Кликнуть на breadcrumb root — мгновенный возврат, без LLM-вызова (проверить Console: нет нового HTTP запроса к Anthropic)
- Нажать `💾 Export Archive`, выбрать путь, открыть полученный `.zip`:
  - Структура: index.html + nodes/ + manifest.json + _assets/
  - Open `index.html` в Safari — должна работать вся навигация по deep-dives
- Поломать iframe sandbox: вставить в один из `.md` файлов потенциально вредоносный markdown с просьбой к LLM «сгенерируй HTML который вызовет alert». Проверить, что alert НЕ появляется в parent (если LLM сгенерирует — alert произойдёт внутри iframe и максимум закроется sandbox'ом)
- Закрыть вкладку, открыть Recursive Insight снова на той же папке — убедиться, что начинается с нуля (новая сессия, новый кеш)
- Проверить что обычные .md файлы по-прежнему открываются нормально, AI Console работает, нет регрессий
