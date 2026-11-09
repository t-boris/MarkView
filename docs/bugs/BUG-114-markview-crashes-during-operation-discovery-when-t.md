---
type: bug
id: BUG-114
title: MarkView crashes during operation discovery when two referenced folders overlap
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-09
provenance: Created by an AI agent through MarkView
updated: 2026-11-09
---

# MarkView crashes during operation discovery when two referenced folders overlap

## Summary

MarkView terminated with EXC_BREAKPOINT (SIGTRAP) at 2026-11-08 19:43:23 while the Operations discovery was running (version 5.47.0). The crashing thread is a Swift concurrency worker; the trap is Dictionary(uniqueKeysWithValues:) inside ProjectOperationDiscoveryService.discover(root:existing:deploymentNodes:phase:), which builds the source fingerprints from inputs.files. ProjectOperationDiscovery.scan can return the same file twice: when a project document references two folders where one contains the other (for example ../infra and ../infra/scripts), both are granted and walked, so each file inside the inner folder is read once per folder. The duplicate path becomes a duplicate dictionary key and the app aborts.

## Steps to reproduce

1. Open a project whose README (or another discovery input) mentions two external folders where one is inside the other, e.g. ../infra and ../infra/scripts
2. Open the Operations / Deployment view and run discovery (Discover or Re-discover)
3. When the assistant answers, discover() builds the source fingerprints and the app crashes

## Expected

Every investigated file is listed once, discovery finishes, and the app keeps running whatever folders the documents mention.

## Actual

scan() lists a file under two granted folders twice; Dictionary(uniqueKeysWithValues:) in ProjectOperationDiscoveryService.swift:173 traps on the duplicate key and the app crashes. Five crash reports with the identical stack (MarkView-2026-11-08-194323, 194716, 194941, 195200, 195446 .ips; thread: _assertionFailure -> _NativeDictionary.merge(trappingOnDuplicates:) -> Dictionary.init(uniqueKeysWithValues:) -> ProjectOperationDiscoveryService.discover -> ProjectOperationsStore.discover(nodes:)), each when Discover ran in the installed 5.47.0. Reproduced with a standalone harness (README naming ../infra and ../infra/scripts gives 3 files, 2 unique) and on the real project broker-fabric, where the granted folders ~/.broker-fabric and ~/.broker-fabric/recordings/... overlap and 8 files are listed twice.

## Environment

MarkView 5.47.0 on macOS 27.0.1 (26A434). The discovery code dates from 2026-11-06 (b1ce96c); not related to the Workflow diagram work in BUG-112/BUG-113.

## Resolution

Root cause: ProjectOperationDiscovery.scan read a file once for every granted folder. Folders that overlap (../infra and ../infra/scripts, or a folder that holds the project) therefore listed the same file twice, and ProjectOperationDiscoveryService.discover keys the source fingerprints by file path with Dictionary(uniqueKeysWithValues:), which aborts the app on a repeated key. Fix (PR #334, 5.48.1): scan skips a file it has already read, so the input list is unique by real path. Verified: tools/tests/project-operation-discovery-tests.sh now includes a second document that names a nested folder; it fails on the old source (SIGTRAP) and passes with the fix; Debug build succeeds. Not hand-checked in the running app.
