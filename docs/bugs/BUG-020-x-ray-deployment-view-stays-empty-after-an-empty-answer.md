---
type: bug
id: BUG-020
title: X-Ray Deployment view stays empty after the assistant returns an empty map
status: fixed
branch: fix/bug-020-empty-deployment
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Reported in a Claude Code session
---

# X-Ray Deployment view stays empty after the assistant returns an empty map

## Summary

In MarkView 3.4.2, the X-Ray Deployment view of Broker Fabric showed nothing at all. Running Analyze
again did not bring it back.

## Steps to reproduce

1. Open a project in X-Ray and run Analyze with an assistant that answers the deployment request with
   `{"nodes":[],"edges":[]}` (Codex `gpt-6-luna` at low effort did this once for Broker Fabric).
2. Open the Deployment view: it is empty.
3. Run Analyze again without changing build or deploy files: the view stays empty.

## Expected

An empty answer is not taken as the deployment map. X-Ray asks again, keeps the previous map if the
answer is still empty, says so, and maps again on the next Analyze.

## Actual

The empty answer was stored as a map with only its root node, together with the signature of the
build and deploy files. Each later Analyze skipped the mapping because the signature was unchanged.

## Reproduction and root cause

Broker Fabric's `.dde/state.db` held one deployment node (the root) and no edges, and
`.dde/cache/xray/96242293c34dd4e06dc9b3df34e2d57a.json` held `{"nodes":[],"edges":[]}` from the
analysis at 06:47. Six direct Codex runs of a similar deployment prompt returned 11 to 25 nodes, so
the empty answer is intermittent. Three defects made it permanent:

- `mapDeployment` built a view from any answer, including one without nodes, and the analysis stored
  the deployment signature with it.
- The signature check returned early whenever a deployment view existed, even one with only its root.
- `xrayCall` cached every non-empty object; `{"nodes":[],"edges":[]}` is one, so a forced retry would
  have read the empty answer back from the cache.

## Resolution

- `xrayCall` takes an `accept` check. A rejected answer is neither cached nor read from the cache, and
  the request is repeated once.
- `mapDeployment` accepts only answers with at least one node. If both attempts are empty it throws
  `EmptyDeploymentMap`: the previous map and its signature are kept, and X-Ray's status line says the
  map came back empty and to click Analyze again.
- A stored deployment view with only its root counts as missing, so projects already affected are
  mapped again on the next Analyze.

Verified with a Debug build on an APFS clone of Broker Fabric that still had the empty map and the
cached empty answer: Analyze rebuilt the Deployment view.

## Environment

MarkView 3.4.2 on macOS, X-Ray backend Codex with the X-Ray model `gpt-6-luna` at low effort.

## Suspected code

- `MarkView/Models/ArchitectureStore.swift` — `analyze`, `mapDeployment`, `xrayCall`.
