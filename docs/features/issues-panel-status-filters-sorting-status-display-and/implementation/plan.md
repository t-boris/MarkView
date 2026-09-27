---
type: plan
feature: issues-panel-status-filters-sorting-status-display-and
title: "Issues panel: status filters, sorting, status display and resizable width"
issues:
  - id: I-1
    title: Status normalization and Open/Closed/Implemented classification model
    summary: "Add a pure, unit-tested model layer that normalizes feature and bug status values: trim whitespace, lowercase, and treat '_' and ' ' as '-'. It classifies each item as Open or Closed (feature Closed = implemented/done/rejected/cancelled; bug Closed = closed/fixed; missing or unknown = Open) and as Implemented or Not-implemented (features only). It also evaluates the faceted filter: OR within the Status, Type and Implementation groups, AND across groups. Any Implementation selection excludes bugs. The result is ANDed with the free-text filter."
    requirements: [REQ-001]
    decisions: [DEC-002, DEC-005, DEC-006, DEC-009, DEC-012, DEC-014]
  - id: I-2
    title: "Sort keys: date fallback chain and unified priority scale"
    summary: Implement comparators for the two sort keys. The date key uses `updated`, falls back to `created`, then to file mtime, and accepts YYYY-MM-DD or ISO 8601 (invalid values count as missing). The priority key maps bug severity and feature priority onto a critical/high/medium/low scale. Items without a value go last in both directions, and ties are broken by title, then id. Sorting applies within each section. The default is date descending, and when the user switches keys the initial direction is date descending or priority high-to-low. No git access and no file format changes.
    requirements: [REQ-002]
    decisions: [DEC-003, DEC-007, DEC-011, DEC-009, DEC-012, DEC-008]
  - id: I-3
    title: Funnel and sort menus, active-filter summary and empty states in FeatureNavigatorView
    summary: Add a funnel menu and a sort menu next to the Filter field. The funnel menu has three grouped multi-select toggle sections. The sort menu offers key and direction. When any filter toggle is selected, highlight the funnel and show a one-line summary (e.g. 'Open · Bugs') with a reset that clears the filters only. Hide sections that have no matching items. When nothing matches, show 'No matching items' with a reset that clears the funnel filter and the text filter. Wire everything to the model from issues 1–2.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-006, DEC-008, DEC-009, DEC-010, DEC-012]
  - id: I-4
    title: Visible status badge in feature and bug rows
    summary: Show a compact status badge in every row. Features use FeatureVocabulary labels and bugs use the normalized raw value. A missing status is shown as a muted 'open'. At narrow widths the title truncates first. The badge keeps up to 12 characters, then truncates with an ellipsis and a tooltip.
    requirements: [REQ-003]
    decisions: [DEC-014]
  - id: I-5
    title: Persist filter and sort per project
    summary: Store the selected filter toggles in `features.issues.filter.<hash>` and the sort in `features.issues.sort.<hash>` ('field:direction'), keyed by a 12-char hash of the project root. Restore them on open and fall back to the defaults when values are invalid. A restored non-default filter shows the highlight and the summary. Document both keys in docs/architecture/configuration.md.
    requirements: [REQ-005]
    decisions: [DEC-004, DEC-008, DEC-015]
  - id: I-6
    title: Make the Issues panel resizable with the shared left-sidebar width
    summary: First check in the code whether the Issues panel is currently resizable and which mechanism, min/max limits and persistence key the other left panels use. Then make the Issues panel use that same shared width mechanism with no new key. Record the concrete values in REQ-004. If the panel already resizes, this becomes a regression check.
    requirements: [REQ-004]
    decisions: [DEC-013]
updated: 2026-09-27
---

# Implementation plan — Issues panel: status filters, sorting, status display and resizable width

## I-1: Status normalization and Open/Closed/Implemented classification model

Add a pure, unit-tested model layer that normalizes feature and bug status values: trim whitespace, lowercase, and treat '_' and ' ' as '-'. It classifies each item as Open or Closed (feature Closed = implemented/done/rejected/cancelled; bug Closed = closed/fixed; missing or unknown = Open) and as Implemented or Not-implemented (features only). It also evaluates the faceted filter: OR within the Status, Type and Implementation groups, AND across groups. Any Implementation selection excludes bugs. The result is ANDed with the free-text filter.

Requirements: REQ-001
Decisions: DEC-002, DEC-005, DEC-006, DEC-009, DEC-012, DEC-014

## I-2: Sort keys: date fallback chain and unified priority scale

Implement comparators for the two sort keys. The date key uses `updated`, falls back to `created`, then to file mtime, and accepts YYYY-MM-DD or ISO 8601 (invalid values count as missing). The priority key maps bug severity and feature priority onto a critical/high/medium/low scale. Items without a value go last in both directions, and ties are broken by title, then id. Sorting applies within each section. The default is date descending, and when the user switches keys the initial direction is date descending or priority high-to-low. No git access and no file format changes.

Requirements: REQ-002
Decisions: DEC-003, DEC-007, DEC-011, DEC-009, DEC-012, DEC-008

## I-3: Funnel and sort menus, active-filter summary and empty states in FeatureNavigatorView

Add a funnel menu and a sort menu next to the Filter field. The funnel menu has three grouped multi-select toggle sections. The sort menu offers key and direction. When any filter toggle is selected, highlight the funnel and show a one-line summary (e.g. 'Open · Bugs') with a reset that clears the filters only. Hide sections that have no matching items. When nothing matches, show 'No matching items' with a reset that clears the funnel filter and the text filter. Wire everything to the model from issues 1–2.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-006, DEC-008, DEC-009, DEC-010, DEC-012

## I-4: Visible status badge in feature and bug rows

Show a compact status badge in every row. Features use FeatureVocabulary labels and bugs use the normalized raw value. A missing status is shown as a muted 'open'. At narrow widths the title truncates first. The badge keeps up to 12 characters, then truncates with an ellipsis and a tooltip.

Requirements: REQ-003
Decisions: DEC-014

## I-5: Persist filter and sort per project

Store the selected filter toggles in `features.issues.filter.<hash>` and the sort in `features.issues.sort.<hash>` ('field:direction'), keyed by a 12-char hash of the project root. Restore them on open and fall back to the defaults when values are invalid. A restored non-default filter shows the highlight and the summary. Document both keys in docs/architecture/configuration.md.

Requirements: REQ-005
Decisions: DEC-004, DEC-008, DEC-015

## I-6: Make the Issues panel resizable with the shared left-sidebar width

First check in the code whether the Issues panel is currently resizable and which mechanism, min/max limits and persistence key the other left panels use. Then make the Issues panel use that same shared width mechanism with no new key. Record the concrete values in REQ-004. If the panel already resizes, this becomes a regression check.

Requirements: REQ-004
Decisions: DEC-013
