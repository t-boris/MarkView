---
type: bug
id: BUG-083
title: Opening a project reads and hashes every file, so MarkView peaks at about 25 GB of memory
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# Opening a project reads and hashes every file, so MarkView peaks at about 25 GB of memory

## Summary

`ProjectChangeScanner.open` (Project Changes) walks the whole project when a window opens and reads every file in 1 MB chunks to SHA-256 it, with no size or type limit and no autorelease pool in the loop. It also enters tool caches the shared exclusion list misses (`.turbo`, agent worktrees under `.claude/worktrees`) and binary attachments. With nine windows restored this read about 27 GB (vivaa-platform 9.0 GB, mostly `.turbo/cache`; broker-fabric 11.6 GB; KnowledgeDB 6.4 GB). The read chunks stayed alive until each walk ended: physical footprint peaked at 24.9 GB within 100 s of launch and 23.7 GB of emptied malloc regions remained afterwards. Every window repeats the walk every 15 s.

## Steps to reproduce

1. Open several large projects (one with a Turborepo `.turbo` cache, one with big attachments) and quit MarkView with the windows open
2. Launch MarkView so the windows are restored
3. After a minute run `vmmap --summary <pid>` and read `Physical footprint (peak)`

## Expected

Opening a project costs memory in proportion to the text files kept for review, not to the bytes on disk. Caches and agent worktrees are not scanned, and large or binary files are compared by size, date and file identity instead of being read.

## Actual

Physical footprint (peak) 24.9 GB for a process whose footprint settles at 1.1 GB; 23.7 GB of \"Malloc Small (empty)\" regions after the walk.

## Environment

MarkView 5.25.0, macOS 27.0.1, Mac14,14 with 128 GB; nine restored windows
