---
type: bug
id: BUG-078
title: UI Studio's simulated lists are empty when a rule names paging parameters as filters, and the seed fills one group only
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio's simulated lists are empty when a rule names paging parameters as filters, and the seed fills one group only

## Summary

On vivaa the home page showed no packages. The bundles/search rule had `filters: [category_id, limit, offset]`. The simulator filtered by equality on every named filter, and no record has a `limit` or `offset` field, so every list was empty. The six seed bundles were also all in one of the six categories. In addition, the preparation prompt allowed `unsupported` for "a third-party SDK", so POST /api/consents was refused because the real route needs the Supabase admin SDK, against the mock-up policy (DEC-007).

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app
2. Look at the home page's package carousels and at .markview/studio/environment.json

## Expected

Every carousel shows simulated packages. Paging parameters page the list. Writes such as consents succeed.

## Actual

bundles/search answers `{hits: []}` for every category. POST /api/consents is "unsupported: requires the Supabase Auth admin SDK".

## Environment

MarkView 5.20.1; StudioSimulator.apply .list; StudioPrompts.preparationSystem
