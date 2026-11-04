---
type: bug
id: BUG-067
title: UI Studio says "the application does not build" about a Next.js page that built and works
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
updated: 2026-11-04
---

# UI Studio says "the application does not build" about a Next.js page that built and works

## Summary

UI Studio on vivaa-platform apps/client-web-app showed "Stale preview: the application does not build after the change. This is the last working capture." and the red line "Next.js: Console Error Server [fx] rates unavailable in client-web-app: marketplace unreachable", although no change was made and the page rendered fine (the app catches the failed rates call, logs it with console.error and shows a banner). The page runtime treats any open Next.js dev dialog as a build failure, but Next 16 uses the same dialog for console, runtime and recoverable errors and names the kind in its label; only "Build Error" (older: "Failed to compile") is one. A second path gives the same false banner after any change: the dev-server log check fails the rebuild on any line with "Error:", which a handled server console.error writes on every render. Once shown, the banner never clears until the page is reloaded, and the capture notice reads "Captured Capture of Populated."

## Steps to reproduce

1. Open vivaa-platform in MarkView 5.15.0 and open UI Studio on apps/client-web-app
2. Let the page render a server-side console.error (the exchange-rates call fails in the studio and is handled)
3. Open the Next.js issues dialog ("2 Issues") or let the page re-render

## Expected

A console, runtime or recoverable error of a page that built is not a build failure: no stale-preview banner, and the preview stays live. The banner goes away when a real build error is fixed.

## Actual

"Stale preview: the application does not build after the change" with the console error as the build error, the status degraded, and the banner stays until a reload. Notice: "Captured Capture of Populated."

## Environment

MarkView 5.15.0, macOS 27, vivaa-platform (Next.js 16.2.1). Fixed in 5.15.2.

## Fix

Fixed in 5.15.2. (1) The page runtime reads the label of the Next.js dialog: only "Build Error" ("Failed to compile" before Next 15) is a build failure; Console, Runtime and Recoverable errors, Blocking Route and Ambiguous Metadata are issues of a page that built. (2) The runtime reports a build error overlay going away (an empty buildError event, also watching the Next.js portal's shadow root, and no longer deduplicated), and the app then clears the build error and the stale preview without a reload. (3) After a change, only compile and bundle failures in the dev server's log fail "Application rebuilt and reloaded" (`StudioSession.buildFailure(in:)`): a handled server `console.error` such as vivaa's `[fx] … Error: marketplace unreachable` no longer does. (4) The notice reads "Saved a capture of <scenario>." Checks: `tools/tests/ui-studio-web-tests.sh`, `ui-studio-session-tests.sh` (the new page checks fail on 5.15.1 with the exact line of the report).
