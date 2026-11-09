---
type: bug
id: BUG-101
title: Issues sorting has no visible effect
status: done
severity: medium
questions:
  - id: BQ-1
    text: Какие 2–3 Features видны в vivaa-platform и в каком порядке при Date → Newest First и Date → Oldest First? Укажите их названия или ID.
    why: По конкретным строкам можно сопоставить наблюдаемый порядок с датами и проверить, должен ли он меняться.
    status: open
  - id: BQ-2
    text: Какие элементы и в каком порядке вы видите при Priority → Highest First и Lowest First? Укажите их приоритеты или severity, если они известны.
    why: Это позволит отдельно проверить сортировку по приоритету и исключить совпадение значений.
    status: open
  - id: BQ-3
    text: Какая у вас версия MarkView и включены ли текстовый фильтр или фильтры Issues во время проверки?
    why: Версия связывает наблюдение с кодом, а фильтры определяют набор сравниваемых строк.
    status: open
---

# Issues sorting has no visible effect

## Summary

The reporter says reversing Date order changes the Bugs list but leaves Features unchanged in vivaa-platform; Priority sorting is also suspected. Code inspection shows that both sections use the same selected sort model and comparator, but does not establish what happens in the installed app with this workspace. The issue remains inconclusive: it is neither confirmed nor shown to be fixed.

## Steps to reproduce

1. Open the vivaa-platform workspace in MarkView and select Issues.
2. Expand Features and Bugs and note any active filters.
3. Select Date → Newest First and record the order of multiple Features and Bugs.
4. Select Date → Oldest First and compare each section separately.
5. Select Priority → Highest First and then Lowest First, recording the order and priority or severity of the same items.

## Expected

Changing the sort field or direction immediately orders items within each section. Date uses a parseable updated date, then created date, then file modification time; equal dates use ID in the selected direction. Priority uses feature priority or bug severity; missing or unrecognized values remain last in either direction. Priority ties use newest date, then newest ID.

## Actual

The reporter observes that changing Date from Newest First to Oldest First changes the order of Bugs, but not Features. The reporter also suspects that Priority sorting does not work. The Priority behavior has not been isolated with a specific item sample, and the report has not been reproduced during this read-only investigation.

## Environment

MarkView native macOS application, workspace vivaa-platform. Installed MarkView version, macOS version, active filters and affected item metadata are unknown. Code inspected in the local checkout at cc7c082; its origin/main reference is d05c258, the same reference as the earlier validity check. No runtime check was performed.

## Suspected code

- `MarkView/Views/FeatureNavigatorView.swift` — Applies the shared sort to Features and Bugs separately before rendering and binds the sort menu to the store; inspect list updates and menu state at runtime.
- `MarkView/Models/FeatureStore.swift` — Publishes and persists the selected sort and loads the feature and bug arrays; relevant to state propagation and stale data.
- `MarkView/Models/IssueListing.swift` — Implements date fallbacks, priority ranks, directions and tie breakers; effective keys can explain an unchanged order.
- `MarkView/Models/FeatureModels.swift` — Loads feature metadata and supplies the date, priority and ID facts used by the comparator.
- `tools/tests/IssueListingTests.swift` — Covers comparator behavior but does not verify SwiftUI menu and list updates with the affected workspace.
- `docs/features/issues-panel-status-filters-sorting-status-display-and/requirements/REQ-002.md` — Defines the expected sorting fields, directions and missing-priority behavior.

## Likely causes

- Unconfirmed: Feature rows may not refresh or reorder when the shared sort selection changes, even though the reporter sees a date-direction change in Bugs.
- Unconfirmed: Features with equal or unrecognized priorities use date and then ID as tie breakers, so changing priority direction can leave their order unchanged. The code recognizes critical/P0, high/P1, medium/P2 and low/P3.
- Unconfirmed: Feature date values, their fallbacks, or the installed app version may differ from the assumptions used in this inspection.

## Missing information

- An observed sequence of at least two affected Features under both date directions, together with their effective dates or source records.
- An observed sequence under both priority directions, including the item priorities or severities and whether the affected items are Features, Bugs, or both.
- Installed MarkView version and active Issues filters; macOS version may help reproduce any UI-specific behavior.

## Validity check

**Outcome:** Inconclusive (checked 2026-11-06). The status was not changed.

**Verified against:** `origin/main` @ `d05c258c13` (2026-11-05) — Merge pull request #299 from t-boris/fix/bug-store-main-actor

**Reason:** The snapshot sorts Features and Bugs separately using the selected field and direction, and its comparator tests cover date and priority ordering. Those tests do not establish that the SwiftUI menu and list update correctly for the reported workspace. The affected item metadata, observed order, active filters, and installed app version are unavailable, so the reported behavior cannot be confirmed or ruled out without those details and a runtime check.

## Clarifications

**BQ-1** Что происходит, если в Issues выбрать Date и переключить Newest First на Oldest First?  
→ Меняется но только в багах! Видимо только приоритет не работает, но перепроверь

**BQ-2** В каком workspace это происходит? Укажите 2–3 элемента в показанном порядке и версию MarkView.  
→ vivaa-platform  
Features вообще никак не сортируются, баги сортируются по дате

## Original description

В Issues у нас есть возможность сортировки. Так вот, сортировка не работает. Я проверял ее и по приоритету, и по дате, и он вообще не меняет ничего.
