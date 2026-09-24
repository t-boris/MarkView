# MarkView — Follow-up Tasks

## Active 6: Finder "Open With" / folder open does nothing

Symptom: opening a file or folder from Finder launches/activates MarkView but
nothing opens. `~/markview_debug.log` showed `application:open:` → posting
`openInActiveWindow` on every attempt and zero handled opens.

Root cause: SwiftUI shows the window *before* `application(_:open:)`, so the
delegate took the "window visible" branch and posted a fire-and-forget
notification. `ContentView` accepts it only if `hostWindow` is the active window,
but `WindowAccessor` sets `hostWindow` asynchronously — it was still nil, every
window rejected the request, and it was lost.

### Plan
- [x] `MarkViewApp.pendingOpenURLs` queue + `enqueueOpen(_:)`; delegate,
      Finder Services callback and Quick Action poll all enqueue.
- [x] `ContentView.drainPendingOpens` — active window takes the queue on
      request signal, on `hostWindow` attach, and on `didBecomeKey`.
      Removed `consumedOpenRequestIDs` and the single `pendingOpenURL`.
- [x] Build + Finder-style `open -a` checks.

### Review (2026-09-17)
- `xcodebuild` → BUILD SUCCEEDED.
- Cold launch with `.md` → opened (trigger `windowAttached` — the exact race).
- Folder open → `openFolder START`, tree loaded.
- App already running, `.canvas` file → opened in the same process.
- Not exercised: all windows closed while app stays running (same drain path,
  via `didBecomeKey`/`windowAttached`).

## Active 5: Fullscreen viewer for Mermaid diagrams

Request: large mermaid diagrams render too small in the preview (`.mermaid svg`
has `max-width: 100%`); need a way to open a diagram full-screen to inspect
details.

### Solution
Lightbox overlay over the whole window. Hovering a rendered `.mermaid` diagram
shows a "⛶" expand button (double-click on the diagram works too). The overlay
clones the already-rendered SVG at its natural `viewBox` size (vector → crisp at
any zoom) and offers the same interaction scheme as the canvas viewer:
wheel = zoom around cursor, ⇧+wheel = pan, drag = pan, pinch = zoom,
toolbar (Fit / 100% / − / + / ✕), Esc or backdrop click closes.

### Plan
- [x] New module `vendor/js/markview-diagram-viewer.js` — overlay build, pan/zoom
      (mirrors `markview-canvas.js` math), `decorateMermaidDiagrams()`, delegated
      dblclick fallback.
- [x] `markview-render.js` — call `decorateMermaidDiagrams()` after
      `mermaid.run()` resolves (buttons must be injected after SVG replaces the
      div content).
- [x] `index.html` — CSS for expand button + overlay (z-index 1000, above all
      existing chrome ≤ 500); `<script>` tag for the new module. No `project.yml`
      change needed (vendor dir is ditto-copied whole).
- [x] Build with xcodebuild; manual check on TestFiles fixture.

### Review (2026-07-19)
- Implemented as planned; build succeeds, final JS verified inside the built
  app bundle. Verified in Chrome against the served editor (`window.setContent`
  + real DOM events): expand button injected once per diagram (no dupes on
  re-render), fit/wheel-zoom-around-cursor/pan/Esc/backdrop-close all work,
  zoomed SVG text stays crisp.
- Fixed a bug caught during verification: a pan-drag ending on the backdrop
  fires a synthetic `click` there, which closed the overlay mid-interaction.
  Now `dvPanEnd` sets `suppressClick` when the pointer actually moved (>3 px)
  and the backdrop click handler consumes it.
- Pre-existing bug found (NOT fixed, out of scope): `markview-d3-mermaid.js:394`
  throws `ReferenceError: init is not defined` on every page load — it calls
  `init()` (defined in `markview-init.js`) but loads *before* that file.
  Reproduced with and without the new module. Needs a decision: move the
  init-kick into `markview-init.js` or reorder scripts.

## Active 4: Finder "Open Folder" lands in orphaned window (welcome screen shown)

Bug report: "I can't open folder /Users/boris/github.com/vivaa-platform/docs/code-architecture".

### Diagnosis (from ~/markview_debug.log + live app inspection, 2026-07-16)
- The folder itself is fine (normal perms, 10 entries). The app's own log shows
  `openFolder START → Tree loaded: 10 children → openFolder COMPLETE` at 23:49:22Z —
  the open **succeeded internally**, but the only visible window (buildID 45610 =
  process launched 23:46:50Z) still shows the welcome screen with `rootNode == nil`.
- Root cause: `application:open:` only stashes the URL in static
  `MarkViewApp.pendingOpenURL`. Delivery relies on a 0.5 s-delayed closure inside
  *every* ContentView's `.onAppear`. When the Finder open event fires, SwiftUI
  creates/re-attaches more than one ContentView (log shows 2× `onAppear` for 1×
  `WorkspaceManager init`); whichever delayed closure runs first consumes the URL —
  in this case a ContentView whose window was discarded. The surviving visible
  window never sees the URL → user sees "can't open".
- Second latent bug found: `.openInActiveWindow` notification (used by the
  `onOpenURLs` callback and the Finder Quick Action poller `checkFinderOpenRequest`)
  has **no observer anywhere** — that entire delivery path is dead code, so the
  Quick Action route silently does nothing.
- Contributing risk: `ensureWindowExists` (AppDelegate, +0.3 s after activation)
  can race the open event and spawn an extra welcome window via `newWindowForTab:`.

### Fix plan (root-cause: make URL delivery window-aware, not timing-based)
- [ ] 1. ContentView: add `.onReceive(NotificationCenter … .openInActiveWindow)`
      observer — revives the dead path. Handle only if this view's window is key
      (fallback: frontmost visible). Dedup via the `id` already in the payload.
- [ ] 2. AppDelegate `application:open:`: if any visible window exists, post
      `.openInActiveWindow` (same payload shape) instead of relying on the
      onAppear race; keep `pendingOpenURL` **only** for cold launch (no windows yet).
- [ ] 3. ContentView: replace the 0.5 s-delayed `pendingOpenURL` check with a
      `NSWindow.didBecomeKeyNotification`-driven consume (own window became key +
      `rootNode == nil` + URL pending → open). Keeps cold-launch working without
      the multi-instance race.
- [ ] 4. Verify: rebuild; test (a) cold launch via Finder "Open With" on the
      vivaa docs folder, (b) same while app is running showing a welcome window,
      (c) Finder Quick Action file path, (d) Cmd+Shift+O panel unchanged.

### Review
(to be filled after implementation)

## Active 3: .canvas (JSON Canvas) file support

Goal: MarkView opens and renders Obsidian/JSON-Canvas `.canvas` files with full
viewer functionality: pan, zoom (wheel/pinch/buttons/fit), node rendering
(text/file/link/group), edges with arrows+labels, node properties panel,
file-node click-to-open, source view toggle, theme support.

### Plan
- [x] 1. `FileType` (DocumentState.swift): add `canvas` case, `"canvas"` extension, mapping in `from(url:)`
- [x] 2. `FileTreeView.fileIcon`: icon for `.canvas` (`rectangle.3.group`, yellow)
- [x] 3. `ContentView`: accept `.canvas` in drag-drop + Open File panel
- [x] 4. `Info.plist`: Canvas document type + imported UTI `com.markview.jsoncanvas` (conforms to public.json)
- [x] 5. `WebViewBridge`: new JS→Swift message `canvasOpenFile {path}` + delegate method
- [x] 6. `EditorView.Coordinator`: implement delegate; `.canvas` links open in tab
- [x] 7. `WorkspaceManager.openCanvasFileReference(path:)`: resolve vs workspace root, then canvas dir; rejects absolute/`..` paths
- [x] 8. NEW `Resources/Editor/vendor/js/markview-canvas.js` (524 lines) + `vendor/css/markview-canvas.css`
- [x] 9. `markview-structured.js`: branch `fileType === 'canvas'` → canvas renderer
- [x] 10. `index.html`: script tag (after markview-globals.js — wrapper order matters) + css link
- [x] 11. Test fixture `TestFiles/demo.canvas` covering all node/edge variants
- [x] 12. Build BUILD SUCCEEDED; verified live on demo.canvas AND user's real vivaa-platform.canvas (248 nodes · 183 edges)

### Review
- Verified visually in the running app: group/text/file/link nodes, preset+hex colors,
  edges with labels/arrowheads (incl. double-arrow), markdown+code inside text nodes,
  zoom-to-fit (93% demo / 51% real canvas), properties panel (node + edge props, raw
  text block), TOC lists canvas nodes (groups level 1, members level 2) with pan-to-node.
- Interactions: wheel = zoom around cursor (user request mid-review; was pan),
  ⇧+wheel = pan, drag background = pan, pinch = zoom, Fit/100%/−/+ buttons,
  dbl-click background = fit, dbl-click text/group node = zoom-to-node,
  dbl-click file node = open via `canvasOpenFile` (root→canvas-dir resolution),
  dbl-click link node = open in browser, Esc/✕ = deselect, Source ↗ = raw JSON
  (editable, Cmd+S works through existing structured pipeline).
- Fixes found during verification:
  - format-bar popped on selection inside canvas/structured views → gated to
    `state.fileType === 'markdown'` (markview-edit.js, root-cause fix for JSON/XML too).
  - zoom-to-fit ran before WebKit layout on tab-restore → 0×0 viewport clamped to 5%;
    now retries via requestAnimationFrame (bounded 30).
  - `setContent` (markdown path) now restores `state.fileType`/contentEditable —
    pre-existing staleness after viewing any structured file.
  - parse-error view restores body padding/scroll (leaveCanvasView before error render).
  - window-level pan listeners are named functions → addEventListener dedupes across
    re-renders (no listener leak).
- Known scope limits: viewer-first (no node dragging/creation — edit via Source),
  file-node image previews not embedded (sandbox), mermaid inside canvas text nodes
  renders as plain code block.

---

## Active 2: docId = относительный путь + прогресс в футере

### Задача 1 — docId без коллизий (относительный путь от корня)
- [ ] `SemanticDatabase.documentId(for:root:)` — канонический хелпер (POSIX rel-path, fallback на имя).
- [ ] Миграция через `PRAGMA user_version` (=1): очистить documents/modules/struct_relations/entities/claims/fts (FK-каскад чистит blocks/symbols/chunks), реиндекс. **Подтверждено: очистить и реиндекс.**
- [ ] `WorkspaceManager.docId(for:)` → делегат к статике с `rootNode.url`.
- [ ] Producers → хелпер: StructuralIndexer(scanTree/link/extractContentModules), WM(excludeFolder, indexFolderComponents, reindexFile, handleBlocksDelta, analyzeAllFiles), Views(BlockIntelligence, CompilePanel). Single-file (indexSingleFile) — без изменений (имя == rel-path).
- [ ] Резолв ссылок: targetId = rel-path.
- [ ] Обратный поиск в ModuleExplorerView: `root.appendingPathComponent(docId)` + fallback.

### Задача 2 — прогресс индексации в футере
- [ ] runStructuralIndex: stderr дочернего через `Pipe`, парсить `Indexing N/M` → `indexingProgress` (set при спавне, clear в terminationHandler).
- [ ] DiagnosticsBarView: сегмент со спиннером + текстом, видим при `indexingProgress != nil`.

### Задача 3 — фикс зависания (найдено через sample стека)
Реальная причина «висит» — НЕ индексация/WebView/миграция, а `GitClient`:
- [x] `run`/`runWithError` → `nonisolated async` + `Task.detached` (git вне главного потока).
- [x] Читать pipe до `waitUntilExit` (устранён дедлок при выводе git > 64KB pipe-буфера).
- [x] Все вызовы (refresh/commit/push/pull/stage/diff/init) → `await`; `diff` стал async (GitView обновлён).
- [x] Миграция docId: вместо каскадного `DELETE` (вешал main) — **удаление файла БД** при старой
      схеме (user_version) прямо в `init` (O(1), без раздувания). По идее пользователя.

### Verification (проверено)
- [x] Сборка BUILD SUCCEEDED.
- [x] docId = относительные пути: 1038 (с коллизиями) → 1222 уникальных; total==distinct.
- [x] Дерево модулей корректно: 177 модулей, SUM(file_count)=1222, глубина до 5 уровней.
- [x] Миграция: старая БД → файл пересоздан (inode сменился), user_version=1; steady-state «up to date».
- [x] Футер: дочерний эмитит N/M; отдельное `structuralIndexProgress` не блокирует дерево/панель.
- [x] **Зависание устранено**: sample главного потока — нормальный event loop, 0 совпадений
      `waitUntilExit/GitClient.run`, CPU 0%, отзывчив.

---

## Active: Fix долгий старт (>5 мин) — индексация воркспейса

### Root cause (подтверждено кодом + логами)
`StructuralIndexer` при открытии папки обходит всё дерево **до 3 раз**:
1. Детект изменений (`StructuralIndexer.swift:27-55`) — `DispatchQueue.main.sync` **на каждый файл** + чтение всего содержимого каждого файла (FNV-хэш). N round-trip'ов к занятому главному потоку → зависание UI на минуты.
2. `indexModules` (:241) — 2-й обход + `contentsOfDirectory` на каждую папку.
3. `indexDocuments` (:308) — 3-й обход, читает и парсит каждый файл.

### План (одобрено: пункты 1+2+3)
- [ ] 1. Убрать `main.sync` из цикла — батч-фетч мета (hash+mtime) одним SELECT.
- [ ] 2. Детект по `contentModificationDate` (mtime); читать/парсить ТОЛЬКО изменённые.
- [ ] 3. Объединить три обхода дерева в один проход.

### Изменения
- [ ] `SemanticDatabase.upsertDocument(..., fileMtime:)` — писать `file_mtime` (колонка уже в схеме).
- [ ] `SemanticDatabase.allDocumentMeta()` — батч-фетч `[docId: (hash, mtime?)]`.
- [ ] `StructuralIndexer.indexAll()` — оркестратор: мета → один `scanTree` → батч-запись.
- [ ] `StructuralIndexer.scanTree` — один enumerator: модули + классификация файлов по mtime.
- [ ] `writeModules` / `writeChangedDocs` — батч-запись на MainActor (чанки 50).
- [ ] Удалить `indexModules` / `indexDocuments`. Схемы ID сохранены 1:1.

### Architecture change (по требованию пользователя)
Индексация вынесена в **отдельный процесс** (re-exec бинарника `MarkView --dde-index <folder>`),
а не фоновый Task внутри приложения. Sandbox отключён → Process + доступ к папкам разрешены.
- `MarkViewApp.swift`: `@main enum DDEAppEntry` перехватывает `--dde-index` до SwiftUI;
  `DDEIndexerRunner` гоняет `indexAll()` на `@MainActor` (SemanticDatabase изолирован),
  `dispatchMain()` обслуживает очередь, `exit()` по завершении. С `MarkViewApp` снят `@main`.
- `WorkspaceManager.runStructuralIndex`: спавнит `Process`, `terminationHandler` →
  `loadCachedResults()` + `refreshSemanticViews()`.
- `SemanticDatabase`: `PRAGMA busy_timeout = 5000` для кросс-процессного WAL.
- `runningIndexers` — **static** (процесс-wide), иначе `Process` освобождается вместе с
  временным WorkspaceManager (их при старте несколько) и terminationHandler не срабатывает.

### Verification (проверено на live-запуске, KnowledgeDB = 1222 .md)
- [x] Сборка: `xcodebuild Debug` → BUILD SUCCEEDED.
- [x] Out-of-process: дочерние процессы с отдельными PID (87768/88321/88789).
- [x] Первый индекс 1222 файлов: ~15с вне процесса (старый код висел >5 мин, БД 4KB/пустая).
- [x] Инкрементально: 1222 → ~1038 пропущено по mtime, ~1с; `file_mtime` заполнен 1038/1038.
- [x] terminationHandler срабатывает (`exited code=0`) → виды обновляются.

### Review
- Корневая причина >5 мин: НЕ парсинг JS (первая гипотеза была неверна), а индексация —
  3 обхода дерева + `DispatchQueue.main.sync` на каждый из 1222 файлов на занятом main-потоке.
- Известный pre-existing дефект (вне рамок задачи): `docId = имя файла`. В KnowledgeDB 1222
  файла при 1038 уникальных именах (184 коллизии) → совпадающие имена «мерцают» по mtime и
  реиндексируются каждый раз (~1с, не растёт). Фикс — сменить схему docId на относительный
  путь — затронет всю схему БД и весь код, использующий docId. Требует отдельного согласования.
- Удалённые/перемещённые файлы из БД не вычищаются (как и было). Вне рамок.

---

## Pending after Recursive Insight (v2)

- [ ] **Set up XCTest infrastructure for MarkView**
  - **Why:** Project has no test target. `Tests/` folder is empty, `project.yml` defines only the `MarkView` app target. No `import XCTest` anywhere.
  - **What to do:**
    1. Edit `project.yml` to add a `MarkViewTests` target (`type: bundle.unit-test`, `platform: macOS`, `sources: [Tests]`, `dependencies: [MarkView]`).
    2. Run `xcodegen` to regenerate `MarkView.xcodeproj`.
    3. Add a test scheme so `xcodebuild test -scheme MarkView` works.
    4. Update `install.sh` / CI to run `xcodebuild test`.
    5. Retroactively cover Recursive Insight v2 critical paths (per Decision 9 — tests deferred until XCTest infrastructure exists; the eight v2 paths below are the canonical first tests for this feature):
       - [ ] `Tests/InsightToolCallParsingTests.swift` — Anthropic `tool_use` envelope parsing in `GraphRAG.buildSkeleton`. Verify strict-schema `InsightSkeleton` decoding, fallback to a single-prose-section `InsightSkeleton` on schema violation, and unique `section.id` / `deepDiveTopic.id` enforcement.
       - [ ] `Tests/InsightPostMessageTests.swift` — `WebViewBridge` postMessage dispatch: 5-type allowlist (`insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`), per-type payload schema validation (presence + non-empty + Int bounds + UUID shape), `frameInfo.isMainFrame` guard, and parent JS `event.source` / `event.origin === 'null'` defense.
       - [ ] `Tests/InsightCacheCRUDTests.swift` — `InsightCache` atomic `writeNode` / `readNode`, `updateManifest` / `loadManifest` (UUID-suffixed temp + `replaceItemAt` swap), concurrent-writer collision avoidance, `cleanup()` ENOENT tolerance, path-containment guard against symlink escape.
       - [ ] `Tests/InsightArchiveExporterTests.swift` — ZIP staging dir builder + HTML rewriting (deep-dive `<button data-section-id=…>` → `<a href="<uuid>.html">`, breadcrumb `href="#<uuid>"` → relative file href, lib refs `../_assets/` ↔ `_assets/` for root promotion), Decision 10 escape policy enforcement at every interpolation, and `Process` argument-array safety against shell-metacharacter destination filenames.
       - [ ] `Tests/InsightBlobLifecycleTests.swift` — Lazy `URL.createObjectURL` materialisation per skeleton section types (Mermaid/Chart/KaTeX gated on `section.type` / `metadata.hasMath`), revocation on navigation between nodes with different lib subsets, and full revocation on tab close via `window.releaseInsightBlobs()`.
       - [ ] `Tests/InsightPhase2ParallelismTests.swift` — `withThrowingTaskGroup` cap of exactly 5 concurrent section streams enforced (additional sections wait for a slot; group never exceeds the cap even under burst).
       - [ ] `Tests/InsightIframeCSPTests.swift` — Iframe `srcdoc` CSP correctness: `sandbox="allow-scripts"` (no `allow-same-origin`, `allow-popups`, `allow-forms`, `allow-modals`, `allow-top-navigation`), `<meta http-equiv="Content-Security-Policy">` present with `default-src 'self' 'unsafe-inline' blob: data:` + `img-src * data: blob:` + `font-src * data:`.
       - [ ] `Tests/InsightIframeTimeoutTests.swift` — 10 s no-`insightIframeReady` watchdog: parent JS calls `setInsightError(message, retryable: true)` and tears down the iframe; retry path re-issues the load.
  - **When:** Within 2 weeks after Recursive Insight v2 is merged.
  - **Owner:** Boris (or first contributor to touch insight code path post-merge).

- [ ] **Address security carry-over items from Recursive Insight tech-spec validation**
  - **Why:** Security audit r1 raised these as MEDIUM/LOW, deferred outside the Recursive Insight scope but should be resolved before broader release.
  - **Items:**
    1. **WKWebView preference audit** — explicitly verify `WKWebViewConfiguration.preferences.javaScriptEnabled` only where needed, set `webView.configuration.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")` and `"allowUniversalAccessFromFileURLs"` to harden against local-file XSS.
    2. **Audit logging for AI calls** — log model, token counts (already done), but also LLM call source (which feature/tab triggered it) for cost attribution and abuse forensics.
    3. **Pin markdown-it and mermaid versions** — currently CDN-loaded without integrity hashes. Add SRI hashes or vendor in `Resources/Editor/` and pin specific versions. Mermaid ≥ 10, markdown-it ≥ 13.
  - **When:** Before next major release of MarkView, not tied to Recursive Insight.

---

## Whole-document translation (RU/EN) — 2026-08-31

Selection translation worked, but whole-document translation was unreachable dead
code and had no Russian variant. Requirement: RU/EN with no selection proposes
translating the entire document into a copy, preserving all formatting.

- [x] Clear `formatBarSelectedText` when the selection collapses (`markview-edit.js`) —
      stale capture made RU/EN re-translate the previous selection forever.
- [x] Capture Source-mode selections from the `<textarea>` (`currentSourceSelection`) —
      `window.getSelection()` never covered it, so selection translation was dead in Source mode.
- [x] Replace the never-called `translateToEnglish()` with `translateWholeDocument(targetLang)`.
- [x] `selectionAction` with no selection now shows a confirm popup built from the
      `#action-popup` DOM (`window.confirm()` silently returns false in this WKWebView).
- [x] Remove the leftover `document.title = 'SEL[...]'` debug line.
- [x] Route the engine: Ollama when connected, else Anthropic, else a visible message
      in the editor popup (was a silent `NSLog` return). Added `ProviderRouter.ActionType.translate`.
- [x] Structure-aware `splitForTranslation` — atomic blocks (front matter, fenced code,
      tables, list/quote runs, paragraphs), never split mid-structure, lossless rejoin
      via per-block separators. Front matter and code fences are never sent to the model.
- [x] Per-chunk structural validation (`skeleton`) with one strict retry; on failure keep
      the source text and report it in the document instead of emitting corrupted markdown.
- [x] Live progress banner written into the translated tab (`indexingProgress` only shows
      in the file-tree sidebar, which is often collapsed).
- [x] Resolve the target tab by `OpenTab.id` instead of a captured index.
- [x] Add the missing HTTP status check; join all `content` text blocks, not just the first.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED.
- Splitter extracted into `/tmp/splittest.swift` and exercised against a fixture with a
  GFM table, a leading-pipe-less table, a fence containing table-like and heading-like
  lines, nested lists with continuations, task lists and a block quote:
  lossless round-trip PASS, atomicity PASS at maxChars 4000 and 60.
  Edge cases PASS: no trailing newline, leading blank lines, CRLF, unclosed fence,
  whitespace-only, heading-only, unterminated front matter.
- `selectionAction` driven through a DOM stub in node: no-selection → proposal popup and
  no API call; confirm → `translateRequested`; `explain` with no selection → no-op;
  with a selection → unchanged popup path.
- App launched on `TestFiles/translation-fixture.md` — no `jsError` entries in
  `~/markview_debug.log`.

### Not fixed (found during review)
- `BlockIntelligenceView.swift:56` — the block-level "Translate" button calls
  `submitJob(.translateBlock)`, but `submitJob` ignores its argument and always calls
  `submitExtraction`. The button does not translate anything.
- Live translation quality with a table has not been exercised against a real API key
  or a running Ollama — needs a manual pass.

---

## Configurable AI CLI tools + Whisper diagnostics — 2026-09-03

Bug report: Codex (and possibly Claude and Whisper) stopped working, with no way to
reconfigure them from the UI.

### Diagnosis
- **Codex broken:** `AIConsoleEngine.codexPath = "/opt/homebrew/bin/codex"` did not
  exist. Real binary: `~/.nvm/versions/node/v22.22.3/bin/codex` (npm/nvm install).
  `codex login status` → logged in, so auth was fine — only the path was wrong.
- **Claude fine:** `~/.local/bin/claude` v2.1.259, `claude auth status` → loggedIn true.
- **Whisper config fine:** key present, mic permission granted (TCC=2), WAV settings
  correct, usage string present. No configuration fault found.
- **Installed app was 7 weeks stale** (Jul 16) — the likely reason Claude/Whisper
  "also" appeared broken.

### Changes
- [x] `CLIToolLocator` + `CLITool` in `AIConsoleEngine.swift` (no new files, so the
      hand-maintained pbxproj needs no regeneration). Resolution order: Settings
      override → candidate scan incl. every `~/.nvm/versions/node/*/bin` → login-shell
      `command -v`, off-main with a timeout.
- [x] Subprocess `PATH` now built from the tool's own dir + base dirs + all Node bin
      dirs + user's extra entries, replacing the fixed literal that omitted nvm.
- [x] Missing binary now writes an actionable message into the console (what, where
      searched, where to fix) instead of an opaque `process.run()` throw.
- [x] Settings → "AI CLI Tools": per-tool path field, Save, Auto-detect, Check
      (version + sign-in state), Login in Terminal, plus an extra-PATH field.
- [x] Terminal login via an executable `.command` file + `NSWorkspace.open` — avoids
      Apple Events and the automation permission prompt.
- [x] Settings → "Whisper": mic status (+ deep link to System Settings), key status,
      model picker (whisper-1 / gpt-4o-transcribe / gpt-4o-mini-transcribe), and a
      3-second record-and-transcribe self-test that prints the real API error.
- [x] `WhisperClient`: model from settings, HTTP status + model in the error text,
      `runSelfTest()`, removed the dead `.m4a` init path that disagreed with the
      `.wav` the multipart body declares.
- [x] Security: `DDESettingsView.onAppear` was logging the first 20 chars of both API
      keys to `~/markview_debug.log`. Now logs presence and length only.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED.
- Locator exercised as a standalone binary against the real machine:
  claude → `/Users/boris/.local/bin/claude`, v2.1.259, loggedIn true;
  codex → `/Users/boris/.nvm/versions/node/v22.22.3/bin/codex`, v0.146.1, loggedIn true.
- Failure path: override set to a nonexistent file → "Path set in Settings does not
  exist or is not executable: …", no silent fallback. Auto-detect recovers.
- Login-shell fallback resolves codex independently of the candidate scan.
- Timeout guard: `/bin/sleep 30` with a 2s budget terminated at 2.0s, exit -2.
- App launched from the Debug build: runs clean, no key material in the debug log.

### Left for manual check
- Console round-trip on each backend (needs UI; `codex exec --full-auto` can write
  files, so it was not run headlessly).
- Whisper 3-second self-test (needs a microphone and a click).

## AI assistant + model selection (Claude / Codex) — 2026-09-24

Goal: choose which CLI (Claude Code / Codex) and which model answers AI Console
requests — every "ask AI" path (console input, AI tools, graph edit, docs) goes
through `AIConsoleEngine.sendMessage`. Configurable in DDE Settings, quick-switchable
from the AI panel via a popover dialog. One source of truth: UserDefaults.

- [x] `AIAssistantPreferences` (AIConsoleEngine.swift): keys `settings.ai.backend`,
      `settings.cli.<tool>Model` ("" = CLI default); model catalog per tool —
      Claude aliases (fable/opus/sonnet/haiku), Codex list read from
      `~/.codex/models_cache.json` (visibility == "list"), custom name always allowed.
- [x] Engine: backend read from preferences; pass `--model` (claude) / `-m` (codex);
      when backend changes between turns, drop the CLI session ids and post a system
      note instead of wiping the visible history.
- [x] AI panel: replace the two-tab header with a "Claude Code · opus ▾" button that
      opens a popover (assistant segmented picker, model list, custom model field);
      input placeholder names the active assistant.
- [x] DDE Settings → AI CLI Tools: "Default assistant" picker + per-tool model picker.
- [x] Build; verify CLI args with both backends; manual UI check.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED; no new warnings in touched files (the
  old off-actor reads of `backend`/session state are gone).
- Exact argument shapes the engine builds, run against the real CLIs:
  claude fresh `--model haiku` → init model claude-haiku-4-5, "OK";
  claude `--resume <id> --model sonnet` → claude-sonnet-5, "OK2" (model switch keeps session);
  codex `exec --full-auto --skip-git-repo-check -m gpt-5.5` → "OK";
  codex `exec resume --last ... -m gpt-5.5` → "OK2".
- Codex catalog lists models the account may not be allowed to use (e.g. gpt-6-luna
  on a ChatGPT login → HTTP 400); the CLI's error text reaches the console as an error.

### Left for manual check
- Popover and Settings picker in the running app (UI).

## Close Folder — 2026-09-24

Goal: close the open workspace and return to the welcome screen to pick another folder.

- [x] `WorkspaceManager.closeFolder() -> Bool`: one "save changes to N documents?"
      prompt (Save All / Don't Save / Cancel; abort if a save fails), cancel insight
      sessions, stop the AI console run, terminate this window's structural-index
      child, stop the file watcher, drop tabs, tree, engines and git state.
- [x] Share the engine teardown with `initSingleFileWorkspace` (`releaseWorkspaceEngines`).
- [x] `GitClient.reset()` so the branch bar disappears.
- [x] UI: File → Close Folder menu item; ✕ button on the file-tree breadcrumb bar;
      "Open Folder…" button in the empty file tree; breadcrumb state resets when the
      root changes.
- [x] Build, deploy locally, manual check.

### Verification
- Debug + Release builds succeed; installed to /Applications.
- File → Close Folder ran `closeFolder` (log line with folder path); window returned
  to the welcome screen.
- Menu item was stuck disabled (Commands don't observe the focused WorkspaceManager);
  fixed with a value-typed `workspaceHasFolder` focused value.
- User confirmed Close Folder works in the installed build.
