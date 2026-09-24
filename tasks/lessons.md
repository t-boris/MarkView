# Lessons

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
