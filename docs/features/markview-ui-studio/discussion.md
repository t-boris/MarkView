# Discussion — MarkView UI Studio

### Answer to Q-001 · 2026-11-04

Какую совместимость обещаем в первом релизе: предложенный React/TypeScript/Vite или стек конкретного вашего проекта?

Any Web app including electron apps

### Answer to Q-002 · 2026-11-04

UI Studio добавляется к Prototype Studio или заменяет её режим реконструкции из существующего кода?

B. Заменить создание прототипов из существующего кода новым режимом; прототипирование по требованиям сохранить.

### Answer to Q-003 · 2026-11-04

Первый релиз рассчитан только на доверенные локальные проекты или должен безопасно запускать непроверенный код?

A. В MVP запускать только доверенные локальные проекты; отдельно ограничивать секреты, симулируемые обращения и разрешённые подключения.

### Answer to Q-004 · 2026-11-04

Что означает «Any Web app including electron apps» в отношении исключённых SSR и серверных/нативных зависимостей: сохраняем эти исключения? 

Понимать «Any Web app» как независимость от клиентского фреймворка, а Electron — как его веб-интерфейс; сохранить исключения для SSR и серверных/нативных зависимостей.

### AI updated the requirements · 2026-11-04

DEC-001, DEC-002, DEC-003, DEC-004 written into the overview.

### Answer to Q-005 · 2026-11-04

Что делать с «Sync from code» и «Hand off to code» у ранее сохранённых реконструкций из кода?

A. «Sync from code» ведёт в UI Studio; «Hand off to code» остаётся; прототип помечен как историческая реконструкция.

### AI updated the requirements · 2026-11-04

DEC-005 written; REQ-001 links Q-005 and DEC-005.

### AI implemented the feature · 2026-11-04

Implemented on branch `feat/markview-ui-studio` (plan items I-1…I-8 under feature issue #287). Q-005 was the only point the specification left open and is answered (DEC-005). These are the readings the implementation relies on, so they stay visible:

• DEC-001, DEC-004, targets: UI Studio uses the launch discovery of Preview Web App, so no framework or bundler is required; a project is opened whenever it has a web dev server (Vite, webpack, Next, Angular, Svelte, Astro, Django, Rails, a static `index.html`…). Electron apps run their renderer through a web-only script or MarkView's Vite launcher, never `electron`. Next, Nuxt, SvelteKit, Remix, Astro, Gatsby and similar frameworks, Django and Rails are opened with a disclosure that requests the server makes itself are not simulated; Electron gets a disclosure that the main process, preload, IPC and native modules do not run and that their stand-ins (named after the preload's `exposeInMainWorld` calls) do nothing.
• Simulation boundary: only `fetch` and `XMLHttpRequest` with JSON bodies are simulated. GraphQL is reported as unsupported; WebSocket, EventSource and `sendBeacon` are reported and not opened (the dev server's own hot-reload socket is kept). Unknown requests are prepared by the project's assistant with read-only access, no web, a strict schema, a deadline and a second attempt with the validation problems, then registered atomically; a failure answers 503 with the contract and never passes the request on.
• DEC-003, trust: project processes run with the user's permissions, which the tab says in its header and in the trust popover. The page may reach only its dev server (localhost and 127.0.0.1, the same port, http and ws), data/blob/about and the addresses the user allows; it is a WebKit content rule list plus a navigation policy, stated as a connection policy and not operating-system isolation. The model policy is separate: assistant runs never get the web. Variables whose names look like credentials are removed from the dev server's environment (names listed, values never), and confidential fields are redacted before anything reaches the model, the log or an export.
• Storage: scenarios, the environment (rules, entities, seed, allowed addresses, confidential fields) and feature packages are configuration in `.markview/studio/` and can be committed. History, captures, selection pictures and the session log are local in `.dde/studio/`, which writes its own `.gitignore`, so pictures are never added to Git automatically.
• Selection: source locations come from what the development build exposes (React `_debugSource` or the component's stack in React 19, Vue `__file`, Svelte `__svelte_meta`, Angular dev metadata, `data-inspector-*` or `data-v-inspector` attributes). Without them the selection says so and still works by selector; canvas, frames and closed shadow roots are disclosed boundaries. After a change the selection is kept, remapped to a moved line, or cleared when the mapping became ambiguous.
• Edits: the assistant returns search/replace edits as data and never writes; MarkView applies them all or none, refuses them when a file or an unsaved editor tab changed since the request, retries once when a search text is missing or ambiguous, and undoes one operation with a three-way merge (a conflict writes nothing and can be opened in the editor). The revision identity is the commit plus a hash of uncommitted changes and of the unsaved buffers that were used.
• DEC-002, DEC-005: "New Prototype from Code…", the AI Tools entry and "Sync from code" open UI Studio. The reconstruction engine is no longer reachable from the interface; saved code-mode prototypes open as before with a "Historical reconstruction" badge, keep "Hand off to code", and are labelled historical for agents.
• Checks: `tools/tests/ui-studio-tests.sh` (pure modules), `ui-studio-web-tests.sh` (the page runtime in WebKit: requests, clock, zoom, selection with scrolling, replay, connection policy) and `ui-studio-session-tests.sh` (a real session against a running dev server), all in the "UI Studio Checks" CI workflow. The edit, question and preparation prompts were also run once against the real Claude CLI on a throwaway project: the edit matched the schema, each of its search texts occurred exactly once, and it put the spacing into the stylesheet rather than an inline style, the question changed nothing, and the prepared rule passed validation and answered the request.
