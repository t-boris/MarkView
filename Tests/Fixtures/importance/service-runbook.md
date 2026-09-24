# Payments Ledger Service — Runbook

## Overview

The ledger service records every money movement for customer wallets. It exposes
an internal gRPC API used by checkout, refunds and payouts.

## Changelog

- 2024-03: moved from Postgres 13 to 15.
- 2023-11: renamed the service from `wallet-core` to `ledger`.
- 2023-06: first version.

## Data retention and deletion (legal requirement)

Ledger entries must be kept for exactly 7 years and must never be edited or deleted,
including on a customer's deletion request — only the customer's name and email are
anonymised. Deleting or rewriting an entry breaks financial audits and is a
reportable compliance incident.

## Restoring from backup after data loss

1. Stop all writers: scale `ledger-writer` to 0 before anything else.
2. Restore the latest snapshot into a new cluster; never overwrite the live one.
3. Replay the write-ahead log from the snapshot timestamp, then verify balances with
   `ledger verify --all` before re-enabling writers.

Skipping step 1 causes double-booked transactions that are very hard to undo.

## Dashboards

Grafana board "Ledger / Overview" shows request rate, p95 latency and error rate.

## Acknowledgements

Thanks to the platform team for the original Helm chart and to everyone who
reviewed the first design.
