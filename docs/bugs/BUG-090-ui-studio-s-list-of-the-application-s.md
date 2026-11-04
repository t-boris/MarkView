---
type: bug
id: BUG-090
title: UI Studio's list of the application's API is made by one assistant call and is empty when it times out
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio's list of the application's API is made by one assistant call and is empty when it times out

## Summary

In vivaa-platform the admin-panel has 63 method and path pairs in its own route.ts files, and 56 of them have no rule, among them GET /api/admin/work/queue (apps/admin-panel/app/api/admin/work/queue/route.ts). The environment's map is status failed, inventoried false, with "The assistant did not list the application's API within 420 s." The listing is one call to an assistant agent that reads the project; no code scan runs, so a timeout leaves no list at all and every request is prepared later, one by one, as the page makes it. The 269 existing rules came from those on-demand preparations and from earlier maps.

## Steps to reproduce

1. Open UI Studio for an application with many route handlers (vivaa-platform admin-panel).
2. Let the environment map run: the inventory call gets 420 s.
3. Compare apps/admin-panel/app/api/**/route.ts with the rules in .markview/studio/environment.json.

## Expected

Every route handler the code defines is listed, whatever the assistant does; the person sees the full list, which endpoints still have no answer, and decides the answer for each.

## Actual

The list is whatever one assistant call finished within 420 s; when it times out the map is failed and empty, and an endpoint such as work/queue is only discovered when the page requests it, then held for up to 90 s while an answer is prepared.

## Environment

MarkView 5.27.0, vivaa-platform admin-panel; UIStudioEnvironmentMapper.swift (one inventory call), UIStudioEnvironmentMap.swift (inventoryDeadline 420).
