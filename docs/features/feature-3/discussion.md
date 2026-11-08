# Discussion — Процессы разработки для каждого проекта

### Answer to Q-001 · 2026-11-08

Как новый процесс должен вступать в силу в существующих проектах?

B. Автоматически применить один стандартный шаблон ко всем существующим проектам.

### Answer to Q-002 · 2026-11-08

Какую роль релиз или развёртывание должны играть в завершении работы?

A. Проект отдельно выбирает для feature и bug, нужен ли релиз и какое доступное событие считается доставкой.

### Answer to Q-003 · 2026-11-08

Какие полномочия должна иметь новая политика на действия в GitHub?

A. Сохранить текущую синхронизацию issues; новые действия политики в GitHub выполнять после подтверждения.

### Answer to Q-004 · 2026-11-08

Может ли человек разово обойти условие перехода, заданное политикой проекта?

A. Разрешить человеку разовый обход условий с причиной, не меняя политику проекта.

### Answer to Q-005 · 2026-11-08

Какие правила должен содержать стандартный процесс, автоматически применяемый к существующим проектам?

A. Стандартный процесс воспроизводит нынешнее поведение для feature и bug.

### Answer to Q-006 · 2026-11-08

Какие подтверждения доставки должны поддерживаться в первой версии?

A. Поддержать опубликованный GitHub release с автоматической проверкой и ручное подтверждение человеком другого события доставки.

### Answer to Q-007 · 2026-11-08

Как выбирать разные правила для отдельных работ внутри одного проекта?

A. Человек выбирает для задачи один из настроенных вариантов правил.

### Answer to Q-008 · 2026-11-08

Как изменение выбранного варианта правил должно влиять на уже начатые задачи?

A. Новые правила применяются ко всем последующим переходам, в том числе у начатых задач.

### Answer to Q-009 · 2026-11-08

Что делать, если пользователь удаляет статус или вариант правил, который сейчас используется задачами?

B. При удалении потребовать от человека выбрать замену для затронутых задач.

### AI updated the requirements · 2026-11-08

DEC-016, DEC-017, DEC-018, DEC-019, DEC-020, DEC-021 written into REQ-005, the overview.

### AI updated the requirements · 2026-11-08

DEC-022 written into REQ-001, REQ-003, REQ-005.

### AI updated the requirements · 2026-11-08

DEC-023 written into REQ-001, REQ-002, REQ-003, REQ-005, REQ-006.

### AI updated the requirements · 2026-11-08

DEC-024, DEC-025 written into REQ-001, REQ-003, REQ-005.

### Agent · 2026-11-08

Implementation notes (branch feat/feature-3-project-workflows). The status tables of features and bugs are now the data type ProjectWorkflow, kept in .dde/workflow/workflow.json; the standard workflow reproduces the previous tables and the unchanged policy, completion and GitHub suites pass against it. Rule variants are read by the policy, the evidence collector and the GitHub synchronization; completion, reopening, filters, badges, the bug basket and the agent tools read lifecycle roles. Assignments, start notes, delivery confirmations and replacements are records of the lifecycle journal (DEC-026 amended to say so). An independent review found and I fixed: a stale editor draft overwriting a newer save (the save now expects the revision the person edited), replacements that did not survive an interruption (the plan is written before the workflow file and finished at the next start), a completion rule without delivery evidence counting as verified (the workflow is now invalid without it), a hand-off that bypassed the workflow, the adoption pass that lived only in memory (now a marker file), and editor rows that could index a removed row. Proposed for your decision: DEC-026 (amended), DEC-027, DEC-028, DEC-029, DEC-030 and the new DEC-031 (guided specification flows keep the standard stage names). Not done and left unticked: REQ-005 criterion 1 (a person picks a variant for each NEW item: new items take the default variant and the person can change it in the Lifecycle section, there is no picker in the creation dialogs), criteria 13-14 (they wait for DEC-028 to be accepted), and the criteria that need the editor and the replacement flow to be tried in the running app (REQ-001 4 and 6, REQ-002 1, 7 and 8, REQ-005 3, 5 and 6). The editor, the variant picker, start by note and delivery confirmation compile and are reviewed but have not been exercised in the running app.
