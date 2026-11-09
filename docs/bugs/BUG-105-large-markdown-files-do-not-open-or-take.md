---
type: bug
id: BUG-105
title: "Large Markdown files do not open (or take very long): vivaa-internals docs/research/2026-11-06-strategic-plan.md and 2026-11-07-business-plan.md"
status: done
severity: critical
reporter: Boris Tsekinovsky
created: 2026-11-07
provenance: Created by an AI agent through MarkView
updated: 2026-11-07
---

# Large Markdown files do not open (or take very long): vivaa-internals docs/research/2026-11-06-strategic-plan.md and 2026-11-07-business-plan.md

## Summary

MarkView does not open /Users/boris/github.com/vivaa-internals/docs/research/2026-11-06-strategic-plan.md (613 KB, 3938 lines) and /Users/boris/github.com/vivaa-internals/docs/research/2026-11-07-business-plan.md (832 KB, 11349 lines), and "it takes very long". Both are valid UTF-8 without BOM, CRLF, NUL or control characters, so the text reader accepts them.

Root cause found for the business plan: it holds 253 Mermaid diagrams, 2354 table rows and 18,000 page elements. The editor page drew the diagrams with one `mermaid.run` call. Every diagram that is drawn puts a `<style>` element into the page, and WebKit then recalculates the styles of every element of the document, so the cost of one diagram grows with the size of the document (about 8.5 microseconds per element: 9 ms in an empty page, 155 ms in this one). The page stayed frozen for about 57 seconds (measured in real WebKit with the shipping editor page); text, scrolling and input did not respond until the last diagram was drawn.

Not reproduced: the strategic plan is a research map without diagrams. Its page renders in 0.13 s and the Swift parse takes 76 ms, so the page and the parser are not the cause there.

Secondary finding (not changed, needs approval): `WorkspaceManager.handleBlocksDelta` writes every block of a newly opened document to SQLite one by one on the main thread (1339 blocks for the strategic plan, 3064 for the business plan). Alone it takes 0.1-0.3 s, but while another process holds the write lock (the out-of-process indexer, or a second window) the same writes took 28.8 s for 1339 blocks in a measurement with the same schema and pragmas.

## Steps to reproduce

1. Open /Users/boris/github.com/vivaa-internals/docs/research/2026-11-06-strategic-plan.md (File > Open or from the file tree) in MarkView.
2. Same with 2026-11-07-business-plan.md.
3. Compare with a small Markdown file from the same folder tree.

## Expected

A Markdown file of this size opens in a tab within a few seconds and stays responsive, or MarkView says clearly why it cannot and offers an alternative.

## Actual

The files do not appear in a tab (or only after a very long wait). While the running app was sampled (pid 21138, 184% CPU, 1.6 GB resident, up for 26 hours) the main thread was idle in the event loop; background work was ArchitectureStore.performScan and FeatureStore.reloadIfChanged/fingerprint opening files, and the machine was also loaded by other processes. No error is shown and the unified log has no MarkView entry about the files.

## Environment

MarkView 5.38.0 installed in /Applications (main process pid 21138), macOS on Apple silicon, Ollama llama-server running at ~570% CPU on the same machine during the sample
