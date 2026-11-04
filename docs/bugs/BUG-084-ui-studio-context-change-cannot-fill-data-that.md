---
type: bug
id: BUG-084
title: UI Studio context change cannot fill data that a rule answers with a fixed body
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio context change cannot fill data that a rule answers with a fixed body

## Summary

Asked three times to fill the StrikeDesk option chain with 16 strikes above and below the middle, the assistant answered \"Not done: the environment does not provide the option chain data or its format\". The chain comes from `strikedesk-backend-ibkr-data-fetch-structure`, a `respond` rule with a fixed body (5 strikes). An override with status 200 and a new body would change it, but the context block lists only the first 60 of 195 rules (this one is number 185) and never shows a fixed rule's body, and the prompt reads as if overriding a body were faking. So data served by fixed answers (155 of 195 rules here) can never be changed by a context change.

## Steps to reproduce

1. Open UI Studio on broker-fabric apps/strikedesk/app/packages/shell (web only), scenario Populated, Trade tab
2. With nothing selected, ask: "Fill the trade table with numbers, 16 strikes above and 16 below the middle for the first expiry"
3. Read the answer in the inspector

## Expected

The assistant sees the rules the page's requests reached first, with the shape of each fixed answer, and fills the table by overriding the rule's body in the same shape. MarkView refuses a body that drops keys of the current answer, so the page does not break.

## Actual

status answered, nothing changed; `unsupported`: \"Данные цепочки опционов для каждого expiry не представлены среди доступных сущностей; формат ответа ... не указан\" (three requests, op-2026-11-04T182109Z, T184405Z, T184530Z).

## Environment

MarkView 5.25.0; broker-fabric .markview/studio/environment.json (195 rules, 15 entities)
