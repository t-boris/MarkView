---
type: bug
id: BUG-081
title: UI Studio runs an Rspack dev server on the test clock and it rebuilds without end
status: done
severity: critical
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio runs an Rspack dev server on the test clock and it rebuilds without end

## Summary

UI Studio decides by the dev script whether a server must keep the real clock (DEC-006). It recognises webpack, but not Rspack (`rspack serve`) or Rsbuild. An Rspack server therefore got MARKVIEW_STUDIO_CLOCK. The page's first lazy-compilation request (`POST /lazy-compilation-using-`) compiles inside the request context, where the preload gives the test time (2026-01-15). Watchpack then sees every file as newer than the watch start and rebuilds about 30 times a second: rspack-node used ~700% CPU and 2 GB, and the flood of server output kept MarkView's main thread busy.

## Steps to reproduce

1. Open broker-fabric in MarkView and start UI Studio on apps/strikedesk/app/packages/shell (web only), which runs `pnpm run dev:renderer` = `rspack serve -c rspack.renderer.config.ts`
2. Let the page load (it sends POST /lazy-compilation-using-)
3. Watch .dde/studio/session.log and the rspack-node process

## Expected

An Rspack or Rsbuild dev server keeps the real clock like a webpack one (time zone and language still follow the scenario), and the session notes why. The server compiles once per real change.

## Actual

"Rspack compiled successfully in ~45 ms" every ~33 ms, about 1,700 server lines a minute, for as long as the session runs; rspack-node at ~700% CPU. The first compile before any request was a single one.

## Environment

MarkView 5.25.0, macOS 27.0.1, @rspack/core 1.7.6 (watchpack bundled), Node 22.22.3
