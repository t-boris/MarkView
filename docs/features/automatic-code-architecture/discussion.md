# Discussion — Automatic Code Architecture

### Answer to Q-001 · 2026-11-02

Как запрошенная вкладка должна соотноситься с существующим X-Ray?

A: extend the existing X-Ray into the requested Code/Architecture experience instead of adding a separate tab beside it.

### Answer to Q-002 · 2026-11-02

Какие сценарии должны попадать в автоматически построенные sequence-диаграммы?

A: the agent chooses a few main scenarios itself, from the project's entry points, and shows their sequences. No manual scenario selection is required.

### Answer to Q-003 · 2026-11-02

Для каких кодовых баз первый выпуск должен гарантировать все три вида диаграмм?

B: analyze every language MarkView recognizes from the first release, and mark the incompleteness of the result explicitly (what was and was not understood) instead of guaranteeing all three diagram types for a fixed language list.

### Answer to Q-004 · 2026-11-02

Когда должен запускаться и повторяться автоматический анализ?

A: start the analysis when the project folder is opened and refresh it after code changes (background work whenever a project is open), with no separate Analyze command.
