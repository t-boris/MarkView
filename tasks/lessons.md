# Lessons

## 2026-09-26 — Write to a PTY: EAGAIN means "later", not "stop"

**Context:** BUG-002. `TerminalSession.write()` wrote to a non-blocking PTY master and stopped at the
first `write` ≤ 0. macOS takes only about 1 KB of input at a time, so every prompt over 1 KB was cut
at 1022 bytes. The closing `ESC[201~` was lost, and Enter was swallowed by the unclosed paste.
Every AI Tools item then "did nothing". The code looked fine for short keystrokes.

**Rule:** Every write to a non-blocking descriptor has an owner for the unsent part: keep it in order
and finish on a write source (retry EINTR, wait on EAGAIN), never on the main thread by blocking. To
reproduce terminal input bugs, use a standalone forkpty harness with the exact write code and a
slow reader or the real CLI. Count the bytes accepted instead of guessing from the screen.

## 2026-09-26 — Автоматическая фиксация: проверять на реальных данных и реальном процессе

**Контекст:** Lifecycle log: «spec ready» ждал статус `ready`, который приложение никогда не
ставит (Create issues переводит review → implementing). «Implement with AI» не писал событие.
Слежение за merge строилось на PR, а в этом репозитории коммитят прямо в main без PR.

**Правило:** Для каждого автоматического триггера найти код, который реально производит этот
переход (grep по значению статуса/действию), и проверить на живых данных (лог событий, `git log`,
`gh`), что событие появилось бы. Действие пользователя, запускающее этап (кнопка), само пишет
событие; модель брать из того, что CLI фактически использовал, а не из настроек.

## 2026-09-26 — Прогресс не виден, если вид не наблюдает объект с состоянием

**Контекст:** Карточки Feature читали `store.assistant.isRunning` через вычисляемое свойство, но
наблюдали только `FeatureStore`. SwiftUI не перерисовывал их при изменении `running` в
`FeatureAssistant` — спиннер не появлялся, карточка менялась только с готовым результатом.
Прошлая правка («помечать шаг сразу») ничего не дала по той же причине.

**Правило:** Вид, который показывает состояние объекта, наблюдает именно его
(`@ObservedObject` / `@EnvironmentObject`). Любое нажатие дольше ~0.5 с — сразу видимый
прогресс (что именно происходит), без ожидания подготовки запроса или сети.

## 2026-09-26 — Долгоживущие вещи не держать в @StateObject вида, который пропадает

**Контекст:** Голосовая запись (WhisperClient) жила в `@StateObject` кнопки микрофона.
Переключение вкладки уничтожало вид (терминал под редактором, вкладки правой панели) → запись
обрывалась, текст терялся. Все записи писали в один временный файл.

**Правило:** Запись, стрим, процесс — во владении модели (сессия терминала, движок), вид только
наблюдает (`@ObservedObject`). Временные файлы — уникальные, удалять после использования.

## 2026-09-26 — Файлы, которые правит и пользователь, и приложение: читать с диска перед записью

**Контекст:** Ревью Feature workspaces: `update()` писал закэшированную копию (правка
пользователя в редакторе терялась), фоновая перезагрузка приносила устаревший список и новый
объект получал уже занятый номер — `write(atomically:)` молча перезаписывал файл; перезапись
front matter теряла комментарии и блочные значения.

**Правило:** Read-modify-write всегда с диска в момент изменения; новые файлы — только
`.withoutOverwriting` и номер выше всех имён на диске; фоновые чтения со счётчиком поколений;
YAML, который нельзя переписать без потерь, не переписывать (сообщить).

## 2026-09-26 — Содержимое .toolbar не получает environmentObject окна

**Контекст:** 2.0.1 падал при запуске: `AIToolsMenu` в `.toolbar` читал
`@EnvironmentObject WorkspaceManager`, а `WorkspaceManager` — `@StateObject` в `ContentView`, в
окружение панели инструментов он не попадает (EnvironmentObject.error → SIGTRAP).

**Правило:** Виды внутри `.toolbar` получают объекты параметром (`@ObservedObject`), как
`AssistantToolbarMenu` работает только с `@AppStorage`. После изменений панели инструментов —
запустить собранное приложение, сборка этого не ловит.

## 2026-09-26 — Файл вне папки проекта переключает рабочее пространство

**Контекст:** `openFile` для `.md` вне корня папки вызывает `initSingleFileWorkspace`: закрывает
базу, останавливает терминалы, Git смотрит в другую папку. Копии файлов PR лежат в кэше вне
проекта — открытие такого `.md` из PR X-Ray давало «Initialize Git Repo» в репозитории с git.

**Правило:** Любой файл, который приложение само кладёт вне проекта (кэш PR, временные копии),
должен распознаваться как часть открытого проекта (`isFileInCurrentWorkspace`). Проверять
открытие `.md` из таких мест.

## 2026-09-26 — PR X-Ray: файл — лист; изменения внутри видны только в открытом файле

**Контекст:** PR X-Ray рисовал внутри файлов узлы изменений (конкретные строки). Пользователь:
это не то — в X-Ray нужны файлы/структура; клик по файлу открывает файл, и уже там видно каждое
изменение с объяснением «почему». Удалённые файлы тоже должны открываться.

**Правило:** В X-Ray (включая PR) не рисовать содержимое файла; детали изменения — в
просмотрщике файла (линза Pull request). В PR X-Ray клик по файлу сразу открывает его.

## 2026-09-26 — Интеграции опциональны: MarkView может быть просто Markdown-viewer

**Контекст:** Во время реализации GitHub-интеграции пользователь напомнил: приложение можно
открыть на одном файле без папки, и оно должно оставаться обычным Markdown-viewer.

**Правило:** Любая интеграция (GitHub и т.п.) — opt-in переключатель в Settings (по умолчанию
выключен) и работает только при открытой папке. Выключена → ни одного вызова `gh`, никакого
опроса, существующий UI не меняется.

## 2026-09-25 — Новую возможность встраивать в существующий инструмент, а не строить рядом

**Контекст:** Пользователь просил «custom filter» — искать по теме и видеть подсвеченным только
нужный код. Я сделал отдельную панель «Topic / AI Search» слева, кнопку в тулбаре и отдельную линзу
в коде. Пользователь: «Ты неправильно сделал. Я хотел внутри X-Ray сделать search… это не более
того, как обычный фильтр… убери весь этот UI».

**Ошибка:** Слово «фильтр» в запросе указывало на уже существующий механизм (фильтры X-Ray с
⚡ Quick AI filter). Я не сверил, какой существующий UI имеется в виду, и изобрёл новый.

**Правило на будущее:**
- Если в запросе звучит название существующей вещи («фильтр», «панель», «линза»), сначала найди
  её в коде и предложи расширить именно её. Новая панель/кнопка — только после явного согласия.
- Перед реализацией UI-фичи коротко опиши, *где* она появится («в X-Ray, в поле ⚡ фильтра»), и
  получи подтверждение, если есть хоть малейшая неоднозначность.
- Результат поиска показывать так, как пользователь описал визуально (здесь: «подсвечивает красным
  только важное»), а не своей схемой шагов/цветов.

## 2026-05-31 — Зависший UI: снимай sample стека, не гадай

**Контекст:** Пользователь повторял «висит». Я последовательно гадал: индексация →
WebView (mermaid 2.9MB) → миграция БД. Каждый раз тратил циклы на неверную гипотезу.
Реальная причина нашлась за один `sample <pid>`: главный поток на 100% стоял в
`GitClient.refresh() → run() → Process.waitUntilExit()` — git выполнялся СИНХРОННО на
главном потоке при открытии папки, плюс чтение pipe ПОСЛЕ `waitUntilExit` → дедлок при
выводе git > 64KB (`git status` на 1200+ файлах).

**Правило на будущее:**
- «Висит/beachball» → СРАЗУ `/usr/bin/sample <pid> 3` (или spindump) и смотри thread 0.
  Стек точно покажет блокирующий вызов. Не гадай по коду.
- `ps -o %cpu,state`: 0% CPU + state S = заблокирован на ожидании (lock/IPC/waitUntilExit),
  а не крутит цикл. Высокий CPU = busy-loop/тяжёлые вычисления. Это сужает поиск.
- НИКОГДА не вызывай `Process.waitUntilExit()` на главном потоке. И всегда читай pipe ДО
  (или конкурентно с) waitUntilExit — иначе переполнение 64KB-буфера = вечный дедлок.
- Утилиты `log`, `sample` перехвачены функцией/обёрткой miniconda в zsh-профиле —
  использовать полный путь `/usr/bin/log`, `/usr/bin/sample`.


## 2026-05-30 — Диагностика перформанса: сначала факты, потом гипотезы

**Контекст:** Жалоба «MarkView очень долго грузится при старте». Я сразу полез читать
`index.html`, нашёл mermaid.min.js 2.9 MB и CDN-скрипты, и предложил lazy-load JS.
Пользователь дважды поправил: «дело не в парсинге» и «больше 5 минут грузится».

**Ошибка:** Построил гипотезу (парсинг JS) из чтения кода, не сверив с **масштабом
симптома**. 2.9 MB JS парсится ~1–2 с — это физически не может давать 5 минут. >5 минут =
зависание/блокировка, а не стоимость вычисления.

**Правило на будущее:**
- При жалобе на перформанс СНАЧАЛА получить число/масштаб (секунды? минуты?) и **прочитать
  логи с таймстампами**, и только потом строить гипотезу. Здесь логи (`~/markview_debug.log`)
  сразу показали бы провал во времени после `structural index started`.
- Сверять порядок величины: предполагаемая причина должна объяснять НАБЛЮДАЕМЫЙ масштаб.
  Парсинг → секунды; сетевой таймаут/блокировка main-потока/per-item sync → минуты.
- Реальная причина: `StructuralIndexer` делал 3 обхода дерева + `DispatchQueue.main.sync`
  на каждый из 1222 файлов на занятом main-потоке.

## 2026-05-30 — Process.terminationHandler требует удержания Process

**Контекст:** Вынес индексацию в отдельный процесс. `Process` создавался как локальная
переменная; после выхода из функции объект освобождался → `terminationHandler` не срабатывал
(ОС-процесс при этом нормально отрабатывал). Сначала удержал в instance-property, но в
приложении создаётся НЕСКОЛЬКО `WorkspaceManager` (несколько окон/ghost windows), и property
умирал вместе с временным экземпляром.

**Правило:** Для fire-and-collect дочерних процессов удерживать `Process` в **процесс-wide
(static)** коллекции до вызова terminationHandler, не в instance-state короткоживущего объекта.
Логировать на входе в handler через nonisolated-путь (handler выполняется вне `@MainActor`),
чтобы отличать «handler не вызвался» от «self уже nil».

## 2026-09-03 — Хардкод абсолютных путей к внешним CLI

**Контекст:** Пользователь сообщил, что Codex перестал работать. Причина: в
`AIConsoleEngine` путь был константой `"/opt/homebrew/bin/codex"`, а реальный бинарник
стоял через npm/nvm — `~/.nvm/versions/node/v22.22.3/bin/codex`. При этом `PATH` для
подпроцессов тоже был литералом без nvm-путей. Ошибка выглядела как «ничего не
происходит»: `process.run()` кидал непрозрачный NSError, и в UI не было ни причины,
ни способа исправить.

**Правила:**
- Никогда не хардкодить абсолютный путь к стороннему бинарнику. Порядок разрешения:
  явный override из настроек → скан кандидатов (включая **все** `~/.nvm/versions/node/*/bin`)
  → `command -v` через login-shell. Путь к node-CLI меняется при каждом обновлении Node.
- Любая интеграция с внешним инструментом должна быть **перенастраиваемой из UI**.
  Если пользователь не может починить её сам — это дефект дизайна, а не «конфиг».
- Ошибка «не найдено» обязана называть: что искали, где искали и куда идти чинить.
  Молчаливый отказ хуже, чем краш.
- У CLI обычно есть дешёвая неинтерактивная проверка авторизации — использовать её,
  а не тратить токены пробным запросом: `claude auth status` (JSON, поле `loggedIn`),
  `codex login status`.
- Логин в CLI требует TTY/браузер. Открывать Terminal через исполняемый `.command`-файл
  и `NSWorkspace.open`, а не через `NSAppleScript` — иначе нужны Apple Events
  и `NSAppleEventsUsageDescription`.

**Сопутствующее:** там же нашёлся лог первых 20 символов API-ключа в
`~/markview_debug.log` (`DDESettingsView.onAppear`). Логировать только факт наличия
и длину — никогда никакую часть ключа.

## 2026-09-17 — Fire-and-forget notifications lose requests during startup

**Context:** Finder "Open With" never opened anything. `application(_:open:)` posted a
NotificationCenter message; the receiving `ContentView` filtered by `hostWindow`,
which `WindowAccessor` sets on the *next* run-loop turn. On delivery every window
rejected it and the request vanished. The fallback only covered "no visible window",
but SwiftUI shows the window before delivering the open event.

**Rules:**
- An external request (open URL, deep link) must be stored in a durable queue and
  drained by the receiver; the notification is only a "check the queue" signal.
- Drain at every moment the receiver may become eligible (signal, window attached,
  window becomes key), not just once.
- Don't branch on "is a window visible" at open time — SwiftUI's ordering of
  window creation vs. `application(_:open:)` is not something to rely on.
- Verify with `open -n -a <DerivedData app> <path>` and the debug log; one grep for
  "was it ever handled" (count = 0) proved the bug in seconds.

## 2026-09-24 — Don't drive UI in the user's live app instance

**Context:** To verify "Close Folder" I ran `install.sh` (which relaunches
/Applications/MarkView.app) and clicked the menu item via System Events. On relaunch
the app had reopened the user's own workspace (`vivaa-platform/docs`) in the key
window, so the scripted click closed the user's real folder and tabs instead of the
test fixture.

**Rules:**
- UI automation runs against the Debug build in /tmp/MarkViewDerivedData, never the
  installed app the user is working in.
- Before a scripted action, confirm which window/folder is key (debug log or window
  title); abort if it is not the fixture I opened.
- Destructive UI actions (close, delete, discard) are for the user to try, not me.

## 2026-09-24 — Menu commands don't observe objects behind @FocusedValue

**Context:** "Close Folder" used `.disabled(activeWorkspace?.rootNode == nil)`, where
`activeWorkspace` is `@FocusedValue(\.workspaceManager)`. The user reported it
permanently disabled. `Commands` re-evaluate only when a focused *value* changes; the
WorkspaceManager reference is the same object before and after the folder loads
asynchronously, so the item froze in whatever state it had when the window took focus.
I had even seen the reverse symptom (still enabled after close) and wrote it off as
cosmetic.

**Rules:**
- Menu enabled/checked state must come from a value-typed focused value
  (`.focusedSceneValue(\.someBool, ...)`), not from properties of a focused object.
- A stale menu state in either direction is the same bug — fix it, don't document it.

## 2026-09-24 — Range deletes by marker: list what's inside first

**Context:** Removing `analyzeAllFiles` I cut from its doc comment to the next known
marker (`/// Load ALL entities…`). Eight live functions (diagram prompts,
`refreshSemanticViews`, `navigateToText`) sat in between; the build broke and I had to
restore them from HEAD.

**Rule:** before deleting a span between two markers, print the `func`/`struct`
declarations inside it and confirm every one is meant to go. Prefer brace-matched
deletion of a single declaration over marker-to-marker cuts.
The same holds for deleting a whole file: `EntityGraphView.swift` also held
`MarkdownContentView`, which the AI console renders with. List every top-level
declaration in a file and grep each one before `git rm`.

## `defer` in a Task does not release a flag before chained work
- `scan()` used `defer { busy = false }` and called `analyze()` at the end of the same Task. The defer had not run yet, so `analyze()` hit `guard !busy` and silently did nothing: the first automatic AI analysis never started.
- Rule: when a job chains into another job guarded by the same flag, clear the flag explicitly right before the chained call. Don't rely on `defer`, and never let a later `defer` clear a flag the chained job has set.

## New columns need a migration, not just CREATE TABLE
- `arch_nodes` gained columns while databases created by an earlier build already had the table. `CREATE TABLE IF NOT EXISTS` skipped it, so INSERT/SELECT failed with "no column named component".
- Rule: whenever a column is added to an existing table, also call `addMissingColumns` (ALTER TABLE ADD COLUMN) in `createTables`, and test on a copy of an old database.

## Codex "error" events are not always fatal
- `codex exec --json` reports warnings (e.g. "Model metadata … not found") as `{"type":"error"}` and API failures as raw JSON inside `message`. Only `turn.failed` ends a run.
- Rule: record `error` events and use them only to explain an empty answer; unwrap the nested `error.message` before showing it. Test model choices with a real `codex exec` call, since the catalog can list models the account cannot use.

## Verify editor UI in WebKit, and never let `display` override `hidden`
- The notes panel could not be collapsed: `.code-notes { display: flex }` beats the UA `[hidden] { display: none }`, so ✕ did nothing. Chrome checks missed it because ✕ was never exercised, and the app runs WKWebView, not Chrome.
- Rule: every element toggled with `hidden` whose CSS sets `display` needs an explicit `[hidden] { display: none }`. When a library styles the element with `!important` (CodeMirror's `.cm-editor` is `display: flex !important`), the `[hidden]` rule needs `!important` too — otherwise two viewers show at once. Check interactions (drag, close, reopen) in real WebKit: a small Swift program with an off-screen WKWebView that loads the editor from a local server and dispatches the events, not only in Chrome.

## Confirm which panel the user means before fixing it
- "The explanation panel doesn't resize" meant the X-Ray details panel (descriptions, Component list), but I fixed the code-notes panel. The user had to repeat it several times.
- Rule: when a report names a UI element loosely ("the panel", "explanations"), match it to the screen the user is on (X-Ray, code, docs) and name the element back ("the X-Ray details panel on the right"). If two readings are plausible, fix both or ask.
- Also: a flex item holding a canvas needs `min-width: 0` (or `overflow: hidden`), or it grows to the canvas width and pushes side panels off-screen.

## Never use `git stash` to compare before/after
- I ran `git stash push <file>; …; git stash pop` to time an old version. The file was untracked, so nothing was stashed — and `pop` would have applied someone else's older stash to a working tree with 70+ uncommitted files.
- Rule: to compare versions, build the old code from a copy (`git show HEAD:path > /tmp/...`) or a separate worktree; never stash in the user's working tree.

## New files in Resources/Editor are not bundled automatically
- The "Build Web Editor" pre-build script copies only listed files (`index.html`, `terminal.html`, `vendor/`). A new top-level page must be added to that script in both `project.yml` and `project.pbxproj`, or `Bundle.main.url(...)` returns nil and the web view stays blank with no error.
- Check with `ls <App>/Contents/Resources/Editor/` after building.

## Never restart the user's running MarkView
- `install.sh` and `release.sh --install` quit and kill the running app; Boris works in it (live terminal sessions). Build into /tmp/MarkViewDerivedData or `./release.sh` (no `--install`) and let him install when he chooses.

## Nodes inside files break "leaf = file" assumptions in the X-Ray JS
- Overlays, PR highlighting and tag hiding collect `descendantsFiles` (leaves). Once files got children (contents, PR changes) a file stopped being a leaf and was dimmed/uncounted. A file is the aggregation boundary: stop at `kind === 'file'`; inner kinds inherit their file's overlay.

## A loaded diff goes stale while the user keeps working
- The PR X-Ray showed a diff taken before a later commit, so lines no longer matched the file. Any view that overlays a diff on a file must either show the diff's own version of the file or map lines by content, and local changes must be re-read when they move on.

## JSONSerialization numbers 0 and 1 are also Bool
- The usage parser skipped Bool values with `value is Bool`; `NSNumber` 0 and 1 match that, so
  "0%" and "1%" windows vanished. Only the tests on real response shapes caught it.
- Rule: tell booleans from numbers with `CFGetTypeID(number) == CFBooleanGetTypeID()`, never `is Bool`.

## Scanning large files: read in chunks and drain the autorelease pool
- The first scan of ~650 MB of agent logs peaked at 1.18 GB: whole files were read at once and
  every `JSONSerialization`/`FileHandle` object stayed in the thread's autorelease pool until the
  scan ended. Chunks of 8 MB, each inside `autoreleasepool {}`, brought it to 92 MB.
- Rule: any loop over many files or lines that creates Foundation objects runs its body in
  `autoreleasepool`; measure peak memory with `/usr/bin/time -l` on real data.


## Launch tests must never touch the user's MarkView (2026-09-26)
- Mistake: the launch test compared against a PID remembered from an earlier turn (48496); the user had restarted MarkView meanwhile (71011), so the test killed the user's app.
- Rule: collect the running PIDs in the same command, immediately before `open -n`, and kill only a process whose executable path is `build/release/MarkView.app` (check `ps -o command=`), never by "not in an old list".

## 2026-09-26 — Cancel must reach async callbacks; insert only into the field's own window

**Context:** Review of the intake dictation: the microphone permission callback started recording
after the user had cancelled (the mic stayed on, the WAV leaked); the transcript was inserted
into whatever text view was first responder in the key window, including another window's
API-key field.

**Rule:** Anything started behind a prompt or callback captures a generation and does nothing if
it changed. Text produced later is inserted only into the originating window's first responder
(captured when the action started), otherwise appended to the field's own binding.


## 2026-09-26 — Terminal OSC 8 and plain URLs have different activation paths

WebLinksAddon handles regex URLs; xterm's OSC 8 provider uses Terminal.options.linkHandler.
Without that handler it calls browser confirm/window.open, which WKWebView without a
WKUIDelegate cannot display. Test both paths in native WebKit. Link activation on xterm's
screen can also bubble into PTY mouse reporting in a TUI: reserve Cmd+click at the screen
bubble phase after the linkifier, retaining ordinary TUI mouse events. Resolve relative file
links against the live foreground/shell cwd, not only the folder where the terminal started.

## Terminal escape-sequence tests must use the emitter's real encoding (2026-09-26)

BUG-001 tests covered only ST-terminated OSC 8 (`ESC \`). Claude Code (Ink/ansi-escapes)
ends OSC 8 with BEL and other tools add `id=` params. When reproducing a terminal bug reported
against a specific program, replay that program's exact byte shape (terminator, params, SGR styling,
alternate screen, mouse mode). Also run the new check against the pre-fix page to prove it catches the bug.

## Never edit a text view and its `inout` binding in the same call (BUG-003, 2026-09-26)
- Dictation inserted the transcript through `NSTextView.insertText` inside a function that took the
  field's text as `inout String`. The view updated the `@State`, then the `inout` write-back restored
  the old text: the text flashed in and vanished, with no error. It was misread for hours as a
  microphone/recording problem, because the logs had no public messages (NSLog shows `<private>`).
- Rule: an edit goes to exactly one owner, the binding. Read the cursor from the view if needed, but
  never mutate the view. To reproduce a UI bug without Accessibility access, run a Developer ID-signed
  copy from a worktree with stderr tracing next to the user's app and have the user click. Trace
  every step through to the final state, not just the part you suspect.

## HSplitView ignores idealWidth; don't run xcodegen on this project (2026-09-26)
- A pane given `idealWidth: savedWidth` opened at 199 or 600 px, depending on the window: SwiftUI `HSplitView`
  divides the space itself. Restoring a width needs the underlying `NSSplitView.setPosition(_:ofDividerAt:)`
  after the first layout (`LeftPanelWidthKeeper`). Don't save widths from before that restore, because they come from layout passes.
- `xcodegen generate` rewrote every ID in `project.pbxproj` (870 lines). Add new files by hand, as was done for
  PTYWriter.swift, and keep `project.yml` aligned.
- A UI can be checked without touching the user's app: build with `PRODUCT_BUNDLE_IDENTIFIER=<other>` (separate
  defaults), seed its defaults, and read rows via `osascript` System Events (`help` of row buttons).

## @AppStorage is app-wide: per-window UI state must not use it (BUG-004, 2026-09-27)
- The right panel tab, left panel mode, open issue, Git section and feature stage were `@AppStorage`. That is one
  UserDefaults value observed by every window, so a tab switched in one window switched in all of them.
- Rule: state that describes what one window shows lives in that window's model (`WorkspaceManager.layout`,
  `PanelLayout`). UserDefaults is only its seed for the next window and relaunch. Keep `@AppStorage` for preferences
  that all windows should share (theme, model, API settings).
- Driving a test copy through AppleScript: `process whose unix id is N` resolves back to
  `application process "MarkView"` by NAME, so it reaches the user's installed app, not the copy. Use the AX API
  directly (`AXUIElementCreateApplication(pid)`, small swiftc helpers) to address the copy by PID only.
## Headless `claude -p` refuses web tools unless pre-approved (New Research, 2026-09-27)
- `--tools WebSearch,WebFetch` only makes the tools available. In `-p` mode nothing can approve them, so every
  WebSearch was denied (listed in the result's `permission_denials`), and WebFetch worked only for Claude Code's
  built-in allowlisted domains. The model then wrote "search not permitted" into the report, with no error.
- Rule: `allowWeb` also passes `--allowedTools WebSearch,WebFetch`; read `permission_denials` and treat refused
  web calls as lost web access. Reproduce with the exact CLI flags before blaming the prompt.

## Text selected in the rendered editor is not the Markdown source (2026-09-27)
- The rendered view shows `doesn’t` for `doesn't`, drops `**`, `[` `](url)` and list markers. Matching a selection
  back to the source needs normalisation (`ResearchDocument.plain`), found only by a real selection, not by tests
  written from the source.

## Driving a background test copy through Accessibility (2026-09-27)
- Toolbar `Menu`: `AXPress` on the AXMenuButton opens it and its AXMenuItems can be pressed; `AXShowMenu` does not.
- SwiftUI tap gestures (file tree rows) ignore `CGEvent.postToPid` clicks while the app is in the background; open
  files through a pressable path instead (Search tab results). Web content: select with
  `AXTextMarkerRangeForUIElement` → set `AXSelectedTextMarkerRange` on the AXWebArea (fires `selectionchange`).

## Prompts that make the AI check git state must exclude the app's own files (batch Fix with AI, 2026-09-27)
- The batch prompt told the AI to ask before continuing when the tree is dirty. The app had just marked the batch's reports
  `fixing`, and MarkView keeps its index in an untracked `.dde/`, so every real run would have stopped on the question.
- Rule: when a prompt conditions on "uncommitted changes", list what the app itself changed or owns (its own edits, `.dde/`)
  as expected and never committed. Verify such prompts with a headless `claude -p` run in a fixture repo, not only by reading.

