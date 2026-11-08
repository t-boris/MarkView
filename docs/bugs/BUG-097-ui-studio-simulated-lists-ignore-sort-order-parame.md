---
type: bug
id: BUG-097
title: UI Studio simulated lists ignore sort/order parameters and text search (REQ-014 criterion 4)
status: fixed
branch: fix/ui-studio-bug-batch
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
updated: 2026-11-05
---

# UI Studio simulated lists ignore sort/order parameters and text search (REQ-014 criterion 4)

## Summary

REQ-014 says paging, sorting and search parameters behave like a real API over the simulated records. Paging (limit/offset/page/per_page) works (BUG-078), but sort, order, order_by, sort_by and a free-text search parameter (q, search) are not applied: `StudioPaging.parameters` lists the sort names only so they are not treated as field filters, and the simulator never reorders or text-searches the list. A page with a sortable table or a search box shows the records in seed order whatever the user chooses.

## Steps to reproduce

1. Open UI Studio on an application whose page lists an entity (for example bundles) through a simulated `list` rule.
2. Make the page request the list with `?sort=price&order=desc` (or `order_by=price.desc`, `sort_by=-price`), or type a word into the page's search box that sends `?q=word`.
3. Compare the rows the page shows with the seed records.

## Expected

The list comes back ordered by the named field in the named direction, and `q`/`search` keeps only the records whose text fields contain the word, as a real API would. Ordering and search apply before paging.

## Actual

The list comes back in seed order and every record matches the search word. Only field filters and paging change the answer. No check covers sorting or text search (`ui-studio-tests.sh` has BUG-078 checks for limit/offset/page only).

## Environment

MarkView 5.35.0, `MarkView/Models/UIStudioSimulation.swift` (`StudioPaging`, list operation at ~line 314). Feature markview-ui-studio, REQ-014 criterion 4 (left unticked).
