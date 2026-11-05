Metadata

<table style="width:100%;border-collapse:collapse;"><tbody><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">type</td><td style="padding:2px 8px;font-size:10px;">bug</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">id</td><td style="padding:2px 8px;font-size:10px;">BUG-101</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">title</td><td style="padding:2px 8px;font-size:10px;">Issues sorting has no visible effect</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">status</td><td style="padding:2px 8px;font-size:10px;">open</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">severity</td><td style="padding:2px 8px;font-size:10px;">medium</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">reporter</td><td style="padding:2px 8px;font-size:10px;">Boris Tsekinovsky</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">created</td><td style="padding:2px 8px;font-size:10px;">2026-11-05</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">provenance</td><td style="padding:2px 8px;font-size:10px;">Created from the bug intake</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">questions</td><td style="padding:2px 8px;font-size:10px;"></td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">- id</td><td style="padding:2px 8px;font-size:10px;">BQ-1</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">text</td><td style="padding:2px 8px;font-size:10px;">Что происходит, если в Issues выбрать Date и переключить Newest First на Oldest First?</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">why</td><td style="padding:2px 8px;font-size:10px;">Это поможет отличить сбой применения настройки от совпадения порядка по дате и приоритету.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">options</td><td style="padding:2px 8px;font-size:10px;"></td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">- label</td><td style="padding:2px 8px;font-size:10px;">Отметка меняется, порядок нет</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">text</td><td style="padding:2px 8px;font-size:10px;">При переключении Date → Newest First / Oldest First отметка в меню меняется, но строки остаются на месте.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">- label</td><td style="padding:2px 8px;font-size:10px;">Отметка тоже не меняется</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">text</td><td style="padding:2px 8px;font-size:10px;">Выбор другого направления не меняет ни отметку в меню, ни порядок строк.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">- label</td><td style="padding:2px 8px;font-size:10px;">Направление работает</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">text</td><td style="padding:2px 8px;font-size:10px;">Newest First / Oldest First меняет порядок; без эффекта только переключение Date / Priority.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">status</td><td style="padding:2px 8px;font-size:10px;">answered</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">answer</td><td style="padding:2px 8px;font-size:10px;">Меняется! Видимо только приоритет не работает, но перепроверь</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">- id</td><td style="padding:2px 8px;font-size:10px;">BQ-2</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">text</td><td style="padding:2px 8px;font-size:10px;">В каком workspace это происходит? Укажите 2–3 элемента в показанном порядке и версию MarkView.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">why</td><td style="padding:2px 8px;font-size:10px;">Конкретные элементы позволят проверить даты и приоритеты, а версия — сопоставить установленную сборку с исследованным кодом.</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">status</td><td style="padding:2px 8px;font-size:10px;">answered</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">answer</td><td style="padding:2px 8px;font-size:10px;">"vivaa-platform \nFeatures вообще никак не сортируются, баги сортируются по дате"</td></tr><tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">issue</td><td style="padding:2px 8px;font-size:10px;">"#295"</td></tr></tbody></table>

# Issues sorting has no visible effect

## Summary

Sorting in Issues reportedly has no visible effect for either Priority or Date. Code inspection confirms that both controls are wired to a shared sort model and that the view sorts its arrays before rendering. No root cause is confirmed; menu state changes and an affected item sample are needed to isolate the failure.

## Steps to reproduce

1.  Open the affected workspace and select the Issues sidebar.
2.  Expand a Features or Bugs section containing multiple items with different dates and priorities.
3.  Record the displayed order.
4.  Select Priority, then Date in the sort menu next to Filter.
5.  Compare the order after each selection. Also switch Highest First / Lowest First and Newest First / Oldest First to isolate direction handling; this diagnostic step is not yet confirmed by the user.

## Expected

Selecting a sort field or direction immediately reorders items within each section. Date uses updated, then created, then file modification time. Priority uses feature priority or bug severity; missing values stay last. Date direction reverses dated items and ID ordering for equal dates. Priority ties use newest date, then newest ID.

## Actual

The user reports that selecting priority or date sorting produces no visible change in the Issues list. This has not been reproduced during the read-only investigation.

## Environment

MarkView native macOS application; project supports macOS 13+. The local Issues sidebar is inferred from the described Date/Priority controls. Installed app version, macOS version, workspace and active filters are unknown. Repository configuration declares version 5.35.0; this does not establish the user’s installed version.

## Suspected code

-   `MarkView/Views/FeatureNavigatorView.swift:224` — sortMenu builds custom Toggle bindings from a captured IssueSort value and writes field/direction changes to the store. Primary inspection point for a selection that appears to do nothing; the bindings are not proven defective.
-   `MarkView/Views/FeatureNavigatorView.swift:88` — IssuesListView applies the selected comparator before rendering each section through ForEach. Inspect this path if the menu selection changes but the rows do not.
-   `MarkView/Models/FeatureStore.swift:33` — Publishes sort changes and persists/restores the selection per project. Relevant to state propagation or an unexpectedly restored selection.
-   `MarkView/Models/IssueListing.swift:189` — Implements sorting, date fallbacks, priority ranks and tie breakers. Equal or missing priorities can preserve date order and make a field change appear ineffective.
-   `MarkView/Models/FeatureModels.swift:627` — Supplies the feature and bug metadata used as sort keys. Inspect affected records here if their effective keys differ from what the user expects.
-   `docs/features/issues-panel-status-filters-sorting-status-display-and/requirements/REQ-002.md` — Defines the required date/priority sorting behavior and both directions.
-   `docs/bugs/BUG-017-issues-list-appears-in-an-unexpected-sort-order.md` — Documents an earlier same-day date tie-breaker bug and its fix. Related history, but it does not establish the cause of both sorting modes having no visible effect.

## Likely causes

-   Unconfirmed: sort menu actions may fail to update the effective selection or refresh the displayed list. Inspect the menu bindings first because both fields reportedly have no effect.
-   Unconfirmed: switching between Date and Priority can legitimately produce identical orders when priorities are equal or missing, or priority order already matches date order. Reversing date direction on distinct items would distinguish this from a broken control.
-   Confirmed implementation detail: Features and Bugs are sorted separately; sorting never moves an item across sections.

## Missing information

-   Whether the selected menu checkmark changes and whether reversing direction also leaves the list unchanged.
-   Specific affected items and their workspace, needed to compare the observed order with their metadata.
-   Installed app version and macOS version.

## Clarifications

**BQ-1** Что происходит, если в Issues выбрать Date и переключить Newest First на Oldest First?  
→ Меняется но только в багах! Видимо только приоритет не работает, но перепроверь

**BQ-2** В каком workspace это происходит? Укажите 2–3 элемента в показанном порядке и версию MarkView.  
→ vivaa-platform  
Features вообще никак не сортируются, баги сортируются по дате

## Original description

В Issues у нас есть возможность сортировки. Так вот, сортировка не работает. Я проверял ее и по приоритету, и по дате, и он вообще не меняет ничего.