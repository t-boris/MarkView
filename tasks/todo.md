# MarkView — Follow-up Tasks

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
