---
type: bug
id: BUG-050
title: Code-mode prototype of a large app is one generic screen, far from the original (broker-fabric StrikeDesk)
status: fixed
branch: fix/bug-050-code-prototype-fidelity
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Code-mode prototype of a large app is one generic screen, far from the original (broker-fabric StrikeDesk)

## Summary

"New Prototype from Code" on broker-fabric/apps/strikedesk (an Electron/React trading terminal) produced a prototype that Boris judged "infinitely far from the original". It is one screen (36 KB of JavaScript) with an accounts table, a list of tab names and an empty main area, on an 8 KB generic stylesheet. The original renderer has 97 .tsx and 356 .ts files and 385 KB of CSS in 43 files, with 20+ widgets (OptionDesk, ChainTable, PositionMonitor, SPXChart...). The planner states twice that it did not read most widgets and the pipeline accepts that partial plan.

## Steps to reproduce

1. Open broker-fabric in MarkView and choose New Prototype from Code with the source apps/strikedesk.
2. Let the build and the 'Synced from code' run finish (docs/prototypes/strikedesk, v3).
3. Open the preview and compare it with the real StrikeDesk window.

## Expected

The preview looks and is organised like the real application: its own theme (the app's CSS and fonts), its docked panels, and the main widgets (option chain, positions, order book, chart, journal) present with believable content. What was not reproduced is reported as a coverage figure, not hidden.

## Actual

Evidence from docs/prototypes/strikedesk and ~/Library/Application Support/MarkView/ai-calls.jsonl (2026-11-03 04:44-04:58 UTC): (1) The plan is one screen, "Торговое рабочее пространство", and the plan's own assumptions say it is partial: the trading widgets and most modal windows were not studied, 491 further files not covered. (2) prototype:plan is one call, 50-98 s, medium effort, ~405K input tokens, 3.6-6K output tokens; nothing checks coverage or asks for another pass. (3) The whole workspace is written by one prototype:screen call at low effort: 84 s, 96K input, 10K output tokens, 36 KB of JS; the original's OptionDesk.tsx alone is 84 KB, ChainTable.tsx 83 KB, PositionMonitor.tsx 60 KB. (4) styles.css is 8 KB of generic shell, card, modal and toast rules; the original theme is 43 CSS files (theme/variables.css, topbar.css, dockview-overrides.css...), none reused. (5) Rendered with the real preview loader: the first view is an accounts table plus a tab list; the main panel reads "Демонстрационные котировки опционов недоступны" (option chain empty). The page loads with 0 JavaScript errors, so this is fidelity, not the BUG-047 error.

## Environment

MarkView 5.1.0, Codex gpt-6.1-terra (plan medium, writers low), prototype mode code, source apps/strikedesk in /Users/boris/github.com/broker-fabric. Only the first view was rendered; other tabs were not clicked.

## Cause

Verified on the real project (the real `PrototypeFiles.inventory` run on broker-fabric, sources `apps/strikedesk`): the web-interface inventory has 891 files; the planner is given only the first 400 sorted by path (`inventoryLimit`), then "+491 more files not listed" (the same 491 the plan's own assumptions quote). The cut falls inside `renderer/components/Settings/`, so everything alphabetically later is invisible: `widgets/` 0 of 112 files (1.15 MB), `theme/` and `styles/` CSS 0 of 21 files (131 KB), `data/`, `hooks/` and the rest. 143 of the 400 listed files are tests (`__tests__`, `.test.`; 927 KB). With no widget or stylesheet on the list the plan covers the shell and the accounts overview as one screen, calls itself partial, and nothing re-plans: the build writes that one screen at low effort and an 8 KB generic stylesheet. Contributing design limits, all in `PrototypeAI.swift`: `screens` is capped at 10 and modal flows go inside their screen, so a window of docked widgets cannot become many entries; the original CSS (43 files, 385 KB) is never copied, the shell writer invents a design system under a 20 KB cap; the plan is accepted without any coverage check.

## Resolution

Version 5.2.0. A code-mode prototype is now built from the whole interface, with the app's own CSS and one screen per widget:

- **Planner input.** `PrototypeFiles.inventory` lists every UI source file grouped by folder, leaves tests, stories and mocks out (counted in one
  line), always keeps stylesheets and, past a safety cap of 1200 files, drops the smallest files of a folder and says so per folder.
  `original/` of the site is never shown to the assistant.
- **Planner output.** The plan carries `styles` (the stylesheets the interface loads), `embedded` (a widget or modal written as a screen of its
  own) and `hosts` (what a host screen lays out); a code-mode plan may have 40 screens. With several front ends in the folder only the one the main
  window loads is planned.
- **Original CSS, verbatim.** `PrototypeStyles` copies the listed stylesheets, what they `@import` and the fonts and images their `url()` names to
  `site/original/` (and package stylesheets such as Dockview's from `node_modules`), links them before `styles.css` and reports what it could not copy.
  `styles.css` becomes a short bridge.
- **Widgets inside a host.** The shell offers `App.renderScreen(id)`; the host screen lays widgets out as the original layout code does, modals open from
  their controls; hosts, widgets and modals run at medium effort and read their whole source files.
- **No assistant for widget pages.** A component that is an embedded screen gets its isolated page from `PrototypeEmbedded.page`.
- **Coverage.** The build reports how many UI source files of 2 KB or more the plan names or the writers read, with the largest uncovered ones.

## Verification

- Real project (broker-fabric, `apps/strikedesk`): the new listing has 569 files, none omitted, widgets 112 of 112, theme CSS 21 of 21 (before: 400 of
  891, widgets 0 of 112). Two live planner calls with the `claude` CLI: 17 and then 26 screens (15 registered widgets, 2 shell strips, 8 modals, one host,
  the legacy `static/` front end left out as a gap), 22 root stylesheets which the copy widened to 42 plus Dockview's CSS, no copy gap.
- Standalone checks: `prototype-styles-tests.sh`, `prototype-embedded-tests.sh`, the widgets scenario of `prototype-deadline-tests.sh`, plus the existing
  prototype, ACP and CLI suites; Debug build.
- Not verified: a complete build with a real model (hosts and widgets written, then rendered). Boris chose to release and try it himself.
