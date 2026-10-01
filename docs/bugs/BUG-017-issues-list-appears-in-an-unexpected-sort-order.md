---
type: bug
id: BUG-017
title: Issues list appears in an unexpected sort order
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где и с какой настройкой сортировки вы увидели неправильный порядок?
    why: В приложении есть разные списки Issues; у сортировки локальных issues также сохраняются поле и направление.
    options:
      - label: Дата, новые сверху
        text: В левой панели Issues выбрана Date → Newest First.
      - label: Дата, старые сверху
        text: В левой панели Issues выбрана Date → Oldest First.
      - label: Приоритет
        text: В левой панели Issues выбрана сортировка Priority.
      - label: GitHub Issues
        text: Речь о списке GitHub Issues во вкладке Git.
    status: answered
    answer: Дата, новые сверху. В левой панели Issues выбрана Date → Newest First.
  - id: BQ-2
    text: Назовите 2–3 issues в том порядке, как они показаны, и в каком порядке вы ожидали их увидеть.
    why: Конкретные элементы позволят сверить отображение с их датами или приоритетами и воспроизвести расхождение.
    status: open
  - id: BQ-3
    text: Пришлите 2–3 issues в порядке, в котором они показаны, и в порядке, который вы ожидали. В каком workspace или по каким путям находятся их файлы?
    why: Конкретная пара и её файлы позволят сравнить показанный порядок с `updated`, `created` и временем изменения файла.
    status: open
issue: "#71"
---

# Issues list appears in an unexpected sort order

## Summary

The reported discrepancy is narrowed to Date → Newest First in the left sidebar Issues panel. Code review confirms the documented date fallback and separate sorting of Features and Bugs, but does not identify an incorrect comparison or establish a reproducible failure.

## Steps to reproduce

1. Open a workspace containing documented features or bugs.
2. In the left sidebar Issues panel, select Date → Newest First.
3. Inspect the order within the Features section or within the Bugs section.
4. Compare the order of a specific pair with each item's effective date. The pair and workspace are still needed to reproduce the reported discrepancy.

## Expected

Within each Features or Bugs section, Date → Newest First should place items with later effective dates first. The effective date is the parseable `updated` front matter value, otherwise `created`, otherwise file modification time. Equal dates are ordered by title, then ID.

## Actual

The user reports that the left sidebar Issues list appears in an unexpected order with Date → Newest First selected. No example items or observed sequence have been provided, so a sorting failure is not yet reproducible.

## Environment

MarkView native macOS app (macOS 13+), left sidebar Issues panel, Date → Newest First selected. App version, macOS version, workspace, and active filters are unconfirmed.

## Suspected code

- `MarkView/Models/IssueListing.swift` — Computes the effective date, parses front matter dates, and compares items in descending order with title and ID tie breakers.
- `MarkView/Models/FeatureModels.swift` — Supplies feature and bug front matter dates and file modification times to the comparator.
- `MarkView/Views/FeatureNavigatorView.swift` — Binds the selected Date → Newest First mode and sorts Features and Bugs separately before display.
- `MarkView/Models/FeatureStore.swift` — Loads and refreshes issue models and persists the per-project sort selection; relevant if the displayed data or selected mode is stale.
- `docs/features/issues-panel-status-filters-sorting-status-display-and/requirements/REQ-002.md` — Defines the expected date key and fallback order used to assess the report.

## Likely causes

- The implementation sorts by a parseable `updated` front matter date, falling back to `created` and then file modification time. A recently changed file can therefore appear below one with a newer front matter date; this is a possible explanation, not a confirmed cause.
- Date only values resolve to the start of the day. Items with the same effective date are ordered by title and then ID, which may look unexpected if the user expects edit time or creation order.
- Features and Bugs are sorted within separate sections. This could explain a comparison across sections, but the reported pair is unknown.

## Missing information

- Two or three specific items in their displayed order and the order the user expected; BQ-2 remains open.
- The workspace or document paths for those items, so their front matter and file dates can be checked.
- The app version and any active Issues filters, if the example cannot be reproduced from the identified workspace.

## Clarifications

**BQ-1** Где и с какой настройкой сортировки вы увидели неправильный порядок?
→ Дата, новые сверху. В левой панели Issues выбрана Date → Newest First.

## Original description

Почини сортинг в issues, там явно не работает подать, потому что я вижу, что порядок совершенно другой, в отличие от того, как я это делал.

## AI fix attempt

2026-09-29 · `fix/issue-workflows`: The Date → Newest First comparator and its existing regression checks match the documented `updated` → `created` → file modification time rule. No displayed issue pair, expected order, or workspace path was provided, so the reported discrepancy could not be reproduced or traced to a root cause. No code change or commit was made for BUG-017.
