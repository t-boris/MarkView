# Architecture and code review, November 2026

Reviewed: `main` at `df78a47` (MarkView 6.25.0), 2026-11-15.
Scope: the whole repository: 439 Swift files (150,710 lines), the bundled web editor (about 19,400 lines of first-party JavaScript plus `index.html`), tests, CI, build and release scripts, and the docs.

This document is a backlog source. Every finding has an id (`AR-nn`), a severity, an effort estimate (S = up to a day, M = several days, L = weeks, done in steps) and enough evidence to turn it into a task. Section 12 gives the order to work in; section 13 lists the decisions that are the owner's.

## How this was done, and its limits

- Seven parallel read-only passes, one per slice (layering, application shell, AI layer, web editor and bridge, extensibility, tests and CI, persistence/security/concurrency), then a spot check of the most serious claims against the code.
- Everything is static reading with `grep`, `wc` and `git`. **Nothing was built, run or profiled.** Performance findings name code paths that block; their real cost on screen is not measured. Runtime consequences inferred from code are marked "by reading".
- Counts are measurements at the commit above. Two passes sometimes counted the same thing with slightly different patterns (for example 17 files with `Process()` versus about 12 distinct runner implementations); the text says which is meant.
- Line numbers are given as evidence for today. They will drift; the symbol named beside each one is the stable reference.
- `docs/architecture/risks-and-tech-debt.md` describes 2.17.0. Where a finding is already recorded there, this review says so and whether it is still true.

## 1. Verdict

MarkView is not a clean architecture today, and it is also not a mess. It is a fast-grown single-target application whose individual pieces are often well made, held together by one very large object and by convention.

What is sound and should be kept as the model:

- The Models layer is mostly free of UI: 287 of 338 files import no UI framework. Views contain no child processes, no SQL and no JSON coding.
- 63 of 66 observable classes are `@MainActor`. Notification use is small (12 custom names) and scoped per window.
- Per-window state (`PanelLayout`, `WindowUIState`, `WindowTheme`, `@WindowStorage`) is a deliberate design with injected storage.
- Several features have exemplary cores: `ProjectWorkflow` + `ProjectWorkflowStore` (pure, versioned, typed load results that never overwrite a damaged or newer file), `QAStore`, `CockpitRunStore`, `UIStudioBridge` (typed parsing with rejections), `CommandPolicy` (a pure classifier), `FrontMatter`.
- Workflow statuses and templates are already data-driven, with user files validated and never rewritten. That is the pattern to copy for themes and layouts.
- `release.sh` is robust (early notary check, clean-checkout check, no secrets).

What is structurally wrong:

1. **One god object.** `WorkspaceManager` (5,851 lines, 49 `@Published`, about 290 methods, 19 owned stores) is the composition root, the router, the tab manager and a dozen feature coordinators at once. Every feature depends on it and it depends on every feature.
2. **No shared infrastructure.** Running a process, calling an assistant, writing a file, logging and escaping HTML are each implemented many times.
3. **No boundaries the compiler enforces.** 338 files in one flat `Models/` folder, one target, domains that reference each other in cycles.
4. **The web side has no module system and an unsafe default.** Untrusted Markdown is rendered with raw HTML enabled in the page that holds the native bridge.
5. **Tests exist in volume but not as a system.** 166 hand-assembled scripts, 106 of which CI never runs.

Scorecard (the owner's questions):

| Question | Assessment |
|---|---|
| Clean architecture (layers, dependency direction) | Partial. Layers exist by folder name only; dependencies point in both directions through `WorkspaceManager` and six domain cycles. |
| Logical decomposition | Weak at the top (three files above 3,700 lines, flat folder), good inside several features. |
| Sharing (reuse instead of copies) | Weak. See AR-24 to AR-27: about 12 process runners, 12+ AI retry loops, 7 HTML escapers, 130 test `check` helpers. |
| Decoupling | Weak at the shell, good in leaf value types. No composition root, no protocol seams for the shell. |
| Structure that is pleasant to work in | Not yet: flat folder, role-free names, 9 parallel lists to add one tool tab. |
| Extensibility | Cheap for backdrops (5 edit sites), expensive for tool tabs (9 parallel lists) and assistants (34 switches). |

## 2. Fix first: defects found on the way

These are not architecture work. They are small, concrete and several are security relevant.

| Id | Sev. | Eff. | Finding | Evidence | Fix |
|---|---|---|---|---|---|
| AR-01 | critical | M | Untrusted Markdown runs script in the page that owns the native bridge. markdown-it is created with `html: true`, the result goes to `innerHTML`, there is no sanitizer on the editor path, and the CSP allows `script-src 'unsafe-inline'`. An opened `.md` (or AI output, which takes the same path) can post any of about 100 bridge messages, including file opens and pull request actions. Recorded as S1, still true. Execution not demonstrated by running. | `markview-state.js:53`, `markview-render.js:147`, `index.html:22`, `markview-find.js:131` | Sanitize before `innerHTML` (vendored DOMPurify) or render documents in a sandboxed frame without the bridge; then remove `'unsafe-inline'` (57 inline `on*=` handlers and 2 inline scripts in `index.html` must move to listeners). |
| AR-02 | high | S-M | The Insight iframe is `sandbox="allow-scripts allow-same-origin"` while comments in `index.html` and `WebViewBridge.swift` say it is null-origin; model-written HTML is protected only by a regex. Recorded as S2, still true. | `markview-insight-handlers.js:132`; contrast `markview-discussion.js:49` (`sandbox=""`) | Null-origin frame with libraries inlined. |
| AR-03 | high | S | Turndown and its GFM plugin still load from jsDelivr with no integrity hash, and the CSP allowlists the host. This breaks the project rule "never load them from a CDN" and loses WYSIWYG saves offline (R3). | `index.html:1599-1600`, `index.html:22` | Vendor through `tools/web-vendor`; remove the host from the CSP. |
| AR-04 | medium | S | Two Swift-to-JS calls interpolate unescaped text into evaluated source: a folder name with an apostrophe breaks `setDocumentBase`, and a heading id taken from document HTML reaches `scrollToHeading`. | `WebViewBridge.swift:683`, `:706` | One `JS.call(name, args:)` helper (JSON-encoded arguments or `callAsyncJavaScript(_:arguments:)`); ban string-built calls. |
| AR-05 | medium | S | Startup references `init` three scripts before it is defined, so the `ready` message is never sent and startup relies on `didFinish` (by reading; R1, still present). | `markview-d3-mermaid.js:478-482`, `markview-init.js:57`, `index.html:1649/1656` | Move the call into `markview-init.js`. |
| AR-06 | high | S | A `@MainActor` method runs `git show` and waits for it with no timeout, reached from a bridge handler: a beachball if git stalls. Recorded, still true. | `ArchitectureStore.prFileURL` (`:2891`), called from `WorkspaceManager.swift:1787` | Make it async and run off the main actor. |
| AR-07 | high | S | The Insight archive export gives `zip -r` a stdout `Pipe()` that is never read; `zip` prints a line per file, so a large export can block for ever. Recorded, still true. | `InsightArchiveExporter.swift:88` | Add `-q` and send stdout to `/dev/null`, or drain it. |
| AR-08 | medium | S | A one-shot assistant call that times out gets SIGTERM only; a CLI that ignores it never finishes. Cancel already escalates to SIGKILL. | `CLICompletion.swift:426-431` versus `:358-368` | Same escalation on timeout. |
| AR-09 | high | S | Sensitive content in logs: the first 100 characters of dictated speech go to the system log; bridge payloads and generated JS (which can contain document text) are appended to a world-readable `/tmp/markview-insight-diag.log`. Both break the project rule on document contents in logs. | `WhisperClient.swift:337`; `WebViewBridge.swift:80, 180, 529-587` | Log counts, not content; delete the `/tmp` diagnostic file. |
| AR-10 | medium | S | The OpenAI key is stored in UserDefaults while every other credential uses the Keychain correctly. Recorded as S5, still true. (Locations only; no value was read.) | `WhisperClient.swift:20, 49, 63`; good examples `BrowserPasswords.swift:71`, `DatabaseKeychain.swift` | Move to the Keychain with a one-time migration. |
| AR-11 | medium | S | "Open in Terminal" builds AppleScript `do script "cd <path>"` and escapes only the double quote. Recorded as S7. `SystemProbe.swift:160` interpolates into `sh -c`; whether its input is quoted upstream is not verified. | `FileTreeView.swift:1208`, `SystemProbe.swift:160` | Quote properly or pass arguments, never a command string. |
| AR-12 | medium | S | Web Inspector is enabled in Release builds through private KVC (S12). The app polls and trusts `/tmp/markview_open_path.txt` (S6). The SSH control path is in `/tmp`. | `EditorView.swift:22`, `UIStudioSession.swift:311`, `MarkViewApp.swift:417`, `DeploymentExecutor.swift:167` | Gate the inspector on `DEBUG`; use the per-user temporary folder with mode `0600`. |
| AR-13 | medium | S | Silent failure where the person is told the opposite: undo-conflict markers are written to a source file with `try?`, then the UI says the markers are in the files and drops the conflict. A failed document save is only logged (R6). The bug report rewrite after an issue is filed is `try?`, so the issue link can be lost. | `UIStudioSession.swift:3089-3092`, `WorkspaceManager.swift:3628`, `FeatureIntake.swift:332` | Surface these three through the existing notice channels now; the general fix is AR-24. |

## 3. Application shell and state

### AR-14 `WorkspaceManager` is a god object and still growing (critical, L)

- `MarkView/Models/WorkspaceManager.swift`: 5,851 lines (3,766 when the risk register was written, +55%), 49 `@Published`, about 83 stored properties, about 290 methods, 19 stores built in property initializers, 20 of the 34 alert and panel call sites in Models.
- Named in 37 of 93 view files (62 `@EnvironmentObject`, 7 `@ObservedObject`, about 200 distinct members used) and in 27 model files. Six model types hold a weak back-reference to it; it references all 20 other domains. Every feature and the workspace form a dependency cycle.
- Its `MARK` sections no longer describe their contents: "Moving and copying files" holds the X-Ray action dispatcher and tab closing; "GitHub" holds intake, research and implement-with-AI; "Prototype Studio" holds deployments, the Cockpit, QA and discussions.
- One file compiles it in tests (as text, see AR-35). Tab closing, save, session save and restore, and opening a folder cannot be tested without the whole app.

Proposed decomposition, in this order (each step ships on its own):

| # | New object | Moves (lines today) | Size | What views and features use instead |
|---|---|---|---|---|
| 1 | `DocumentTranslator` + pure `MarkdownChunker` | 2544-2955 | ~410 | `translate(tab:) async` |
| 2 | `InsightCoordinator` + archive export | 2956-3611 | ~650 | the bridge's insight callbacks |
| 3 | `ResearchMapController` | 5561-5839 | ~280 | already an extension; give it its own state |
| 4 | `AITerminalsController` | 3991-4385, 5433-5452 | ~420 | `AssistantProviding`; replaces the `qa.assistantSelection` and `agentActivity.*` closures |
| 5 | `TabsController` (promote `WorkspaceTabsStore`) | 211-302, 998-1140, 2263-2463, 3612-3706, 5453-5495 | ~700 | `TabsProviding`, observed directly |
| 6 | `WindowChrome` (panel visibility, sheet requests) | 355-437 and scattered sheet flags | ~150 | merges into `PanelLayout` |
| 7 | `WindowSessionSnapshotter` | 1141-1274 | ~135 | `snapshot()` / `restore()` over tool descriptors (AR-31) |
| 8 | `ProjectContext` (root, linked folders, exclusions, index, recents) | 567-660, 726-997, 1275-1349, 2104-2262, 3749-3990 | ~900 | `ProjectContext` protocol: `root`, `aiProject`, `searchRoots`, `database` |
| 9 | `FeatureFlowCoordinator` (intake, research, implement, bug fix) | 4386-4887 | ~500 | takes `AssistantProviding` + `TabsProviding` |
| 10 | `ToolTabsRouter` (`openGit/QA/Cockpit/...`) | 4888-5432 | ~550 | driven by the tool registry |
| 11 | `CodeAndXRayCoordinator` | 1350-1623, 1663-1993 | ~600 | `handleArchitectureAction`, code navigation |
| - | `WorkspaceManager` stays as the composition root | wiring only | <400 | views migrate file by file |

Steps 1-3 share no state and are safe first. Step 5 removes the hot path of AR-15. Steps 4 and 8 introduce the protocols that make 9-11 testable.

### AR-15 Window-wide re-render through `objectWillChange` forwarding (high, M)

`WorkspaceManager` forwards the change signals of `fileTreeStore`, `tabsStore`, `layout` and `gitClient` (18 more `@Published`) into its own (`:692-712`). `updateTabContent` (every editor content message) and `updateActiveTabScrollPosition` (called unthrottled from `EditorView.swift:909-911`) rewrite `openTabs`, an array that carries each document's full text. Each such event invalidates all 69 observing declarations including `ContentView`, and triggers the session archive rebuild (debounced 400 ms). Whether the JS side throttles scroll events, and the frame cost, are not measured.

Fix: stop forwarding; expose tabs, file tree and git as separate observable objects; move scroll position and active heading out of `OpenTab` into a non-published side table.

### AR-16 Other oversized multi-responsibility types (high, M each)

- `ArchitectureStore.swift`: 4,467 lines in one main-actor type (3,136 when recorded, +42%): scan, cluster naming, importance, descriptions, change review, book, SQL, JSON caches, 41 assistant call references. Split along its marks into Scan / Clustering / ChangeReview / Book.
- `UIStudioSession.swift`: 3,748 lines plus four extension files.
- `PrototypeAI.swift` 2,160, `InsightSession.swift` 2,072, `FeatureAI.swift` 1,848: each mixes prompts, parsing, file writing and state; the first two embed HTML.
- Views above 1,300 lines: `FeaturePanelView` 2,084, `UIStudioView` 1,997, `GitHubViews` 1,808, `QAViews` 1,657, `FileTreeView` 1,409, `ContentView` 1,319.

### AR-17 No composition root; collaborators are wired four different ways (high for testability, M-L)

`ContentView.swift:188` creates `WorkspaceManager()`, whose initializers build everything. Wiring is done by closures set in `init` (`qa.assistantSelection`, `agentActivity.terminals`, `fileTreeStore.onTimer`), by back-references (`research.workspace = self`), by views writing hooks into the model (`EditorView.swift:476`, `:595`), and by 61 closure-typed stored properties across Models. The 15 existing protocols are feature-local; none covers the shell, tabs, file system, git or the assistant terminal. The QA model bug fixed in 6.24.2 came straight out of one of these closures.

Fix: a `WindowComposition` that builds the stores and hands each feature narrow protocols (`ProjectContext`, `TabsProviding`, `AssistantProviding`). `PanelLayout`, `WindowUIState` and `WindowTheme` already take injected storage and show the pattern.

### AR-18 Hidden global state (medium, S-M)

- Four observers react to **any** UserDefaults write (`ContentView.swift:1119`, `AIAssistantPickerView.swift:76`, `TerminalView.swift:237`, `WorkspaceManager.swift:4731`), while `PanelLayout.remember` and `WindowUIState.set` write a seed on every change including divider drags. Per-window UI state therefore wakes the assistant menu and the terminal model check in every window. The block observer in `WorkspaceManager` is never removed.
- At least 30 mutable statics, including per-project registries (`ProjectOperationsStore.stores`, `CockpitRuntime.services`, `BrowserControlServer.windows`, `ControlToolRunner+Flow.jobs`, `WorkspaceManager.runningIndexers`) and test knobs living in production types (`UIStudioSession.preparationLimits`, `DeploymentStore.approvalTimeout`, `DeploymentExecutor.extraOptions`, the last `nonisolated(unsafe)`).
- 73 literal UserDefaults keys in 37 files with no registry; seven literals are repeated (`"layout.showTOC.v3"` three times, `"settings.cli.extraPATH"` three times, and others). The project's own versioning rule makes a settings key change a major bump, yet nothing enforces key stability.

Fix: a typed settings observable for the assistant choice, seeds written at window close, one `ProjectRegistry` keyed by root for per-project services, knobs as init parameters, a `DefaultsKey<T>` registry.

### AR-19 Tasks and timers are not owned (medium, S-M)

`WorkspaceManager` has about 60 task sites (12 detached) and two stored handles; app-wide there are 356 statement-level `Task { }` against 80 stored task properties, and 238 `Task.detached`. Most work cannot be cancelled when a folder or window closes. Nine timers and many sleep loops never pause: there is no observer for app deactivation or window occlusion anywhere. `MarkViewApp.swift:244` starts a 1 s timer on every window appearance and never invalidates it (recorded, still true); a 2 s timer stats every open tab (`WorkspaceManager.swift:5455`).

Fix: a per-window task bag cancelled on close; one visibility-aware scheduler for polling; move the Quick Action poll to the app delegate.

## 4. Layering and module structure

### AR-20 One flat folder holds 22 domains and four layers (high, M)

`MarkView/Models`: 338 files, 114,425 lines, 323 at one level (only `Remote/` is a folder). It mixes pure values, persistence stores, 53 observable view models, process and network clients, prompt text and embedded HTML. The Xcode project lists every file individually.

Domains by size:

| Domain | Files | Lines | Largest file |
|---|---|---|---|
| UI Studio | 35 | 18,151 | `UIStudioSession` 3,748 |
| Features / issues / lifecycle / cycle time | 37 | 13,044 | `FeatureAI` 1,848 |
| QA | 41 | 9,736 | `QARunner` 684 |
| Workspace / window / files | 26 | 9,447 | `WorkspaceManager` 5,851 |
| Architecture / X-Ray | 15 | 8,727 | `ArchitectureStore` 4,467 |
| Prototype | 19 | 7,620 | `PrototypeAI` 2,160 |
| Semantic / Insight | 14 | 6,723 | `InsightSession` 2,072 |
| AI / agents | 18 | 6,512 | `ACPAssistant` 700 |
| Research | 11 | 5,148 | `ResearchMapDocument` 1,075 |
| Cockpit | 20 | 3,533 | `CockpitSession` 517 |
| Browser | 11 | 3,303 | `BrowserControlServer` 808 |
| Workflow | 12 | 3,272 | `ProjectWorkflow` 894 |
| Deployments / databases | 15 | 3,070 | `DeploymentDiscovery` 576 |
| Git / GitHub | 6 | 3,014 | `GitHubClient` 1,158 |
| Agent tools (MCP) | 8 | 2,821 | `ProjectAgentTools` 581 |
| Project operations | 8 | 2,186 | `ProjectOperationsStore` 775 |
| Book / PDF | 7 | 2,101 | `BookBuilder` 703 |
| Remote | 15 | 1,953 | `RemoteChannel` 208 |
| Theme / backdrop | 7 | 1,456 | `WelcomeBackdrop` 495 |
| Terminal | 5 | 1,152 | `TerminalSession` 703 |
| Dictation | 4 | 1,001 | `WhisperClient` 552 |
| Discussion | 4 | 455 | `Discussion` 245 |

Moving files is mechanical but wide: 211 test scripts hard-code paths to 238 distinct model files, and the architecture docs carry more than a thousand `file:line` citations. Each move must update the scripts in the same change (which is one more reason for AR-33).

### AR-21 Dependency cycles between domains (high, M-L)

Measured by type-name references across domain files (generic names may inflate a few edges):

- Features/Issues <-> Workflow (23 types one way, 15 back): effectively one domain split by file name. Merge into one Lifecycle domain.
- Browser <-> Agent tools: `BrowserControlServer` hosts all four tool runners and they reference it back. The MCP tool server lives inside the Browser domain. Extract an `AgentToolServer`.
- Semantic/Insight <-> Architecture; Git/GitHub <-> Features; Terminal <-> Remote; QA <-> Cockpit.
- AI/agents, which should be a base layer (17 domains depend on it), depends upward on `WorkspaceManager`, `ArchitectureStore`, `TerminalSession` and `BrowserSession`.

Cleanly separable today: Dictation, Theme/Backdrop, the git client, and the value-type cores of cycle time, QA scenario/run, UI Studio GraphQL/simulation and the Remote protocol. Large but low fan-in leaves: UI Studio, QA, Prototype.

### AR-22 Layer leaks (medium, S-M)

- View code in Models: `AIToolRuns.swift:71` (a `View`), `AppFontScale.swift:77, 88` (view modifiers), `QAWebWindow.swift:7` (a window subclass). Models depend on a view type: `PanelLayout.swift:47` and `WorkspaceManager.swift:1257` use `TOCView.Tab`.
- Stores show modal UI themselves (`ProjectOperationsStore`, `BrowserSession.swift:516-540`, `AgentBrowserRegistration.swift:158, 179`). `ProjectOperationsPresenter` (`WorkspaceManager.swift:5840`) is the right pattern; use it everywhere.
- Models reach into `Bridge/` for rendering services (`PrototypeScreenshots`, `BookPDFRenderer`) and for a log helper (`InsightSession.swift:1121`).
- Views do file work: 31 `FileManager` uses in 16 view files, with create and trash in `FileTreeView.swift:1098, 1250, 1384`, and a network call in `DDESettingsView.swift:518`. Four view models are declared inside view files.

### AR-23 Names do not signal role (medium, M, incremental)

"Model" names both observable view models (`QAModel`, `QARunModel`) and plain value bags (`ArchitectureModel`, `FeatureModels`). Observable classes use 13 `Store`, 11 `Model`, 6 `Session`, 4 `Controller` and about 20 with no suffix. "Client" is an observable class, a struct and an enum namespace in three places. Grab-bag files hold 21-27 types each (`UIStudioModels`, `SemanticModels`, `GitHubClient`, `QAScenario`, `ProjectWorkflow`).

Convention to adopt: `*Store` = persistence, `*ViewModel` = observable UI state, `*Client` = stateless I/O, `*Coordinator` = cross-feature flow, plain nouns = values.

### Target structure

```
MarkView/
  App/            MarkViewApp, WindowComposition (composition root), window session
  Core/           Foundation only; first local package (MarkViewCore)
    Subprocess/  Files/ (AtomicFile, paths, watcher)  FrontMatter/  Logging/
    Settings/ (DefaultsKey registry)  Hashing/  TextDiff/
  Platform/
    AI/           AIOperation runner, CLICompletion, ACP, AssistantProvider registry, usage
    Git/          GitClient, GitHubClient (DTOs split out)
    Terminal/  Dictation/
    WebBridge/    WebHost factory, typed bridge, scheme handlers
    AgentToolServer/   control server + tool declarations with their handlers
  Workspace/      Domain (tabs, DocumentState, FileNode) / Services / UI
  Features/
    Lifecycle/ (features, issues, bugs, workflow, cycle time)
    QA/  UIStudio/  Cockpit/  Prototype/  Research/  Deployments/
    Architecture/ (X-Ray, change review)  Insight/ (semantic DB, GraphRAG)
    Browser/  Book/  ProjectOps/  Discussion/  Remote/  Appearance/ (themes, backdrops, layouts)
      each:  Domain/ (values, pure rules)  Services/ (stores, clients, AI, runners)  UI/ (views, view models)
```

Dependency rule: `Features -> Platform -> Core`; `Workspace` depends on `Platform` and `Core`; features reach the workspace only through protocols defined below them; nothing depends on `App`. Local package candidates in order of readiness: `MarkViewCore`, the Lifecycle domain core, the QA domain core, UI Studio simulation, the Remote protocol. (That each compiles in isolation is not verified; many are already compiled alone by the test scripts.)

## 5. Sharing: what is implemented many times

### AR-24 No shared file and logging infrastructure (high, M-L)

- `FileManager.default` 465 times (426 in Models); `write(to:` 115 times. About 11 writes are not atomic (`WorkspaceManager.swift:1969`, `:3773`, `AICallLog.swift:47`, `DeploymentStore.swift:140`, `BrowserSession.swift:390`, ...). Atomic writes are otherwise written inline 99 times with one helper in existence.
- `try?` appears about 1,130 times in Models (190 files; `UIStudioSession` 58, `WorkspaceManager` 50, `ArchitectureStore` 48). There are 52 typed error enums but 36 `@Published` string error fields: most failures become a string or nothing.
- Path containment is checked inline 155 times in 66 files with three private helpers; each copy uses `standardizedFileURL`, which does not resolve symlinks.
- `".dde"` is a literal 56 times in 32 files; 14 `slug` functions in 11 files; front matter has one real parser and seven hand scans of `---`; 84 `JSONEncoder()` and 81 `JSONDecoder()` with 42 date-strategy settings and only three shared factories.
- File watching: three FSEvents implementations, two dispatch-source ones, nine polling timers, four hand-rolled debouncers.
- Logging: `NSLog` 119 calls; four copies of a synchronous append to `~/markview_debug.log` (41 calls, never rotated, on the main thread); the `/tmp` diagnostic file; plus `AICallLog`, `StudioLog`, `LifecycleLog`. No `os.Logger`. Four log files grow without bound.

Fix: `Core/Files` (`ProjectPaths`, `contains(_:root:)` that resolves symlinks, a throwing `AtomicFile.write` with optional lock and permissions, one JSON codec, one debounced watcher, `JSONLinesFile` with rotation, generalised from `IssueTransitionLog.swift:129`) and `Core/Logging` (one facade over `os.Logger` with categories and privacy markers).

### AR-25 About 12 separate "run a process" implementations (high, M)

`Process()` is created in 17 files. One-shot runners with different guarantees: `CLIToolLocator.run` (timeout, sleep poll), `ArchitectureScanner.runTool` (synchronous, no timeout, stderr dropped, 22 call sites), three variants in `GitClient` (no timeout), `StudioProcess.run` (unbounded wait that hangs if a killed child leaves a grandchild holding the pipe), `ProcessRunner` in `DeploymentExecutor` (timeout, output cap, bounded drain; a `timedOut` flag written without the lock), `GitHubClient` (52 call sites), and five more without timeouts. Streaming ones: `CLICompletion`, `ACPAssistant`, `CockpitChild`, `RemoteCommand`, the indexer. The project rule about draining pipes and never waiting on the main thread is enforced only by each author remembering it; AR-06 and AR-07 are the two places it slipped.

Fix: one `Subprocess.run(executable, arguments, cwd, environment, stdin, timeout, outputCap) async` with concurrent drain, TERM then KILL, a bounded drain wait and task cancellation; `ProcessRunner` is the closest base. Port the 11 one-shot sites; mark the synchronous runner unavailable from the main actor.

### AR-26 Every feature re-implements the assistant call pipeline (high, L)

- `CLICompletion.run` is called at 54 sites in 27 files. JSON schemas are hand-written dictionaries: 144 object literals in 38 files. Answers come back as `Any?` and are cast by hand in 24 feature files (291 `as? [String: Any]` in Models); only 12 sites decode with `JSONDecoder`.
- At least 12 files carry their own validate-and-ask-again loop (five copies inside `PrototypeAI.swift` alone). "Take the outermost braces" JSON salvage exists four times. Ten files translate activity events into their own stage strings. 34 busy/progress and 36 error/notice published fields are per feature. Usage is recorded by hand at 34 of 54 call sites (which of the rest go unrecorded is not verified). Timeouts are 76 literals from 180 to 900 s. 53 system prompts are scattered; `AIPrompts.swift` holds only the terminal prompts.

Consequence: a rule such as "retry with the problems listed" or "Codex needs strict schemas" has to be re-applied in about 25 places, and a schema can drift from its parser silently because a missing key only fails a cast.

Fix: one typed layer above `CLICompletion`:

```swift
struct AIOperation<Input, Output: Decodable> {
    let label: String
    let system: String
    let prompt: (Input) -> String
    var validate: (Output) -> [String] = { _ in [] }   // problems to send back
    var policy = AIPolicy(attempts: 3, timeout: 300, effort: nil, web: false)
}
// One runner owns: schema derived from Output, decoding, the repair loop, one AIProgress stream,
// cancellation, the call log and usage accounting.
```

Migrate feature by feature, starting with `PrototypeAI` and `FeatureAI`. It deletes the retry loops, the salvage parsers, the activity translators and most cast chains.

### AR-27 Web-side copies (medium, M)

Seven HTML escape functions under five names (the one in `markview-data.js:72` does not escape the apostrophe), 97 `innerHTML` sinks in 17 files, six wheel pan/zoom implementations, no shared debounce (14 ad-hoc timers), three private DOM builders beside 215 raw `createElement` calls in `markview-architecture.js`, four different wrappers for posting to native, 56 empty `catch {}` blocks. On the Swift side there are ten `WKWebView` hosts with seven navigation-policy and eight message-handler implementations; a weak handler proxy exists in two of them while the editor registers its bridge strongly.

Fix: one `mv-kit` module (escape, `h()`, debounce, a pan/zoom controller, `native.post`) and one Swift `WebHost` factory (configuration, weak handler, first-paint theme script, navigation policy, the JS call helper of AR-04).

## 6. Web editor and bridge

### AR-28 The bridge contract is stringly typed and mirrored by hand (high, L)

JS to Swift: 29 message types handled in one switch (`WebViewBridge.swift:120-353`; `researchMap` appears twice), three of which are sub-protocols (`arch` with 45 actions at 73 call sites, `code` with 15, `researchMap` with 16). Swift to JS: 71 evaluate calls in 15 files against about 32 `window.*` entry points. The only schema is comments and a stale doc table. Payloads are `[String: Any]`; for the three sub-protocols the bridge checks only that `action` is a string and hands the raw dictionary to `WorkspaceManager` (52 string cases in `handleArchitectureAction`), so the validation the project rules require "at the boundary" happens, if at all, deep inside the largest class. Dead code recorded earlier is still there (`BridgeMessage`/`AnyCodable`, `textChanged`, `requestHTML`, `preparePrintLayout`, `restoreEditLayout`).

Fix: one `bridge/messages.json` (type, direction, payload schema, action enums) that generates Swift `Codable` types with a single decoder used in the message handler, and a JS `native.post` with constants and JSDoc types. Unknown or invalid messages are rejected and logged in one place. Migrate type by type, `arch` first. `UIStudioBridge.swift` (`parseRequest`/`parseEvent` returning a rejection) is the in-house model.

### AR-29 No module system; behaviour depends on script order and monkey-patching (high, L incremental)

59 script tags; the first-party files are classic scripts sharing one global scope with 85 `window.x =` assignments. Entry points are wrapped by later files: `setContent` is reassigned in four files, `setTheme` in three. `index.html` carries 1,294 lines of inline CSS. No lint, no types, no bundling for the shipping JS. The three largest files are single closures: `markview-architecture.js` (3,628 lines, 147 functions, 22 hard-coded colours, no theme variables), `markview-research-map.js` (2,845; its layout is already split out and tested, which is the model), `markview-ui-studio.js` (2,998; a runtime injected into the user's page that mixes network simulation, third-party stand-ins and the selection overlay).

Fix: `tools/web-vendor` already runs esbuild. Add an entry file that imports the existing files in today's order and emits one bundle (no behaviour change); then convert file by file to `import`/`export`, replace the wrap chains with a view registry (`views.register({ enter, leave })`), and add `tsc --checkJs` and ESLint to CI. Also move the 19,351 first-party lines out of `vendor/js`, which is a misleading home.

### AR-30 `EditorWeb/` is dead weight (low, S)

One commit ever (the initial release, 2026-03-31) out of 1,247. About 1,700 lines of TypeScript on a different engine (Milkdown) with an interface incompatible with the shipping globals, covering roughly 9% of what ships. `EDITOR_IMPLEMENTATION.md` is from the same commit and describes sandbox paths and a CDN design that no longer exist. `CLAUDE.md` still spends a paragraph and a verification recipe on it.

Recommendation: delete `EditorWeb/` and `EDITOR_IMPLEMENTATION.md` and the `CLAUDE.md` text about them. Adopting it would mean rewriting the editor; AR-29 modernises the code that actually ships.

## 7. Extensibility: registries, data files, and whether to build plugins

The owner asked whether themes, welcome screens and layouts should become a plugin system. Measured cost of adding one more of each today:

| Extension point | Edit sites today | Problem | Mechanism to adopt | Effort |
|---|---|---|---|---|
| **Tool tabs** (Git, QA, Cockpit, UI Studio, ...) | **9 parallel lists** in 6 files plus an `openX()` in `WorkspaceManager` | Drift is visible: Workflow has three different icons, QA and UI Studio two each; Git, Workflow and Cockpit have no menu command; Cockpit has no welcome tile; shortcuts are written three times; one case list in `ContentView` already lacks `.data` | In-code registry of `ToolDescriptor` | M |
| **Themes** | about 12 sites in 5 files (5 exhaustive switches and 2 hand lists in `AppTheme.swift`, a ~56-token entry in `markview-themes.js`, 3 test files) | The same colours live in Swift and JS (820 hex literals), kept equal only by a test | **Data files**: one JSON per theme, bundled plus a user folder | M |
| **Layouts by situation** | nothing exists | The state model does: `WorkspacePanelState` and `restoreWindowState` already capture and apply panels | **Data files** on top of the tool registry | M |
| Welcome backdrops | 5 sites in 2 files plus the scene itself (four scenes in 6.25.0 cost 6 lines of bookkeeping and 753 lines of scene code) | The enum mixes scenes with modes (`project`, `shuffle`, `off`); two coding styles | Small in-code registry, one file per scene | S |
| Welcome tiles | 4 sites in 2 files | Shortcut text typed by hand | Derive from the tool registry | S |
| MCP tools | declaration is data, dispatch is a separate string switch; tests assert exact totals (42, 29, 18) | every new tool breaks a count | Handler closure beside the declaration; tests assert uniqueness and schema validity | S-M |
| File types | one central switch plus 63 scattered extension checks | no table | One Swift table: extensions -> type, tab factory, icon | S-M |
| Assistants | 34 switches in 12 files, 31 more comparisons, the list re-declared in four other enums | adding Antigravity touched 11 files | `AssistantProvider` protocol and registry | M-L |
| Workflow statuses, templates | already data | none | keep; it is the model | - |

### Recommendation: registries and data files, not plugins

**Do not build a real plugin system** (loadable bundles or scripts). The app is unsandboxed, signed with hardened runtime and has no library-validation exception: loading third-party code means weakening the signature of an application that holds API keys and document contents. A script API would need to stay stable across 150k lines that change daily. There is one developer and no plugin authors. What a person can realistically author (themes, layouts, workflows) is data, and data files give that without any of the cost.

Three things to build, in this order:

**1. Tool registry (AR-31, M).** One descriptor per singleton tool tab; toolbar, View menu, welcome tile, tab icon and title, and session restore are generated from the list. Document tabs keep `TabKind`.

```swift
struct ToolDescriptor: Identifiable {
    let id: String                       // "qa"; also the saved-session key
    let title: String, symbol: String
    let shortcut: KeyboardShortcut?
    let needsProject: Bool, restorable: Bool
    let welcome: (section: WelcomeSection, hint: String)?
    let open: @MainActor (WindowContext) -> Void
    let view: @MainActor (WindowContext, OpenTab) -> AnyView
}
enum ToolRegistry { static let all: [ToolDescriptor] = [.git, .deployments, .workflow, .qa /* ... */] }
```

Risk: touches `ContentView` and the session format, which must keep decoding old archives.

**2. Themes as data (AR-32, M).** One JSON file per theme in `Resources/Themes/`, read by Swift, which passes the web tokens to the page (the first-paint injection point already exists in `EditorView`). `AppTheme` becomes a value with a string id. User themes go in `~/Library/Application Support/MarkView/Themes/*.json`, validated like workflow templates: an unusable file is listed with the reason and never rewritten. A stored id that no longer exists already falls back to Classic Dark.

```json
{ "schema": 1, "id": "nord", "name": "Nord", "summary": "Arctic blue-grey with frost cyan",
  "native": { "bg": "#2E3440", "bgSidebar": "#353C4A", "text": "#E5E9F0", "accent": "#88C0D0" },
  "web": { "t": { "codeBg": "#3b4252" }, "syn": { "keyword": "#9db8d6" }, "struct": {}, "term": {} } }
```

`isDark` is computed from the background's luminance. For user themes `web` could be optional with tokens derived from `native`; that derivation is a proposal and has not been compared with the hand-tuned values. Risks: first-paint flash, three test files to rewrite, persisted ids must not change.

**3. Layout presets (AR-33, M, after the registry).**

```swift
struct LayoutPreset: Codable, Identifiable {
    var id: String, name: String, symbol: String
    var panels: WorkspacePanelState        // existing type
    var openTools: [String]                // ToolDescriptor ids
    var focusTool: String?
    var trigger: Trigger?                  // .manual, .toolOpened("qa"), .projectPlatform("ios")
}
```

Bundled defaults plus `.dde/layouts/*.json` per project. Ship manual switching first: automatic triggers fight the rule that a window keeps its own state.

**Backdrops (AR-34, S):** split the mode (`off`, `shuffle`, `byProject`, `scene(id)`) from the scene and give each scene one file behind a small protocol (`id`, `title`, `symbol`, `build(context) -> [CALayer]`). Do not make scenes declarative or user-authored: each is 100-400 lines of bespoke Core Animation, and a data language for that would be a second animation engine.

**Assistants (AR-35, M-L):** an `AssistantProvider` (identity, locating and probing, model catalogue, one-shot arguments and event parser or the session-protocol profile, terminal launch arguments, goal phrasing, optional usage source) with one registry; `TerminalProfile` becomes `provider | shell` and the three duplicate enums go. Behavioural, so not data. Worth doing when a sixth assistant is planned, or together with AR-26.

## 8. Persistence and domain model

### AR-36 No storage layer and no cross-process coordination (high, L)

Several windows, agent command line tools and MCP helper processes write the same `docs/` and `.dde/` trees. File locking exists in exactly one place (`CockpitResults.swift:33`); there is no file coordination. `FeatureStore.update` (`:333-345`) is an unguarded read-modify-write. Only seven types carry a schema version (`ProjectWorkflow`, `WorkflowTemplate`, `QAScenario`, `QARun`, `UIStudioScreens`, `UIStudioEnvironmentMap`, `ArchitectureModel`); feature and bug front matter has none.

Fix: typed repositories per feature returning `.ok / .damaged(reason) / .unsupported(schema)` exactly as `ProjectWorkflowStore` does, built on the `AtomicFile` helper of AR-24, and a `schema:` key in front matter.

### AR-37 SQLite runs entirely on the main actor (high, M; recorded, still true)

`SemanticDatabase` is `@MainActor` with 53 methods and 35 tables. Open, pragmas and DDL run on main; `busy_timeout = 5000` means the main thread can wait up to five seconds on the indexer process; `saveArchitecture` deletes and reinserts five tables; full-text search is called from a view (`TOCView.swift:188`). Only one read path is off the main thread.

Fix: make it an `actor` with one serial connection; callers already tolerate async.

### AR-38 The migration strategy is "delete the database" (medium, M)

`SemanticDatabase.swift:44-59` removes the database files when `user_version` is below 1 and then sets it to 1 unconditionally; the `applied_migrations` table is created and never used. X-Ray groupings live in this file, so a version bump discards them. A fallback path keys the database by the folder's last path component, so two folders with the same name share one.

Fix: an ordered migration list keyed by `user_version`; key the fallback by a hash of the path.

### AR-39 Domain model quality varies; copy the best (medium, L)

Best: `ProjectWorkflow` + `ProjectWorkflowStore`, then `QAStore` and `CockpitRunStore`. Middle: `FeatureStore` (pure parsing, a lossless-rewrite guard, but synchronous I/O and git on main). Worst: `ArchitectureStore`. New feature work should follow the first three: pure values and rules, a small store with typed results, the observable object last.

## 9. Security boundaries

Beyond section 2:

### AR-40 The local control socket trusts what the client says (medium, M)

`BrowserControlServer` listens on a unix socket in the per-user temporary folder with mode `0600`, which is right against other users. But it performs no peer check: `pids`, `cwd`, `folderDeclared` and `cwdTrusted` come from the request, and `cwdTrusted` defaults to true. `by_user` (the mark that a decision belongs to the person) is a boolean the agent supplies (`ControlToolRunner+Flow.swift:113, 235`). Any process of the same user, or a prompt-injected agent, can drive signed-in browser tabs, start agents and "approve" person-only steps. The Cockpit gate keys on the client-supplied `pids` and looks spoofable the same way (not verified further).

Fix: derive the peer pid in the server, issue a per-window token to the agents the app launches, and require a native confirmation for `by_user` actions.

### AR-41 Platform posture (medium, S-M)

Sandbox off (by design). Hardened runtime is applied only by `release.sh`, not in `project.yml`. App Transport Security allows arbitrary loads (`Info.plist:212`); scope it to web content. Approved deployment and remote commands run as one string through a shell (`DeploymentExecutor.swift:153`, `RemoteCommand.swift:28`): this is the documented exception, and its safety rests on the approval UI and on regex blocklists that cannot be complete. Full-permission flags are passed to all five agents (`AIAssistants.swift:72-76`; S4). Other editor settings: `img-src` allows any `https:` image (remote tracking), and navigation policy allows every `.other` navigation.

## 10. Concurrency and performance

### AR-42 Main-thread blocking reachable from views (high, M)

Worst paths by reading, not profiled: all SQL (AR-37); the 2 s timer that stats every open tab and re-reads changed files in full (`WorkspaceManager.swift:5455-5483`); `hasMarkdownFiles` walking the tree during menu rendering (`:931`, from `ContentView.swift:1181`); a full workspace enumeration inside `ForEach` in a view body (`GraphCreatorSheet.swift:49, 125-129`); a full-tree enumeration as a lookup fallback (`TOCView.swift:209`); `FeatureStore.reloadSync` falling back to a full load after writes (`:277-286`); `excludeFolder` deleting per file in SQL (`WorkspaceManager.swift:965`); single-file indexing on main (`:2218-2248`, `:3833`); whole-file reads in the main-actor `GraphRAG` (`:160, 251, 589`); `debugLog` opening and closing a file on every call (`:726-736`, 41 call sites).

### AR-43 Concurrency checking is at the language default (medium, L)

`SWIFT_VERSION` is 5.9 with no `SWIFT_STRICT_CONCURRENCY`, so checking is minimal. Counts: 32 `@unchecked Sendable` classes guarded by about 35 lock or queue sites, 4 `nonisolated(unsafe)` (on mutable statics in `DeploymentExecutor.swift:161`, `UIStudioServer.swift:156, 250`), about 30 mutable statics, 10 actors. Three observable objects lack `@MainActor` (`FileNode.swift:17`, `WindowUIState.swift:68`, `TabBarView.swift:267`). `DeploymentExecutor.swift:101` writes a flag from another thread without its lock. Three sleep polls block worker threads.

Path: set `targeted` per module as each becomes a package and fix warnings there; convert lock-plus-unchecked services to actors (AR-25 and AR-26 remove most of them); then `complete`.

## 11. Tests, CI, build, repository

### AR-44 Tests are many scripts, not a system (high, M)

- `tools/tests`: 166 shell scripts and 200 Swift files (47,571 lines). 156 scripts list application source files by hand; none uses a pattern. When a file gains a dependency the app build stays green and the script stops compiling (recorded twice in `tasks/lessons.md`).
- No run-all script and no map from a changed file to its suites. The 14 workflows reference 60 distinct scripts, so **106 of 166 run only when someone remembers them**.
- 81 application type names are redefined as stubs (125 definitions; `CLITool` nine times, `SemanticDatabase` six). A stub that disagrees with the real type still compiles, and the test passes against behaviour the app does not have.
- 130 test files define their own `check(...)` in at least 12 signatures. Tests assert exact totals of MCP tools.
- Summed over scripts, about 311,000 application lines are compiled per full pass (twice the app); 102 scripts use `-O`.
- Coverage gap (upper bound, by file name): 143 files, 59,625 lines, are named by no script, including `ArchitectureStore`, `InsightSession`, `FeatureAI`, `SemanticDatabase`, `FeatureStore`, `WebViewBridge`; `WorkspaceManager` is read only as text.

Path that keeps everything running meanwhile:

1. `tools/tests/run.sh [--changed <ref>]` driven by one manifest (suite, its sources, kind: pure / needs a GUI session / live assistant). CI and local runs share it.
2. `Packages/MarkViewCore` with `swift test`; move the most recompiled pure files first (`FrontMatter`, `IssueListing`, `FeatureVocabulary`, `ProjectWorkflow`, `IssueLifecycle`, `CockpitPlan`, `CycleTime`, `AgentUsage`). The compiler then enforces dependencies and each module builds once. This is the first package dependency of the app target and so needs the owner's approval.
3. Port each script's main to a test case in its package and delete the script. One `TestSupport` target with one fake per protocol replaces the stubs.
4. An app-hosted test target for the GUI and WebKit suites. Live assistant scripts stay manual.

### AR-45 CI repeats cold builds and never cancels (high, M)

Three suite workflows trigger on any `MarkView/**` change; six end with their own uncached Debug build; only `build-release.yml` uses a cache and it does not run on pull requests. One commit triggered up to 10 workflows. No workflow has a concurrency group (0 of 14), so superseded pushes keep running. Suites are duplicated between workflows (`window-session-tests`, `bug-validity-tests`).

Fix: one `ci.yml`: a job that selects suites from the manifest of AR-44, one cached build, one macOS job running the selected suites, the Go and relay jobs kept separate, and `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }`. At most three jobs per push.

### AR-46 `project.yml` is declared the source of truth but the project file is edited by hand (high, M)

`CLAUDE.md` and `setup.sh` (`xcodegen generate`) say one thing; `tasks/lessons.md` says not to run XcodeGen here because it rewrote every identifier, and records a hand edit that corrupted the file. New files are added to `project.pbxproj` in four places by hand (as 6.25.0 did). Both currently agree on sources.

Decide one way: generate the project in CI and `release.sh` and stop committing it, or drop XcodeGen and delete `setup.sh`. Packages shrink the problem either way.

### AR-47 Build phases and scripts (medium, S-M)

- The Cockpit runtime phase runs on every build: it needs Go, downloads a pinned PostgreSQL image on first run, then mounts it and runs six `go build` commands each time. The verification build in `CLAUDE.md` therefore needs Go and the network, undocumented. Declare inputs and outputs so Xcode skips it.
- Editor assets ship twice (flat into `Contents/Resources` and again under `Resources/Editor/`, about 10 MB); four stale scaffold documents under `MarkView/` are bundled into the app.
- `install.sh` still force-kills the app, signs without a team and copies a key from a container that is no longer used; `release.sh --install` does the job properly. `tools/importance-check.sh` reads a deleted file. `bump-version.sh` does not verify that its edits matched.
- No compiler or lint policy: no warnings-as-errors, no SwiftLint or SwiftFormat, no `.editorconfig`.
- `vendor/MANIFEST.txt` lists none of the newer bundles and still says `html: false`. The DMG bundles PostgreSQL 16, the Temporal server and embedded-postgres with no third-party notices file.

### AR-48 Dead code and clutter (low, S)

`EmbeddingClient` is still constructed (`WorkspaceManager.swift:462`); `IncrementalCompiler`, `DependencyGraphScheduler` and a two-line `SemanticModel.swift` remain; the dead bridge code of AR-28. At the top level: `QUICKSTART.md` and `EDITOR_IMPLEMENTATION.md` (stale), `EditorWeb/`, a 3.5 MB presentation PDF, `work/` (123 tracked spec files), ad-hoc `TestFiles/`, an empty `lsd/`. Locally: 3.4 GB in `build/` with 12 old installers, 13 worktrees, 48 local and 35 remote branches almost all merged.

### AR-49 Documentation drift (medium, M)

`docs/architecture` describes 2.17.0 and carries about 1,350 `file:line` citations; five of six spot-checked have drifted. `build-release-testing.md` lists 6 test scripts where there are 166. `editor-and-bridge.md` still describes libraries on a CDN that are now vendored. `tasks/todo.md` is 5,961 lines and `tasks/lessons.md` 2,024, both read at session start and containing superseded rules. `CLAUDE.md` is outdated on XcodeGen, on `EditorWeb` and on the vendor list, and the agent memory holds instructions that contradict it ("main directly, no pull requests") while recent history uses pull requests.

Fix: cite symbols, not lines; stamp each architecture document with the commit it was checked against; rotate `todo.md` by month into `tasks/archive/`; distil lessons into a short rule list by topic; reconcile `CLAUDE.md` with practice.

## 12. Roadmap

Each phase leaves the app shippable. Phases 0 and 1 are low risk and mostly independent; the later ones change architecture and need approval per the project rules.

**Phase 0: safety and correctness (days) — [Done].** AR-01 to AR-13 implemented and verified (`tools/tests/phase0-safety-tests.sh`).

**Phase 1: remove what misleads (days) — [Done].** AR-30 (delete `EditorWeb`), AR-48 (dead code, clutter), dead bridge code, `install.sh` / `setup.sh` / `importance-check.sh`, the repeated settings literals, the three view items out of Models, `TOCView.Tab` into Models, concurrency groups in CI, the test runner and manifest (AR-44 step 1) (`tools/tests/phase1-cleanup-tests.sh`).

**Phase 2: shared infrastructure, `Core` (2-3 weeks).** `Subprocess` (AR-25), `Files` and `Logging` (AR-24), the settings key registry (AR-18), the JS call helper and `WebHost` (AR-04, AR-27). Files first, then the first local package with `swift test` (AR-44 step 2).

**Phase 3: extension points (2-3 weeks).** Tool registry (AR-31), backdrop registry (AR-34), themes as data (AR-32), MCP tool handlers and the file type table, then layout presets (AR-33).

**Phase 4: shell decomposition (4-6 weeks, incremental).** `WorkspaceManager` steps 1-5 (AR-14), stop the change forwarding (AR-15), the composition root and protocols (AR-17), task bag and scheduler (AR-19), then steps 6-11.

**Phase 5: AI layer (3-4 weeks, feature by feature).** `AIOperation` (AR-26), `AssistantProvider` (AR-35).

**Phase 6: storage and concurrency (3-4 weeks).** SQLite actor and migrations (AR-37, AR-38), repositories and schema versions (AR-36), control socket authentication (AR-40), strict concurrency per package (AR-43), main-thread paths (AR-42).

**Phase 7: web modernisation (4-6 weeks, incremental).** Bundle entry with no behaviour change, typed bridge registry (AR-28), ES modules, `mv-kit`, split of the three large files (AR-29), sanitised rendering with a strict CSP completed.

**Continuous.** Feature folders one domain per change, leaves first (AR-20); merge Workflow into Lifecycle and extract the agent tool server (AR-21); naming convention on touch (AR-23); split `ArchitectureStore` and `UIStudioSession` (AR-16); CI consolidation (AR-45); docs (AR-49).

The ten changes with the best return for their cost:

1. AR-01 sanitised Markdown rendering.
2. AR-25 one `Subprocess`.
3. AR-31 tool registry (prerequisite for layouts, removes visible drift).
4. AR-15 stop window-wide re-rendering.
5. AR-44 step 1, the test runner and manifest (106 suites start running).
6. AR-45 one CI workflow with a cache and cancellation.
7. AR-32 themes as data, with user themes.
8. AR-14 steps 1-5 of the `WorkspaceManager` split.
9. AR-37 the database off the main thread.
10. AR-26 a typed assistant operation.

## 13. Decisions for the owner (Resolved 2026-11-15)

All ten owner decisions and the roadmap scope were answered and recorded in `docs/features/architecture-review-2026-11/decisions/DEC-001..DEC-010.md`:

- **Scope:** Implement all roadmap phases (Phase 0 through Phase 7 and Continuous items) sequentially (`REQ-001`..`REQ-008`, GitHub issue `#414`).
1. **Plugins (`DEC-001`, Accepted):** Accept "registries and data files, no loadable plugins" (section 7).
2. **Layout presets (`DEC-002`, Accepted):** Ship `Writing`, `Review`, `QA`, and `Cockpit` layout presets triggered only by explicit user choice, with no automatic triggers (preserving per-window layout state).
3. **User themes (`DEC-003`, Accepted):** Allow user theme JSON files in `~/Library/Application Support/MarkView/themes/` and derive web CSS tokens automatically when a theme specifies only native colours.
4. **`EditorWeb/` (`DEC-004`, Accepted):** Delete `EditorWeb/` and remove stale references (AR-30).
5. **XcodeGen (`DEC-005`, Accepted):** Drop XcodeGen, delete `setup.sh` and `project.yml`, and maintain `MarkView.xcodeproj` directly with local Swift packages reducing project file churn (AR-46).
6. **Local Swift packages (`DEC-006`, Accepted):** Approve introducing `Packages/MarkViewCore` as a local Swift package dependency of the `MarkView` app target (AR-44).
7. **Raw HTML in Markdown (`DEC-007`, Accepted):** Sanitise rendered HTML after parsing (strip `<script>` tags, inline event handler attributes, and dangerous URL schemes) and tighten the preview CSP by removing `'unsafe-inline'` from `script-src` (AR-01).
8. **CI (`DEC-008`, Accepted):** Consolidate CI checks into a unified `ci.yml` workflow with build caching and `concurrency: { group: ..., cancel-in-progress: true }` (AR-45).
9. **Control socket (`DEC-009`, Accepted):** Require per-window/per-instance token authentication on the control socket and native confirmation for `by_user` mutations (AR-40).
10. **Strict concurrency and lint (`DEC-010`, Accepted):** Adopt `targeted` strict concurrency checking and formatting configuration per package/target (AR-43, AR-47).
